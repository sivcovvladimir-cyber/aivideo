import SwiftUI
import UIKit

struct OnboardingPage {
    let imageName: String
    let title: String
    let description: String
}

// Высота hero как в aiheadshots для видео (`LoopingVideoPlayer.calculateFrameHeight`), но по aspect ratio ассета.
private enum OnboardingHeroLayout {
    static var screenAspectRatio: CGFloat {
        UIScreen.main.bounds.width / UIScreen.main.bounds.height
    }
    
    static func imageAspectRatio(for imageName: String) -> CGFloat {
        guard let img = UIImage(named: imageName), img.size.height > 0 else {
            return 16.0 / 9.0
        }
        return img.size.width / img.size.height
    }
    
    /// Та же логика, что `LoopingVideoPlayer.calculateFrameHeight` — чтобы картинка прижималась к верху и занимала ту же долю экрана, что и видео в старом проекте.
    static func frameHeight(forImageNamed imageName: String) -> CGFloat {
        let contentAspect = imageAspectRatio(for: imageName)
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
    
    // Картинки: aivideo/Assets.xcassets/Onboarding/Onboarding{1,2,3}.imageset
    let pages: [OnboardingPage] = [
        OnboardingPage(imageName: "Onboarding1", title: "onboarding_step1_title".localized, description: "onboarding_step1_desc".localized),
        OnboardingPage(imageName: "Onboarding2", title: "onboarding_step2_title".localized, description: "onboarding_step2_desc".localized),
        OnboardingPage(imageName: "Onboarding3", title: "onboarding_step3_title".localized, description: "onboarding_step3_desc".localized)
    ]
    
    /// Картинка с `scaledToFill` якорится к верху, чтобы не «подрезать» верх по центру как у видео.
    @ViewBuilder
    private func onboardingHeroImage(imageName: String, height: CGFloat) -> some View {
        GeometryReader { geo in
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
    
    var body: some View {
        ZStack {
            OnboardingVisual.backdrop
                .ignoresSafeArea()
            
            // Hero: без центрирования fill — иначе `scaledToFill` режет верх/низ симметрично и кажется, что верх «уехал» за экран.
            VStack(spacing: 0) {
                onboardingHeroImage(
                    imageName: pages[currentPage].imageName,
                    height: OnboardingHeroLayout.frameHeight(forImageNamed: pages[currentPage].imageName)
                )
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
            
            // Скрим под текст/кнопку — всегда тёмный fade (см. `onboardingBottomScrim`).
            VStack {
                Spacer()
                onboardingBottomScrim
            }
            
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
                                _ = await PaywallCacheManager.shared.loadAndCachePaywallDataAsync()
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
                .padding(.bottom, AppTheme.Spacing.screenVertical)
            }
        }
        .background(OnboardingVisual.backdrop)
        .environment(\.colorScheme, .dark)
    }
}
