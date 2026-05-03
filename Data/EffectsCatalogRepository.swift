import Foundation

protocol EffectsCatalogRepository {
    func loadEffectsHome() async throws -> EffectsHomePayload
}

/*
/// Локальный mock каталога (раньше подставлялся в `EffectsHomeView`). Сейчас Home берёт `AppState.sessionEffectsHomePayload` после `SupabaseSessionBootstrap` на сплеше — мок оставлен для ручных тестов UI при необходимости.
final class MockEffectsCatalogRepository: EffectsCatalogRepository {
    func loadEffectsHome() async throws -> EffectsHomePayload {
        makeEffectsHomePayload()
    }

    // Локальный mock-каталог собирается мгновенно, поэтому даём синхронный snapshot для первого кадра главного экрана без скелетон→контент рывка.
    func makeEffectsHomePayload() -> EffectsHomePayload {
        let presets = Self.makePresets()
        let calculator = GenerationCostCalculator()

        func item(for preset: EffectPreset) -> EffectsHomeItem {
            EffectsHomeItem(
                preset: preset,
                estimatedCostTokens: calculator.effectGenerationCost(presetTokenCost: preset.tokenCost)
            )
        }

        let heroItems = presets.prefix(3).map { item(for: $0) }
        let hero = EffectsHeroCarousel(
            sectionId: "hero",
            title: "effects_home_hero_title".localized,
            subtitle: nil,
            aspectRatio: "16:9",
            items: heroItems
        )

        let railA = Array(presets.dropFirst(3).prefix(4)).map { item(for: $0) }
        let railB = Array(presets.dropFirst(7)).map { item(for: $0) }

        return EffectsHomePayload(
            hero: hero,
            sections: [
                EffectsHomeSection(
                    id: "popular",
                    title: "effects_popular_section".localized,
                    subtitle: nil,
                    sort: 0,
                    isFeatured: true,
                    aspectRatio: "9:16",
                    items: railA
                ),
                EffectsHomeSection(
                    id: "very_hot",
                    title: "effects_very_hot_section".localized,
                    subtitle: nil,
                    sort: 1,
                    isFeatured: false,
                    aspectRatio: "9:16",
                    items: railB
                )
            ]
        )
    }

    private static func makePresets() -> [EffectPreset] {
        [
            makePreset(id: 1, slug: "neon-portrait", title: "Neon Portrait", isProOnly: false),
            makePreset(id: 2, slug: "cinematic-zoom", title: "Cinematic Zoom", isProOnly: true),
            makePreset(id: 3, slug: "retro-wave", title: "Retro Wave", isProOnly: false),
            makePreset(id: 4, slug: "fashion-shot", title: "Fashion Shot", isProOnly: true),
            makePreset(id: 5, slug: "anime-energy", title: "Anime Energy", isProOnly: false),
            makePreset(id: 6, slug: "movie-poster", title: "Movie Poster", isProOnly: false),
            makePreset(id: 7, slug: "glitch-dance", title: "Glitch Dance", isProOnly: true),
            makePreset(id: 8, slug: "soft-light", title: "Soft Light", isProOnly: false)
        ]
    }

    private static func makePreset(id: Int, slug: String, title: String, isProOnly: Bool) -> EffectPreset {
        return EffectPreset(
            id: id,
            slug: slug,
            title: title,
            description: nil,
            promptTemplate: nil,
            providerTemplateId: nil,
            tokenCost: nil,
            isProOnly: isProOnly,
            aspectRatio: "9:16",
            durationSeconds: nil,
            previewImageURL: nil,
            previewVideoURL: nil
        )
    }
}
*/
