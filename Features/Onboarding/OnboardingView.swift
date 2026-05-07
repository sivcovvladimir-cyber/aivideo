import SwiftUI
import UIKit
import AVFoundation

struct OnboardingPage {
    let title: String
    let description: String
}

// Высота hero как на paywall: считаем долю экрана от aspect ratio видео-контента.
private enum OnboardingHeroLayout {
    static var screenAspectRatio: CGFloat {
        UIScreen.main.bounds.width / UIScreen.main.bounds.height
    }

    static func videoAspectRatio(for videoURL: URL?) -> CGFloat {
        guard let videoURL else { return 16.0 / 9.0 }
        let asset = AVURLAsset(url: videoURL)
        let tracks = asset.tracks(withMediaType: .video)
        guard let track = tracks.first else { return 16.0 / 9.0 }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let w = abs(transformed.width)
        let h = abs(transformed.height)
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    static func frameHeight(forVideoURL videoURL: URL?) -> CGFloat {
        let contentAspect = videoAspectRatio(for: videoURL)
        let aspectRatioRatio = screenAspectRatio / contentAspect

        let percentage: CGFloat
        if aspectRatioRatio < 0.75 {
            percentage = 0.75
        } else if aspectRatioRatio > 0.85 {
            percentage = 0.85
        } else {
            percentage = ceil(aspectRatioRatio * 100) / 100
        }
        
        return UIScreen.main.bounds.height * percentage
    }
}

// Onboarding hero видео: сначала ищем файл в Bundle, иначе materialize MP4 из Data Catalog (`onboarding1-3`).
private enum OnboardingHeroTopMedia {
    private static var cachedDataCatalogVideoFileURLByName: [String: URL] = [:]

    static func heroVideoPlaybackURL(forPage index: Int) -> URL? {
        let baseName = "onboarding\(index + 1)"
        if let u = Bundle.main.url(forResource: baseName, withExtension: "mp4") { return u }
        if let u = Bundle.main.url(forResource: baseName, withExtension: "mov") { return u }
        return materializedMP4FromDataCatalogIfNeeded(baseName: baseName)
    }

    private static func materializedMP4FromDataCatalogIfNeeded(baseName: String) -> URL? {
        if let cached = cachedDataCatalogVideoFileURLByName[baseName],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let data = rawDataCatalogData(baseName: baseName),
              dataLooksLikeMP4OrMOV(data) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding_\(baseName)_from_datacatalog.mp4")
        do {
            try data.write(to: url, options: .atomic)
            cachedDataCatalogVideoFileURLByName[baseName] = url
            return url
        } catch {
            return nil
        }
    }

    private static func rawDataCatalogData(baseName: String) -> Data? {
        NSDataAsset(name: baseName)?.data
            ?? NSDataAsset(name: "Onboarding/\(baseName)")?.data
    }

    private static func dataLooksLikeMP4OrMOV(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        return data.subdata(in: 4 ..< 8) == Data([0x66, 0x74, 0x79, 0x70]) // "ftyp"
    }
}

// Совпадает с `PaywallView.paywallBottomChromePadding`: игнор safe area снизу + явный inset (home indicator + 8pt), иначе кнопка «парит» выше, чем на пейволе.
private enum OnboardingBottomChrome {
    #if canImport(UIKit)
    static func keyWindowSafeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return 0 }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
    #endif

    static func padding(safeAreaBottom: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let bottom = max(safeAreaBottom, keyWindowSafeAreaBottom())
        #else
        let bottom = safeAreaBottom
        #endif
        return max(16, bottom + 8)
    }

    /// На сколько опустить нижний градиентный скрим: столько же пикселей, на сколько опустилась CTA после перехода с `screenVertical` на `padding` (как на пейволе).
    static func scrimDropOffset(safeAreaBottom: CGFloat, legacyVerticalPadding: CGFloat = AppTheme.Spacing.screenVertical) -> CGFloat {
        #if canImport(UIKit)
        let bottomInset = max(safeAreaBottom, keyWindowSafeAreaBottom())
        #else
        let bottomInset = safeAreaBottom
        #endif
        let oldClearanceFromPhysicalBottom = bottomInset + legacyVerticalPadding
        let newClearance = max(16, bottomInset + 8)
        return max(0, oldClearanceFromPhysicalBottom - newClearance)
    }
}

// Онбординг всегда визуально как тёмная тема: фон/скрим не зависят от выбранной темы приложения, заголовок без градиента — читаемость на коллаже.
private enum OnboardingVisual {
    /// Совпадает с `AppTheme.Colors` для `.dark` (`mainBackgroundRGB`).
    static let backdrop = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let title = Color.white
    static let subtitle = Color.white.opacity(0.72)
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0

    /// Нижний скрим: всегда затемнение к тёмному фону (не белая вуаль из light-темы).
    private var onboardingBottomScrim: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: OnboardingVisual.backdrop.opacity(0), location: 0),
                .init(color: OnboardingVisual.backdrop.opacity(0.3), location: 0.2),
                .init(color: OnboardingVisual.backdrop, location: 0.75),
                .init(color: OnboardingVisual.backdrop, location: 1),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 360)
    }
    
    // Шаги онбординга: hero-видео `onboarding1-3` из ассетов + текстовые блоки.
    let pages: [OnboardingPage] = [
        OnboardingPage(title: "onboarding_step1_title".localized, description: "onboarding_step1_desc".localized),
        OnboardingPage(title: "onboarding_step2_title".localized, description: "onboarding_step2_desc".localized),
        OnboardingPage(title: "onboarding_step3_title".localized, description: "onboarding_step3_desc".localized)
    ]

    /// Hero-видео onboarding по текущей странице; fallback на старые изображения, если видео недоступно.
    @ViewBuilder
    private func onboardingHeroMedia(pageIndex: Int) -> some View {
        let videoURL = OnboardingHeroTopMedia.heroVideoPlaybackURL(forPage: pageIndex)
        let height = OnboardingHeroLayout.frameHeight(forVideoURL: videoURL)
        if let videoURL {
            LoopingVideoPlayer(playbackURL: videoURL, playbackVolume: 0.07)
                .frame(height: height)
                .frame(maxWidth: .infinity)
        } else {
            let fallbackName = "Onboarding\(pageIndex + 1)"
            GeometryReader { geo in
                Image(fallbackName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                OnboardingVisual.backdrop
                    .ignoresSafeArea()

                // Hero: без центрирования fill — иначе `scaledToFill` режет верх/низ симметрично и кажется, что верх «уехал» за экран.
                VStack(spacing: 0) {
                    onboardingHeroMedia(pageIndex: currentPage)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.85),
                                .init(color: .clear, location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

                // Скрим под текст/кнопку — всегда тёмный fade (см. `onboardingBottomScrim`); сдвиг вниз синхронизирован с опусканием CTA.
                VStack {
                    Spacer()
                    onboardingBottomScrim
                        .offset(y: OnboardingBottomChrome.scrimDropOffset(safeAreaBottom: geo.safeAreaInsets.bottom))
                }
                .ignoresSafeArea(edges: .bottom)

                VStack {
                    Spacer()

                    VStack(spacing: 20) {
                        // Заголовок и описание ближе друг к другу; до кнопки оставляем прежний интервал.
                        VStack(spacing: 8) {
                            Text(pages[currentPage].title)
                                .font(AppTheme.Typography.title)
                                .foregroundColor(OnboardingVisual.title)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .multilineTextAlignment(.center)
                            Text(pages[currentPage].description)
                                .font(AppTheme.Typography.body)
                                .foregroundColor(OnboardingVisual.subtitle)
                                .lineLimit(2)
                                .minimumScaleFactor(0.88)
                                .multilineTextAlignment(.center)
                        }
                        Button(action: {
                            if currentPage < pages.count - 1 {
                                currentPage += 1
                            } else {
                                Task {
                                    await AppAnalyticsService.shared.reportOnboardingCompleted()
                                }

                                appState.hasCompletedOnboarding = true
                                // Не ждём Adapty/paywall: сразу на главный; превью и paywall догоняют в фоне (оверлей покажем, когда конфиг будет).
                                appState.currentScreen = .effectsHome

                                Task { @MainActor [weak appState] in
                                    _ = await appState?.ensurePaywallPreloaded()
                                    guard let appState else { return }
                                    appState.tokenWallet.syncWithCurrentConfig()
                                    let showPaywall = PaywallCacheManager.shared.paywallConfig?.logic.showPaywallAfterOnboarding ?? false
                                    print("🧩 [Onboarding] paywall decision: showPaywallAfterOnboarding=\(showPaywall)")
                                    if showPaywall {
                                        appState.presentPaywallFullscreen(placementTier: .standard)
                                    }
                                }
                            }
                        }) {
                            Text(currentPage == pages.count - 1 ? "lets_start".localized : "next".localized)
                                .font(AppTheme.Typography.button)
                                .foregroundColor(AppTheme.Colors.onPrimaryText)
                                .primaryCTAChrome(isEnabled: true, fill: .productGradient)
                        }
                        .appPlainButtonStyle()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, OnboardingBottomChrome.padding(safeAreaBottom: geo.safeAreaInsets.bottom))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
            }
            .background(OnboardingVisual.backdrop)
            .environment(\.colorScheme, .dark)
        }
        .onAppear {
            appState.ensureOnboardingHomeWarmupStarted()
        }
    }
}
