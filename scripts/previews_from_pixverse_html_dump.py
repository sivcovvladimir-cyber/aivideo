#!/usr/bin/env python3
"""
Строит SQL UPDATE превью из сохранённого HTML PixVerse (как Party.txt / Spring.txt):
  - карточки: <div data-index="…"> … <span class="text-xs…">Название</span> … img src="…"

Party: постер — первая картинка .png/.jpg в блоке (без query); «движение» для `preview_video_url` —
первый .webp в том же блоке (второй <img> в вёрстке студии), без query.

Spring: пара `studio/img/<uuid>.jpg` + `…webp` — постер и `preview_video_url` (motion-слой).

Пример:
  python3 scripts/previews_from_pixverse_html_dump.py \\
    --party "/path/Party.txt" --spring "/path/Spring.txt" > docs/supabase/migrations/_generated_previews.sql
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

# Совпадение с миграцией 008: title в HTML → provider_template_id
PARTY_TITLE_TO_TEMPLATE_ID: dict[str, int] = {
    "Bald Swipe": 340361643937600,
    "Gender Swap": 323578865822784,
    "Love Punch": 339376362313472,
    "Long Hair Magic": 308552687706496,
    "Muscle Surge": 308621408717184,
    "Baby Arrived": 342874383633472,
    "Kungfu Club": 315447659476032,
    "Balloon Belly": 336856634055424,
    "Punch Face": 338083197718400,
    "Muscle Max: Bodybuilder Champion": 350496364287680,
}

# Совпадение с миграцией 007: title → provider_template_id (типичный дамп Spring)
SPRING_TITLE_TO_TEMPLATE_ID: dict[str, int] = {
    "Spring Ink Blossom": 392297961247515,
    "Sakura Light-Up": 392309110682398,
    "Splash Me": 392461593847898,
    "Petting Lambkins": 392501390618708,
    "Puppy Lovers": 392341961751019,
    "Nest on My Head": 392472479471738,
    "Playful Bubbles": 392342538206009,
    "Spring Rain": 392499419152452,
}

RASTER_EXT = (".png", ".jpg", ".jpeg", ".webp")


def strip_query(url: str) -> str:
    return url.split("?", 1)[0]


def parse_dump(path: Path) -> dict[str, list[str]]:
    s = path.read_text(encoding="utf-8", errors="replace")
    parts = re.split(r'<div data-index="\d+">', s)
    out: dict[str, list[str]] = {}
    for p in parts[1:]:
        m = re.search(r'<span class="text-xs[^"]*">([^<]+)</span>', p)
        if not m:
            continue
        title = m.group(1).strip()
        imgs = re.findall(r'src="(https://media\.pixverse\.ai/[^"]+)"', p)
        out[title] = imgs
    return out


def first_raster_url(imgs: Iterable[str]) -> str | None:
    for u in imgs:
        low = u.lower()
        if any(low.split("?", 1)[0].endswith(ext) for ext in RASTER_EXT):
            return u
    return None


def pick_best_image(imgs: list[str]) -> str | None:
    u = first_raster_url(imgs)
    if not u:
        return None
    stripped = [strip_query(x) for x in imgs]
    for pref in (".png", ".jpg", ".jpeg"):
        for x in stripped:
            if x.lower().endswith(pref):
                return x
    return strip_query(u)


def pick_webp_motion_overlay(imgs: list[str], poster: str) -> str | None:
    """Первый .webp в порядке DOM; предпочтительно не совпадает с постером (jpg/png + webp overlay)."""
    poster_s = strip_query(poster)
    first: str | None = None
    for u in imgs:
        s = strip_query(u)
        if not s.lower().endswith(".webp"):
            continue
        if first is None:
            first = s
        if s != poster_s:
            return s
    return first


def sql_escape(s: str) -> str:
    return s.replace("'", "''")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--party", type=Path, help="Путь к Party.txt (HTML)")
    ap.add_argument("--spring", type=Path, help="Путь к Spring.txt (HTML)")
    args = ap.parse_args()
    if not args.party and not args.spring:
        ap.print_help()
        sys.exit(1)

    party_rows: list[tuple[int, str, str]] = []
    if args.party:
        dump = parse_dump(args.party)
        for title, tid in PARTY_TITLE_TO_TEMPLATE_ID.items():
            imgs = dump.get(title)
            if not imgs:
                print(f"-- SKIP party (нет в дампе): {title}", file=sys.stderr)
                continue
            img = pick_best_image(imgs)
            if not img:
                print(f"-- SKIP party (нет img): {title}", file=sys.stderr)
                continue
            webp = pick_webp_motion_overlay(imgs, img)
            if not webp:
                print(f"-- SKIP party (нет .webp в блоке): {title}", file=sys.stderr)
                continue
            party_rows.append((tid, img, webp))

    spring_rows: list[tuple[int, str, str]] = []
    if args.spring:
        dump = parse_dump(args.spring)
        for title, tid in SPRING_TITLE_TO_TEMPLATE_ID.items():
            imgs = dump.get(title)
            if not imgs:
                print(f"-- SKIP spring (нет в дампе): {title}", file=sys.stderr)
                continue
            img = pick_best_image(imgs)
            if not img:
                continue
            if "/studio%2Fimg%2F" not in img and "/studio/img/" not in img.lower():
                print(f"-- WARN spring (не studio img): {title} {img[:80]}", file=sys.stderr)
            webp = pick_webp_motion_overlay(imgs, img)
            if not webp:
                print(f"-- SKIP spring (нет .webp в блоке): {title}", file=sys.stderr)
                continue
            spring_rows.append((tid, img, webp))

    print("begin;")
    if party_rows:
        print()
        print("-- Party (сгенерировано previews_from_pixverse_html_dump.py)")
        print("update public.effect_presets p set preview_image_url = v.preview_image_url,")
        print("preview_video_url = v.preview_video_url, updated_at = now()")
        print("from (values")
        for i, (tid, img, vid) in enumerate(party_rows):
            comma = "," if i < len(party_rows) - 1 else ""
            print(
                f"    ({tid}::bigint, '{sql_escape(img)}'::text, '{sql_escape(vid)}'::text){comma}"
            )
        print(
            ") as v(provider_template_id, preview_image_url, preview_video_url)\n"
            "where p.provider = 'pixverse' and p.provider_template_id = v.provider_template_id;"
        )
    if spring_rows:
        print()
        print("-- Spring (сгенерировано previews_from_pixverse_html_dump.py)")
        print("update public.effect_presets p set preview_image_url = v.preview_image_url,")
        print("preview_video_url = v.preview_video_url, updated_at = now()")
        print("from (values")
        for i, (tid, img, webp) in enumerate(spring_rows):
            comma = "," if i < len(spring_rows) - 1 else ""
            print(
                f"    ({tid}::bigint, '{sql_escape(img)}'::text, '{sql_escape(webp)}'::text){comma}"
            )
        print(
            ") as v(provider_template_id, preview_image_url, preview_video_url)\n"
            "where p.provider = 'pixverse' and p.provider_template_id = v.provider_template_id;"
        )
    print()
    print("commit;")


if __name__ == "__main__":
    main()
