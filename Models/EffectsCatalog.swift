import Foundation

// MARK: - Catalog models

/// Строка `effect_presets`: PK `integer` в БД; в JSON `get_effects_home` поле `preset.id` — число.
struct EffectPreset: Identifiable, Codable, Equatable {
    let id: Int
    let slug: String
    let title: String
    let description: String?
    let promptTemplate: String?
    let providerTemplateId: Int?
    let tokenCost: Int?
    let isProOnly: Bool
    /// Соотношение для превью/выхода (переопределение над группой); строка `w:h`, например `9:16`.
    let aspectRatio: String?
    let durationSeconds: Int?
    let previewImageURL: URL?
    let previewVideoURL: URL?

    /// Ширина к высоте для слотов превью из строки `9:16` и т.п.
    var previewLayoutAspectWidthOverHeight: Double {
        Self.parseRatioWidthOverHeight(aspectRatio) ?? (9.0 / 16.0)
    }

    private static func parseRatioWidthOverHeight(_ raw: String?) -> Double? {
        guard let raw = raw?.split(separator: ":"),
              raw.count == 2,
              let w = Double(raw[0]),
              let h = Double(raw[1]),
              h > 0 else { return nil }
        return w / h
    }

    /// В `get_effects_home` у элементов hero часто нет `preview_image` / `preview_video`, хотя в секциях тот же `id` уже с полными URL — подставляем только отсутствующие поля.
    func fillingPreviewMediaIfMissing(fromSameIdFallback fallback: EffectPreset?) -> EffectPreset {
        guard let fallback, fallback.id == id else { return self }
        guard previewImageURL == nil || previewVideoURL == nil else { return self }
        return EffectPreset(
            id: id,
            slug: slug,
            title: title,
            description: description,
            promptTemplate: promptTemplate,
            providerTemplateId: providerTemplateId,
            tokenCost: tokenCost,
            isProOnly: isProOnly,
            aspectRatio: aspectRatio,
            durationSeconds: durationSeconds,
            previewImageURL: previewImageURL ?? fallback.previewImageURL,
            previewVideoURL: previewVideoURL ?? fallback.previewVideoURL
        )
    }
}

struct EffectsHomeItem: Identifiable, Codable, Equatable {
    let preset: EffectPreset
    /// Дубликат `preset.token_cost` из RPC; можно использовать как число для UI без клиента-калькулятора.
    let estimatedCostTokens: Int?

    var id: Int { preset.id }

    func resolvedEstimatedCostTokens() -> Int {
        let calculator = GenerationCostCalculator()
        return calculator.effectGenerationCost(presetTokenCost: estimatedCostTokens ?? preset.tokenCost)
    }
}

/// Hero-блок: группа с `is_hero`; несколько эффектов — карусель на главной.
struct EffectsHeroCarousel: Identifiable, Codable, Equatable {
    let sectionId: String
    let title: String
    let subtitle: String?
    /// Aspect всего блока (из группы), строка `w:h`; главная задаёт высоту плейсхолдера.
    let aspectRatio: String
    let items: [EffectsHomeItem]

    var id: String { sectionId }

    var layoutAspectWidthOverHeight: Double {
        Self.parseRatioWidthOverHeight(aspectRatio) ?? (16.0 / 9.0)
    }

    private static func parseRatioWidthOverHeight(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              h > 0 else { return nil }
        return w / h
    }
}

struct EffectsHomeSection: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let sort: Int
    let isFeatured: Bool
    let aspectRatio: String?
    let items: [EffectsHomeItem]

    enum CodingKeys: String, CodingKey {
        case sectionId
        case title
        case subtitle
        case sort
        case isFeatured
        case aspectRatio
        case items
    }

    init(id: String, title: String, subtitle: String?, sort: Int, isFeatured: Bool, aspectRatio: String?, items: [EffectsHomeItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sort = sort
        self.isFeatured = isFeatured
        self.aspectRatio = aspectRatio
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .sectionId)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        sort = try c.decode(Int.self, forKey: .sort)
        isFeatured = try c.decode(Bool.self, forKey: .isFeatured)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)
        items = try c.decode([EffectsHomeItem].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .sectionId)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encode(sort, forKey: .sort)
        try c.encode(isFeatured, forKey: .isFeatured)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try c.encode(items, forKey: .items)
    }
}

struct EffectsHomePayload: Codable, Equatable {
    let hero: EffectsHeroCarousel?
    let sections: [EffectsHomeSection]

    /// Диагностика каталога эффектов: одним логом видим, что пришло из RPC/памяти AppState и какие poster/motion URL реально попадут в UI.
    func debugLogSummary(source: String, prefix: String = "[effects-preview]") {
        // let heroCount = hero?.items.count ?? 0
        // print("\(prefix) EffectsHomePayload source=\(source) heroItems=\(heroCount) sections=\(sections.count)")
        //
        // if let hero {
        //     print("\(prefix)   hero section=\(hero.sectionId) title='\(hero.title)' aspect=\(hero.aspectRatio) items=\(hero.items.count)")
        //     for item in hero.items {
        //         item.debugLogSummary(context: "hero:\(hero.sectionId)", prefix: prefix)
        //     }
        // }
        //
        // for section in sections {
        //     print("\(prefix)   section=\(section.id) title='\(section.title)' aspect=\(section.aspectRatio ?? "nil") items=\(section.items.count)")
        //     for item in section.items {
        //         item.debugLogSummary(context: "section:\(section.id)", prefix: prefix)
        //     }
        // }
        _ = source
        _ = prefix
    }

    /// Подмешивает poster/motion в hero из секций по совпадению `preset.id`, чтобы карусель и Effect Detail могли крутить превью как у ленты.
    func mergingHeroPreviewMediaFromSections() -> EffectsHomePayload {
        guard let hero else { return self }
        let lookup = Self.presetsByIdInSections(sections)
        let enrichedItems = hero.items.map { item in
            let merged = item.preset.fillingPreviewMediaIfMissing(fromSameIdFallback: lookup[item.preset.id])
            return EffectsHomeItem(preset: merged, estimatedCostTokens: item.estimatedCostTokens)
        }
        let newHero = EffectsHeroCarousel(
            sectionId: hero.sectionId,
            title: hero.title,
            subtitle: hero.subtitle,
            aspectRatio: hero.aspectRatio,
            items: enrichedItems
        )
        return EffectsHomePayload(hero: newHero, sections: sections)
    }

    private static func presetsByIdInSections(_ sections: [EffectsHomeSection]) -> [Int: EffectPreset] {
        var map: [Int: EffectPreset] = [:]
        for section in sections {
            for item in section.items {
                map[item.preset.id] = item.preset
            }
        }
        return map
    }
}

extension EffectsHomeItem {
    /// Лог одной плитки каталога: помогает проверить, не остался ли старый MOV/MP4 в памяти/ответе RPC после миграции на WebP.
    func debugLogSummary(context: String, prefix: String = "[effects-preview]") {
        // let p = preset
        // let image = p.previewImageURL?.absoluteString ?? "nil"
        // let motion = p.previewVideoURL?.absoluteString ?? "nil"
        // print("\(prefix)     item context=\(context) id=\(p.id) slug=\(p.slug) title='\(p.title)' aspect=\(p.aspectRatio ?? "nil") poster=\(image) motion=\(motion)")
        _ = context
        _ = prefix
    }
}
