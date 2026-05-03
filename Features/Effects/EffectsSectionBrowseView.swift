import SwiftUI

/// Сетка всех эффектов одной секции каталога (переход с «View all» на главной).
struct EffectsSectionBrowseView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var tokenWallet = TokenWalletService.shared

    let section: EffectsHomeSection

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopNavigationBar(
                    title: section.title,
                    showBackButton: true,
                    customRightContent: AnyView(
                        ProStatusBadge(
                            tokenBalance: tokenWallet.balance,
                            action: { appState.presentPaywallFullscreen() }
                        )
                    ),
                    backgroundColor: AppTheme.Colors.background,
                    onBackTap: {
                        appState.currentScreen = .effectsHome
                    }
                )

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(section.items) { item in
                            EffectCatalogRailCard(
                                item: item,
                                layout: .gridTwoColumnCell(
                                    aspectWidthOverHeight: CGFloat(item.preset.previewLayoutAspectWidthOverHeight)
                                )
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
    }

}
