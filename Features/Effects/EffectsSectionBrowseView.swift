import SwiftUI

/// Сетка всех эффектов одной секции каталога (переход с «View all» на главной).
struct EffectsSectionBrowseView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var paywallCache = PaywallCacheManager.shared

    let section: EffectsHomeSection

    /// Тот же флаг, что и рельсы на главной: `paywall_config.logic` / Adapty.
    private var effectsCatalogAllowsMotionPreview: Bool {
        paywallCache.paywallConfig?.logic.effectsCatalogAllowsMotionPreview ?? false
    }
    
    /// Каталог Effects (main + view all): показывать ли постер до старта motion. Работает только при включённом `effectsCatalogAllowsMotionPreview`.
    private var effectsCatalogShowPosterBeforeMotion: Bool {
        paywallCache.paywallConfig?.logic.effectsCatalogShowPosterBeforeMotion ?? false
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    private let gridAutoplayLimit = 6
    @State private var gridVisibleAutoplayQueue: [String] = []

    private var browseTailWarmupIdentity: String {
        let videos = section.items.compactMap { $0.preset.previewVideoURL?.absoluteString }.joined(separator: ",")
        let posters = section.items.compactMap { $0.preset.previewImageURL?.absoluteString }.joined(separator: ",")
        return "browse-tail|\(section.id)|v:\(videos)|p:\(posters)"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopNavigationBar(
                    title: section.title,
                    showBackButton: true,
                    backgroundColor: AppTheme.Colors.background,
                    onBackTap: {
                        appState.currentScreen = .effectsHome
                    }
                )

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        // В view-all включаем autoplay только для последних видимых N карточек:
                        // при скролле новые видимые ячейки вытесняют старые, чтобы playback-слоты не "залипали" вне экрана.
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            let autoplayKey = "\(item.id)"
                            EffectCatalogRailCard(
                                item: item,
                                layout: .gridTwoColumnCell(
                                    aspectWidthOverHeight: CGFloat(item.preset.previewLayoutAspectWidthOverHeight)
                                ),
                                allowsMotionPreview: effectsCatalogAllowsMotionPreview,
                                showsPosterBeforeMotion: effectsCatalogShowPosterBeforeMotion,
                                autoplayEnabled: effectsCatalogAllowsMotionPreview && gridVisibleAutoplayQueue.contains(autoplayKey),
                                onVisibilityChanged: { isVisible in
                                    updateGridAutoplayVisibility(key: autoplayKey, isVisible: isVisible)
                                    if isVisible {
                                        scheduleCatalogPriorityUpdate(previewVideoURL: item.preset.previewVideoURL)
                                    }
                                }
                            ) {
                                let presets = section.items.map(\.preset)
                                appState.openEffectDetail(item.preset, carouselPresets: presets, dismissTo: .effectsBrowse(section))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                }
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .themeAware()
            .themeAnimation()
        }
        .task(id: browseTailWarmupIdentity) {
            await EffectsMediaOrchestrator.shared.reevaluateCatalogTailWarmupForBrowse(section: section)
        }
    }

    private func updateGridAutoplayVisibility(key: String, isVisible: Bool) {
        gridVisibleAutoplayQueue.removeAll { $0 == key }
        if isVisible {
            gridVisibleAutoplayQueue.append(key)
            if gridVisibleAutoplayQueue.count > gridAutoplayLimit {
                gridVisibleAutoplayQueue = Array(gridVisibleAutoplayQueue.suffix(gridAutoplayLimit))
            }
        }
    }

    private func scheduleCatalogPriorityUpdate(previewVideoURL: URL?) {
        Task {
            await EffectsMediaOrchestrator.shared.scheduleCatalogCurrentPresetPriority(
                previewVideoURL: previewVideoURL
            )
        }
    }
}
