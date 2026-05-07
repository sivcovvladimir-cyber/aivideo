import SwiftUI
import StoreKit

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dynamicModalManager: DynamicModalManager
    @ObservedObject private var generationJob = GenerationJobService.shared
    
    var body: some View {
        ZStack {
            Group {
                switch appState.currentScreen {
                case .splash:
                    SplashView()
                case .onboarding:
                    OnboardingView()
                case .effectsHome:
                    EffectsHomeView()
                case .effectsSectionBrowse(let section):
                    EffectsSectionBrowseView(section: section)
                case .effectDetail:
                    EffectDetailView()
                case .generation:
                    PromptGenerationView()
                case .gallery:
                    GalleryView()
                case .settings:
                    SettingsView()
                }
            }

            if appState.isPaywallOverlayPresented {
                PaywallView(
                    closeOnlyDismissesSheet: true,
                    externalDismiss: { appState.dismissPaywallOverlay() }
                )
                .environmentObject(appState)
                // Без выезда снизу: короткое появление/исчезновение по opacity (как обычный оверлей).
                .transition(.opacity)
                .zIndex(50_000)
            }
        }
        // `themeAware` на всём `ZStack`, а не только на `Group`: оверлеи (`generation`, success) иначе не получают `colorScheme` из приложения — на blur остаётся «светлый» контраст (белый текст).
        .themeAware()
        .animation(.easeOut(duration: 0.22), value: appState.isPaywallOverlayPresented)
        .overlay {
            ZStack {
                if let media = appState.generationSuccessDetailMedia {
                    GenerationSuccessDetailOverlay(media: media)
                        .environmentObject(appState)
                        .transition(.opacity)
                        .zIndex(60_000)
                }
                if generationJob.isOverlayVisible {
                    GenerationProgressOverlayView()
                        .zIndex(55_000)
                }
            }
        }
        .alert(isPresented: $appState.showNetworkAlert) {
            Alert(
                title: Text("network_error".localized),
                message: Text(appState.networkAlertMessage),
                dismissButton: .default(Text("retry".localized)) {
                    appState.loadInitialData()
                }
            )
        }
        .dynamicModal(manager: dynamicModalManager)
    }
}

// MARK: - Результат генерации на весь экран (если пользователь дождался на оверлее)

/// Дублируем контракт `GalleryView` → `MediaDetailView`: те же избранное и действия, чтобы поведение совпадало с библиотекой.
/// После генерации показываем только **этот** результат — без карусели по всей галерее и без счётчика «1 из N» (как в `ailogos`: одиночный просмотр, не лента).
private struct GenerationSuccessDetailOverlay: View {
    @EnvironmentObject private var appState: AppState
    let media: GeneratedMedia

    @State private var favoriteIds: Set<String> = []

    private let favoriteIdsKey = "gallery_favorite_media_ids"

    var body: some View {
        MediaDetailView(
            allMedia: [media],
            currentMedia: media,
            hideActionButtons: false,
            isEffectReferencePickMode: false,
            onDismiss: {
                appState.dismissGenerationSuccessDetail()
                appState.handleMediaDetailDismissed()
            },
            onEffectReferencePicked: nil,
            showDeleteInTopBar: true,
            customTrailingActionIcon: { current in
                favoriteIds.contains(current.id) ? "Star Fill" : "Star"
            },
            customTrailingActionIconColor: { current in
                favoriteIds.contains(current.id) ? .yellow : AppTheme.Colors.textPrimary
            },
            customTrailingActionColor: Color.customPurple.opacity(0.72),
            customTrailingAction: { current in
                toggleFavorite(for: current)
            }
        )
        .environmentObject(appState)
        .onAppear {
            loadFavorites()
        }
    }

    private func loadFavorites() {
        let raw = UserDefaults.standard.string(forKey: favoriteIdsKey) ?? ""
        favoriteIds = Set(raw.split(separator: ",").map(String.init))
    }

    private func saveFavorites() {
        let snapshot = favoriteIds.sorted().joined(separator: ",")
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(snapshot, forKey: favoriteIdsKey)
        }
    }

    private func toggleFavorite(for item: GeneratedImage) {
        let isCurrentlyFavorite = favoriteIds.contains(item.id)
        if isCurrentlyFavorite {
            favoriteIds.remove(item.id)
            saveFavorites()
            return
        }
        favoriteIds.insert(item.id)
        saveFavorites()
        Task.detached(priority: .utility) {
            SupabaseService.shared.submitShowcaseCandidate(generationId: item.id, publishNow: false) { _ in }
        }
    }
}

