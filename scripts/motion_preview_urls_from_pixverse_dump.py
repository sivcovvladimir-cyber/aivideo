#!/usr/bin/env python3
"""Генерирует SQL для обновления preview_video_url из docs/pixverse_effects_data.

Приоритет источника motion URL:
1) `app_thumbnail_gif_url` (если есть и это webp/gif с `app` в URL);
2) fallback: `thumbnail_gif_path` c заменой `web_`/`web-` -> `app_`/`app-`.

Группы обновления:
- group_id = 7: только 8 template_id, добавленные последним апдейтом;
- group_id IN (8, 9, 10, 11): все совпавшие template_id из motion_map.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DUMP = REPO_ROOT / "docs" / "pixverse_effects_data"
DEFAULT_OUT = REPO_ROOT / "docs" / "supabase" / "migrations" / "014_motion_preview_app_urls_groups_7_11.sql"
GROUP_7_LAST_ADDED_TEMPLATE_IDS = (
    359328847686976,
    358817882065344,
    359155391147328,
    361263764141120,
    330523675191680,
    324640938615168,
    375446505475008,
    376165070337920,
)


def has_app_in_url(url: str) -> bool:
    u = url.lower()
    return "app_" in u or "app-" in u or "%2fapp" in u


def mobile_motion_from_thumbnail_gif_path(gif: str):
    gif = (gif or "").strip()
    if not gif:
        return None
    if not (gif.lower().endswith(".webp") or gif.lower().endswith(".gif")):
        return None
    if has_app_in_url(gif):
        return gif
    for old, new in (("web_", "app_"), ("web-", "app-"), ("Web_", "app_")):
        if old in gif:
            return gif.replace(old, new, 1)
    return None


def pick_mobile_motion_url(obj: dict) -> str | None:
    # Берём app_motion строго из поля дампа; это исключает случайный выбор горизонтальных web-вариантов.
    app_gif = (obj.get("app_thumbnail_gif_url") or "").strip()
    if app_gif and has_app_in_url(app_gif) and app_gif.lower().endswith((".webp", ".gif")):
        return app_gif
    return mobile_motion_from_thumbnail_gif_path(obj.get("thumbnail_gif_path") or "")


def parse_dump(path: Path) -> dict[int, str]:
    text = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None

    mapping: dict[int, str] = {}
    # Основной путь: файл уже сохранён как валидный JSON { "items": [...] }.
    if isinstance(payload, dict) and isinstance(payload.get("items"), list):
        for obj in payload["items"]:
            if not isinstance(obj, dict):
                continue
            tid = obj.get("template_id")
            if not isinstance(tid, int):
                continue
            url = pick_mobile_motion_url(obj)
            if url and has_app_in_url(url):
                mapping[tid] = url
        return mapping

    # Fallback для старых «грязных» дампов: эвристический разбор по template_id.
    for m in re.finditer(r'"template_id"\s*:\s*(\d+)', text):
        tid = int(m.group(1))
        if tid in mapping:
            continue
        start = text.rfind("{", 0, m.start())
        depth = 0
        for i in range(start, min(start + 300_000, len(text))):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break
                    if obj.get("template_id") != tid:
                        break
                    url = pick_mobile_motion_url(obj)
                    if url and has_app_in_url(url):
                        mapping[tid] = url
                    break
    return mapping


def render_sql(mapping: dict[int, str], group_ids: tuple[int, ...]) -> str:
    groups_sql = ", ".join(str(g) for g in group_ids)
    g7_ids_sql = ", ".join(f"{x}::bigint" for x in GROUP_7_LAST_ADDED_TEMPLATE_IDS)
    value_lines = []
    for tid, url in sorted(mapping.items()):
        esc = url.replace("'", "''")
        value_lines.append(f"        ({tid}::bigint, '{esc}'::text)")
    if value_lines:
        value_lines[-1] = value_lines[-1]  # trailing comma ok in SQL values before closing paren in PG? Actually PG allows trailing comma in VALUES? No - remove last comma
        value_lines[-1] = value_lines[-1].rstrip(",")

    values_body = ",\n".join(value_lines)
    group_label = ", ".join(str(g) for g in group_ids)
    return f"""-- Motion-превью для групп id {group_label}: мобильный WebP/GIF (`app_` / `app-` в URL).
-- Источник: приоритет `app_thumbnail_gif_url`, fallback `thumbnail_gif_path` (web -> app).
-- Для group_id=7 обновляются только template_id из последнего апдейта каталога.

begin;

with motion_map (provider_template_id, preview_video_url) as (
    values
{values_body}
)
update public.effect_presets p
set
    preview_video_url = m.preview_video_url,
    updated_at = now()
from motion_map m
where (
      p.group_id = 7
      and p.provider_template_id in ({g7_ids_sql})
   or p.group_id in ({groups_sql})
         and p.group_id <> 7
)
  and p.provider_template_id = m.provider_template_id
  and p.preview_video_url is distinct from m.preview_video_url;

commit;
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, default=DEFAULT_DUMP)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--groups", default="7,8,9,10,11", help="effect_groups.id через запятую")
    args = parser.parse_args()
    group_ids = tuple(int(x.strip()) for x in args.groups.split(",") if x.strip())
    mapping = parse_dump(args.dump)
    args.out.write_text(render_sql(mapping, group_ids), encoding="utf-8")
    print(f"Wrote {len(mapping)} rows → {args.out}")


if __name__ == "__main__":
    main()
