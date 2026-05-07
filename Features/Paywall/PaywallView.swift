import SwiftUI
import Adapty
import UIKit
import AVFoundation
import AVKit
import StoreKit
import WebKit

// Высота hero как на онбординге: aspect ratio ассета + та же формула доли экрана.
private enum PaywallHeroLayout {
    static var screenAspectRatio: CGFloat {
        UIScreen.main.bounds.width / UIScreen.main.bounds.height
    }

    static func imageAspectRatio(for image: UIImage?) -> CGFloat {
        guard let img = image, img.size.height > 0 else { return 16.0 / 9.0 }
        return img.size.width / img.size.height
    }

    static func frameHeight(for image: UIImage?) -> CGFloat {
        let contentAspect = imageAspectRatio(for: image)
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

// Верх paywall: `paywall.mp4|mov` в Copy Bundle Resources; иначе MP4/MOV в Data Catalog (`NSDataAsset`); иначе WebP в том же ассете (не путаем с видео по сигнатуре `ftyp`).
private enum PaywallHeroTopMedia {
    private static let rawDataCatalogData: Data? = NSDataAsset(name: "paywall")?.data
        ?? NSDataAsset(name: "Paywall/paywall")?.data

    private static var cachedDataCatalogVideoFileURL: URL?

    /// Воспроизводимый URL: свободный файл в bundle или временная копия из Data Catalog (AVPlayer не читает байты ассета напрямую).
    static var heroVideoPlaybackURL: URL? {
        if let u = Bundle.main.url(forResource: "paywall", withExtension: "mp4") { return u }
        if let u = Bundle.main.url(forResource: "paywall", withExtension: "mov") { return u }
        return materializedMP4FromDataCatalogIfNeeded()
    }

    private static func materializedMP4FromDataCatalogIfNeeded() -> URL? {
        if let cached = cachedDataCatalogVideoFileURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let data = rawDataCatalogData, dataLooksLikeMP4OrMOV(data) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paywall_hero_from_datacatalog.mp4")
        do {
            try data.write(to: url, options: .atomic)
            cachedDataCatalogVideoFileURL = url
            return url
        } catch {
            return nil
        }
    }

    private static func dataLooksLikeMP4OrMOV(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        return data.subdata(in: 4 ..< 8) == Data([0x66, 0x74, 0x79, 0x70])
    }

    /// Данные для WK WebP: только если это не контейнер MP4/MOV в том же Data Set.
    static var webpData: Data? {
        guard let d = rawDataCatalogData, !dataLooksLikeMP4OrMOV(d) else { return nil }
        return d
    }

    static var webpImage: UIImage? {
        guard let data = webpData else { return nil }
        return UIImage(data: data)
    }

    static var hasHero: Bool { heroVideoPlaybackURL != nil || webpData != nil }

    /// Та же геометрия, что у онбординга/видео: доля высоты экрана от aspect ratio контента.
    static func heroFrameHeight() -> CGFloat {
        if let url = heroVideoPlaybackURL {
            let asset = AVURLAsset(url: url)
            let tracks = asset.tracks(withMediaType: .video)
            guard let track = tracks.first else {
                return UIScreen.main.bounds.height * 0.45
            }
            let size = track.naturalSize.applying(track.preferredTransform)
            let w = abs(size.width)
            let h = abs(size.height)
            guard h > 0 else { return UIScreen.main.bounds.height * 0.45 }
            let contentAspect = w / h
            let screenAspect = UIScreen.main.bounds.width / UIScreen.main.bounds.height
            let r = screenAspect / contentAspect
            let percentage: CGFloat
            if r < 0.75 {
                percentage = 0.75
            } else if r > 0.85 {
                percentage = 0.85
            } else {
                percentage = ceil(r * 100) / 100
            }
            return UIScreen.main.bounds.height * percentage
        }
        if let img = webpImage {
            return PaywallHeroLayout.frameHeight(for: img)
        }
        return 0
    }
}

/// Animated WebP/Data Set показываем через `WKWebView`: `UIImageView` на iOS часто берёт только первый кадр WebP.
private struct AnimatedPaywallWebPView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.loadHTMLString(htmlString(), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlString(), baseURL: nil)
    }

    private func htmlString() -> String {
        let base64 = data.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
          <style>
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
            img { width: 100vw; height: 100vh; object-fit: cover; display: block; }
          </style>
        </head>
        <body><img src="data:image/webp;base64,\(base64)" /></body>
        </html>
        """
    }
}

struct PaywallView: View {
    /// UI-контент пейвола больше не читается из `paywall_config.json`: локальный JSON содержит только логику.
    private let standardPaywallFeatureKeys = [
        "feature_premium_styles",
        "feature_hd_quality",
        "feature_no_watermarks",
        "feature_priority_processing",
        "feature_advanced_editing"
    ]
    /// Если true — закрытие не меняет `currentScreen`, только убирает презентацию (sheet или оверлей).
    var closeOnlyDismissesSheet: Bool = false
    /// Оверлей из `RootView`: закрытие без `Environment.dismiss`, предыдущий экран остаётся под пейволом.
    var externalDismiss: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    init(closeOnlyDismissesSheet: Bool = false, externalDismiss: (() -> Void)? = nil) {
        self.closeOnlyDismissesSheet = closeOnlyDismissesSheet
        self.externalDismiss = externalDismiss
    }

    private func dismissPaywallPresentation() {
        if let externalDismiss {
            externalDismiss()
        } else if closeOnlyDismissesSheet {
            dismiss()
        } else {
            appState.dismissPaywallOverlay()
        }
    }
    @StateObject private var paywallCache = PaywallCacheManager.shared
    @State private var selectedPlan: Int = 0
    @State private var currentCarouselIndex = 0

    @State private var isLoadingConfig = true
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showTrialPlans = true
    
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    private let bottomGradientHeight: CGFloat = 600

    /// Картинка с `scaledToFill` и якорем к верху — как `onboardingHeroImage` в `OnboardingView`.
    @ViewBuilder
    private func paywallHeroWebP(data: Data, height: CGFloat) -> some View {
        GeometryReader { geo in
            AnimatedPaywallWebPView(data: data)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    /// Аналитика + загрузка конфига/продуктов: общая для полноэкранного лоадера и для варианта с hero (видео показываем сразу).
    private func onPaywallContentAppear() {
        Task {
            await AppAnalyticsService.shared.reportPaywallShown()
        }
        let cached = paywallCache.hasCachedData()
        print("[paywall] PaywallView.onAppear: hasCachedData=\(cached) tier=\(paywallCache.currentPlacementTier.rawValue)")
        if cached {
            selectedPlan = paywallCache.getDefaultSelectedPlanIndex()
        }
        loadPaywallData()
    }
    
    var body: some View {
        ZStack {
            // Тот же фон, что у dark-темы приложения — не белый холст в light при открытом пейволе.
            PaywallShellChrome.canvasBackground
                .ignoresSafeArea()
                
            // Без локального hero (только бегущие ряды) — полноэкранный лоадер до прихода конфига/продуктов.
            if isLoadingConfig && !PaywallHeroTopMedia.hasHero {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    Text("loading".localized)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(PaywallPlanTileChrome.title)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // С hero (видео/WebP из Bundle) показываем разметку сразу: видео не ждёт `loadAndCachePaywallData`.
            if !isLoadingConfig || PaywallHeroTopMedia.hasHero {
                // Main content: GeometryReader — корректный `safeAreaInsets.bottom` в оверлее; нижний блок игнорирует safe area снизу и добивает отступ как на storecards (key window fallback).
                GeometryReader { geo in
                ZStack {
                    // Hero: MP4/MOV в bundle или в Data Catalog (копия во temp для AVPlayer), иначе WebP из Data Set.
                    if let heroVideoURL = PaywallHeroTopMedia.heroVideoPlaybackURL {
                        VStack(spacing: 0) {
                            // Paywall hero держим на 7% громкости для единообразия с остальными экранами.
                            LoopingVideoPlayer(playbackURL: heroVideoURL, playbackVolume: 0.07)
                                .frame(height: PaywallHeroTopMedia.heroFrameHeight())
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
                    } else if let heroData = PaywallHeroTopMedia.webpData {
                        VStack(spacing: 0) {
                            paywallHeroWebP(
                                data: heroData,
                                height: PaywallHeroLayout.frameHeight(for: PaywallHeroTopMedia.webpImage)
                            )
                            .allowsHitTesting(false)
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
                    }

                    // Ниже hero — сплошной фон плиток; без hero остаётся прежний полноэкранный вариант.
                    VStack(spacing: 0) {
                        if PaywallHeroTopMedia.hasHero {
                            Spacer()
                                .frame(height: PaywallHeroTopMedia.heroFrameHeight())
                        }
                        AppTheme.Colors.paywallCardBackground
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .ignoresSafeArea()

                    if !PaywallHeroTopMedia.hasHero {
                        paywallAnimatedPreviewRowsBackground
                            .ignoresSafeArea()
                        paywallLoopBottomBackgroundOverlay
                    }

                    // Крестик: слева сверху; выше и светлее — читается на hero в любой теме приложения.
                    VStack {
                        HStack {
                            Button(action: {
                                dismissPaywallPresentation()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(PaywallShellChrome.closeButton)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .appPlainButtonStyle()
                            .padding(.leading, 24)
                            .padding(.top, 4)
                            Spacer()
                        }
                        Spacer()
                    }
                    .zIndex(10) // Поверх hero, градиента и нижнего блока

                    // Затемнение снизу: фиксированные стопы как для dark colorScheme (не ослабляем в light).
                    VStack {
                        Spacer()
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.black.opacity(0), location: 0),
                                .init(color: Color.black.opacity(0.68), location: 0.72),
                                .init(color: Color.black.opacity(0.96), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bottomGradientHeight)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    
                    // Нижний блок: прижат к физическому низу экрана; отступ снизу = home indicator + небольшой зазор (не «висячий» чёрный зазор как при UIKit windows.first).
                    VStack {
                        Spacer()
                        
                        VStack(spacing: 16) {
                            // Заголовок + карусель только для стандартного paywall с подписками.
                            if paywallCache.currentPlacementTier == .standard {
                                VStack(spacing: 8) {
                                    Text(getLocalizedTitle())
                                        .font(AppTheme.Typography.title)
                                        .foregroundColor(PaywallPlanTileChrome.title)
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(2)
                                        .padding(.horizontal, 20)
                                    
                                    TabView(selection: $currentCarouselIndex) {
                                        ForEach(0..<standardPaywallFeatureKeys.count, id: \.self) { index in
                                            Text(standardPaywallFeatureKeys[index].localized)
                                                .font(AppTheme.Typography.body)
                                                .foregroundColor(PaywallPlanTileChrome.title)
                                                .multilineTextAlignment(.center)
                                                .padding(.horizontal, 20)
                                                .tag(index)
                                        }
                                    }
                                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                                    .frame(height: 24)
                                    .onReceive(timer) { _ in
                                        withAnimation(.easeInOut(duration: 0.5)) {
                                            currentCarouselIndex = (currentCarouselIndex + 1) % standardPaywallFeatureKeys.count
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                }
                            } else {
                                VStack(spacing: 12) {
                                    Text(getLocalizedTitle())
                                        .font(AppTheme.Typography.title)
                                        .foregroundColor(PaywallPlanTileChrome.title)
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(2)
                                    
                                    if !getLocalizedSubtitle().isEmpty {
                                        Text(getLocalizedSubtitle())
                                            .font(AppTheme.Typography.body)
                                            .tracking(0.20)
                                            .foregroundColor(PaywallPlanTileChrome.secondary)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(4)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            
                            if !isLoadingConfig {
                                // Карточки
                                let products = getDisplayedProducts()
                                VStack(spacing: 8) {
                                    ForEach(0..<products.count, id: \.self) { index in
                                        let product = products[index]
                                        PricingPlanCard(
                                            title: getProductTitle(product),
                                            subtitle: getProductSubtitle(product),
                                            price: formatPriceForCard(product.localizedPrice),
                                            underPrice: planUnderPrice(for: product),
                                            isPackProduct: isPackProduct(product),
                                            isSelected: selectedPlan == index,
                                            isRecommended: shouldShowMostPopularBadge(for: product, at: index)
                                        )
                                        .onTapGesture { selectedPlan = index }
                                    }
                                }
                                .padding(.horizontal, 24)
                                
                                // Кнопка
                                Button(action: { handleSubscription() }) {
                                    HStack(spacing: 8) {
                                        if isPurchasing {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                                                .scaleEffect(0.8)
                                        }
                                        Text(getButtonTitle())
                                            .font(AppTheme.Typography.button)
                                            .foregroundColor(AppTheme.Colors.onPrimaryText)
                                        if isSelectedPackProduct() {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(AppTheme.Colors.onPrimaryText)
                                        }
                                    }
                                    .primaryCTAChrome(isEnabled: true, fill: .productGradient)
                                }
                                .appPlainButtonStyle()
                                .disabled(isPurchasing)
                                .padding(.horizontal, 24)
                                
                                // Privacy / Restore / Terms — одна строка: иначе длинные локали переносятся на второй ряд.
                                HStack(spacing: 10) {
                                    Button("privacy_policy".localized) { openPrivacyPolicy() }
                                        .font(AppTheme.Typography.caption)
                                        .foregroundColor(PaywallShellChrome.footerLink)
                                        .appPlainButtonStyle()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.62)
                                        .layoutPriority(1)

                                    Button(isRestoring ? "restoring_purchases".localized : "restore".localized) { handleRestore() }
                                        .font(AppTheme.Typography.caption)
                                        .foregroundColor(PaywallShellChrome.footerLink)
                                        .appPlainButtonStyle()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.62)
                                        .layoutPriority(1)
                                        .disabled(isRestoring)
                                        .opacity(isRestoring ? 0.5 : 1.0)

                                    Button("terms_of_service".localized) { openTermsOfService() }
                                        .font(AppTheme.Typography.caption)
                                        .foregroundColor(PaywallShellChrome.footerLink)
                                        .appPlainButtonStyle()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.62)
                                        .layoutPriority(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                            } else {
                                VStack(spacing: 14) {
                                    ProgressView()
                                        .scaleEffect(1.2)
                                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                                    Text("loading".localized)
                                        .font(AppTheme.Typography.body)
                                        .foregroundColor(PaywallPlanTileChrome.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                            }
                        }
                        .padding(.bottom, Self.paywallBottomChromePadding(safeAreaBottom: geo.safeAreaInsets.bottom))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(1)
                    // Второй нижний градиент — закомментирован, т.к. первый (height 320) уже достаточно тёмный.
                    // Раскомментить, если низ снова будет выглядеть светлым.
//                    VStack {
//                        Spacer()
//                        LinearGradient(
//                            colors: [Color.clear, Color.black.opacity(0.5), Color.black.opacity(0.92)],
//                            startPoint: .top,
//                            endPoint: .bottom
//                        )
//                        .frame(height: 260)
//                        .allowsHitTesting(false)
//                    }
//                    .zIndex(0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .onAppear { onPaywallContentAppear() }
        .background(PaywallShellChrome.canvasBackground.ignoresSafeArea())
        .compositingGroup()
        // Пейвол — отдельный тёмный слой: градиенты/материалы как в dark, даже если приложение в light.
        .preferredColorScheme(.dark)
        .themeAnimation()
    }
    
    // MARK: - Private Methods

    #if canImport(UIKit)
    /// Нижний inset (home indicator): foreground scene + key window — в полноэкранном оверлее `windows.first` часто не key и даёт 0 (как в `MediaDetailView`).
    private static func keyWindowSafeAreaBottom() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return 0 }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
    #endif

    /// Отступ снизу для блока тарифов + CTA + ссылки: зона home indicator + небольшой зазор, без «парящего» контента над полоской.
    private static func paywallBottomChromePadding(safeAreaBottom: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let bottom = max(safeAreaBottom, keyWindowSafeAreaBottom())
        #else
        let bottom = safeAreaBottom
        #endif
        return max(16, bottom + 8)
    }

    /// 4 бегущих ряда декоративных превью (ассеты `paywall_logo_*` в каталоге — историческое имя файлов).
    ///
    /// Горизонтальная анимация зациклена без визуального "скачка":
    /// модуль сдвига считается по ширине всей последовательности кадров в ряду.
    private var paywallAnimatedPreviewRowsBackground: some View {
        GeometryReader { geo in
            // По ТЗ: 3 карточки ровно влезают в ширину, карточки квадратные.
            let tileSide = max(24, geo.size.width / 3)
            let rows = 4

            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    movingIconRow(
                        rowIndex: row,
                        tileSide: tileSide,
                        assetNames: paywallAnimatedPreviewAssetNamesForRow(row)
                    )
                    .frame(height: tileSide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.55),
                        .init(color: .clear, location: 0.85)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var paywallLoopBottomBackgroundOverlay: some View {
        GeometryReader { geo in
            // 4 ряда в лупе, spacing=0: последний ряд начинается на 3*tileSide и заканчивается на 4*tileSide.
            let tileSide = max(24, geo.size.width / 3)
            let overlayStartY = tileSide * 3
            let overlayHeight = tileSide
            let overlayColor = AppTheme.Colors.paywallCardBackground

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: overlayStartY)

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.clear, location: 0),
                        .init(color: overlayColor, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: overlayHeight)

                // Ниже градиента держим сплошной фон, чтобы луп точно не просвечивал.
                overlayColor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    private func movingIconRow(rowIndex: Int, tileSide: CGFloat, assetNames: [String]) -> some View {
        // Ряд должен быть бесшовным: если ассеты не добавлены, возвращаем дефолт-значение, чтобы не падало.
        let safeAssetNames = assetNames.isEmpty ? ["appicon"] : assetNames
        let assetCycleCount = max(1, safeAssetNames.count)
        let cycleWidth = CGFloat(assetCycleCount) * tileSide
        let repeatCycles = 3 // чтобы всегда было перекрытие при анимационном "wrap"

        // Уменьшаем/меняем скорость между рядами.
        let speed: CGFloat = 20 - CGFloat(rowIndex) * 1.5
        let goesLeft = rowIndex % 2 == 0

        return TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // shift считается по ширине всей последовательности, чтобы wrap совпадал по рисунку.
            let shift = CGFloat((t * Double(speed)).truncatingRemainder(dividingBy: Double(cycleWidth)))

            // Сдвигаем "середину" последовательности влево на ширину одного цикла.
            // Тогда при shift в диапазоне [0...cycleWidth) всегда есть непрерывное покрытие.
            let offsetBase: CGFloat = -cycleWidth
            let offsetX = goesLeft ? (offsetBase - shift) : (offsetBase + shift)

            HStack(spacing: 0) {
                ForEach(0..<(assetCycleCount * repeatCycles), id: \.self) { idx in
                    let name = safeAssetNames[idx % assetCycleCount]
                    Image(name)
                        .resizable()
                        .scaledToFit()
                        // Вертикальные поля внутри квадрата (2px), чтобы превью не прилипало к краям.
                        .padding(.vertical, 2)
                        .frame(width: tileSide, height: tileSide)
                }
            }
            .offset(x: offsetX)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
    }

    // Получаем 4 уникальных ассета для конкретного ряда.
    // 0 -> 1..4, 1 -> 5..8, 2 -> 9..12, 3 -> 13..16
    private func paywallAnimatedPreviewAssetNamesForRow(_ rowIndex: Int) -> [String] {
        let base = rowIndex * 4
        return (1...4).map { i in
            "paywall_logo_\(base + i)"
        }
    }
    
    /// Снимок для отладки: не вызывать из `body` на каждый кадр — только из `loadPaywallData` / колбэков.
    private func logPaywallDisplaySnapshot(_ reason: String) {
        let tier = paywallCache.currentPlacementTier
        let pro = appState.isProUser
        let rawCount = paywallCache.productsCache.count
        let displayed = getDisplayedProducts()
        let ids = displayed.map(\.vendorProductId)
        let planIds = paywallCache.paywallConfig?.planIds.map { "\($0)" } ?? "nil"
        let purchaseIds = paywallCache.paywallConfig?.purchasePlanIds.map { "\($0)" } ?? "nil"
        let order = paywallCache.productIdsOrder
        print("[paywall] PaywallView.snapshot(\(reason)): tier=\(tier.rawValue) isProUser=\(pro) rawProducts=\(rawCount) displayed=\(displayed.count) ids=\(ids) planIds=\(planIds) purchasePlanIds=\(purchaseIds) productIdsOrder=\(order)")
    }

    /// Продукты для отображения в порядке конфига (planIds/purchasePlanIds) или в порядке, как вернул Adapty.
    private func getDisplayedProducts() -> [ProductInfo] {
        // Dictionary.values не гарантирует стабильный порядок → приводим к детерминированному.
        let allProducts = Array(paywallCache.productsCache.values)
            .sorted { $0.vendorProductId < $1.vendorProductId }
        let subscriptionProducts = allProducts.filter { $0.vendorProductId.hasPrefix("premium_") }
        let packProducts = allProducts.filter { isPackProduct($0) }
        let list: [ProductInfo]
        let orderIds: [String]
        switch paywallCache.currentPlacementTier {
        case .standard:
            list = subscriptionProducts.isEmpty ? allProducts : subscriptionProducts
            orderIds = paywallCache.paywallConfig?.planIds ?? []
        case .proUpsell:
            list = packProducts.isEmpty ? allProducts : packProducts
            orderIds = paywallCache.paywallConfig?.purchasePlanIds ?? []
        }
        
        func sortedByOrder(_ products: [ProductInfo], ids: [String]) -> [ProductInfo] {
            let idSet = Set(products.map(\.vendorProductId))
            let fallbackOrder = paywallCache.productIdsOrder.filter { idSet.contains($0) }
            let order = ids.isEmpty ? fallbackOrder : ids
            if order.isEmpty { return products }
            var byId: [String: ProductInfo] = [:]
            for p in products { byId[p.vendorProductId] = p }
            var result: [ProductInfo] = []
            for id in order {
                if let p = byId[id] { result.append(p) }
            }
            // Если ids заданы, но ни один не совпал с продуктами — считаем, что конфиг не соответствует vendorProductId.
            // В этом случае используем стабильный fallback из productIdsOrder.
            if !ids.isEmpty, result.isEmpty, !fallbackOrder.isEmpty {
                for id in fallbackOrder {
                    if let p = byId[id] { result.append(p) }
                }
            }
            for p in products where !result.contains(where: { $0.vendorProductId == p.vendorProductId }) {
                result.append(p)
            }
            return result
        }
        return sortedByOrder(list, ids: orderIds)
    }
    
    private func openTermsOfService() {
        if let urlString = ConfigurationManager.shared.getValue(for: .termsOfServiceURL),
           let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func openPrivacyPolicy() {
        if let urlString = ConfigurationManager.shared.getValue(for: .privacyPolicyURL),
           let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func loadPaywallData() {
        // Если кэш есть — показываем его мгновенно, не ждём сети
        if paywallCache.hasCachedData() {
            print("[paywall] PaywallView.loadPaywallData: ветка мгновенного UI (кэш есть)")
            isLoadingConfig = false
            selectedPlan = paywallCache.getDefaultSelectedPlanIndex()
            logPaywallDisplaySnapshot("after instant cache")
            // Двухфазный refresh: сначала быстрый cache-first, затем принудительный revalidate из сети.
            Task {
                let warmSuccess = await paywallCache.loadAndCachePaywallDataAsync(
                    forceRefresh: false,
                    updatesLoadingIndicator: false
                )
                await MainActor.run {
                    print("[paywall] PaywallView.loadPaywallData: фоновый cache-first завершён success=\(warmSuccess)")
                    if warmSuccess {
                        self.selectedPlan = self.paywallCache.getDefaultSelectedPlanIndex()
                        self.logPaywallDisplaySnapshot("after background cache-first refresh")
                    }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                let forceSuccess = await paywallCache.loadAndCachePaywallDataAsync(
                    forceRefresh: true,
                    updatesLoadingIndicator: false
                )
                await MainActor.run {
                    print("[paywall] PaywallView.loadPaywallData: фоновый force-refresh завершён success=\(forceSuccess)")
                    if forceSuccess {
                        self.selectedPlan = self.paywallCache.getDefaultSelectedPlanIndex()
                        self.logPaywallDisplaySnapshot("after background force refresh")
                    }
                }
            }
            return
        }
        
        // Кэша нет — показываем лоадер и ждём
        print("[paywall] PaywallView.loadPaywallData: ждём первую загрузку (кэша нет)")
        paywallCache.loadAndCachePaywallData { success in
            DispatchQueue.main.async {
                self.isLoadingConfig = false
                print("[paywall] PaywallView.loadPaywallData: первая загрузка success=\(success) isLoadingConfig→false")
                if success {
                    self.selectedPlan = self.paywallCache.getDefaultSelectedPlanIndex()
                }
                self.logPaywallDisplaySnapshot("after first load")
            }
        }
    }
    
    private func getLocalizedTitle() -> String {
        if paywallCache.currentPlacementTier == .proUpsell {
            return "need_more_generations".localized
        }
        return "upgrade_to_pro".localized
    }
    
    private func getLocalizedSubtitle() -> String {
        if paywallCache.currentPlacementTier == .proUpsell {
            return "buy_prem_pack".localized
        }
        return ""
    }
    
    private func getProductTitle(_ product: ProductInfo) -> String {
        // Для разовых пакетов показываем понятный CTA-тайтл: что именно пользователь получает за покупку.
        if isPackProduct(product),
           let count = paywallCache.generationLimit(for: product.vendorProductId, title: product.localizedTitle) {
            return "pack_get_format".localized(with: count)
        }
        // Для подписок используем единые локализованные названия, чтобы UI не зависел от store title.
        if let cadence = subscriptionCadence(for: product) {
            switch cadence {
            case .annual: return "paywall_plan_annual".localized
            case .monthly: return "paywall_plan_monthly".localized
            case .weekly: return "paywall_plan_weekly".localized
            }
        }
        return product.localizedTitle
    }

    private enum SubscriptionCadence {
        case annual
        case monthly
        case weekly
    }

    private func subscriptionCadence(for product: ProductInfo) -> SubscriptionCadence? {
        guard !isPackProduct(product) else { return nil }
        if let period = product.subscriptionPeriod?.lowercased() {
            if period.contains("year") { return .annual }
            if period.contains("month") { return .monthly }
            if period.contains("week") { return .weekly }
        }
        let id = product.vendorProductId.lowercased()
        if id.contains("annual") || id.contains("year") { return .annual }
        if id.contains("monthly") || id.contains("month") { return .monthly }
        if id.contains("weekly") || id.contains("week") { return .weekly }
        return nil
    }
    
    private func getProductSubtitle(_ product: ProductInfo) -> String {
        if product.isTrial {
            if let trialPeriod = product.trialPeriod {
                return trialPeriod.localized
            } else {
                return "3_day_free_trial".localized
            }
        } else if isPackProduct(product) {
            // Пакеты: скидка относительно самого дорогого по цене за генерацию
            let packProducts = getDisplayedProducts()
            let savings = calculatePackSavingsPercentage(for: product, allPacks: packProducts)
            if savings > 0 { return "-\(savings)%" }
        } else if product.vendorProductId.contains("annual") {
            // Годовая: показываем «Save N%» (локализовано), а не «-N%» — слово помещается и читается лучше.
            let savings = calculateSavingsPercentage(for: product)
            if savings > 0 { return "paywall_save_percent_format".localized(with: savings) }
        }
        return ""
    }
    
    /// Под ценой: лимит из конфига показываем как число токенов + звезда (не слово «генераций»); иначе подпись периода.
    private func planUnderPrice(for product: ProductInfo) -> PlanUnderPrice {
        if isPackProduct(product) { return .none }
        if let count = paywallCache.generationLimit(for: product.vendorProductId, title: product.localizedTitle) {
            return .tokenCount(count)
        }
        if let period = product.subscriptionPeriod, !period.isEmpty {
            switch period {
            case "year":  return .caption("per_year".localized)
            case "week":  return .caption("per_week".localized)
            case "month": return .caption("per_month".localized)
            default:      return .caption(period)
            }
        }
        if product.vendorProductId.contains("annual") { return .caption("per_year".localized) }
        if product.vendorProductId.contains("weekly") { return .caption("per_week".localized) }
        if product.vendorProductId.contains("month") { return .caption("per_month".localized) }
        return .caption("subscription".localized)
    }
    
    private func shouldShowMostPopularBadge(for product: ProductInfo, at index: Int) -> Bool {
        _ = product
        return index == 0
    }
    
    /// Процент скидки для годовой подписки относительно еженедельной (52 нед).
    private func calculateSavingsPercentage(for annualProduct: ProductInfo) -> Int {
        let products = paywallCache.getPaywallProducts()
        guard let weeklyProduct = products.first(where: { $0.vendorProductId.contains("weekly") && !$0.isTrial }) else { return 0 }
        let annualPrice = extractPriceValue(from: annualProduct.localizedPrice)
        let weeklyPrice = extractPriceValue(from: weeklyProduct.localizedPrice)
        guard annualPrice > 0, weeklyPrice > 0 else { return 0 }
        let yearlyWeeklyCost = weeklyPrice * 52
        let savings = (yearlyWeeklyCost - annualPrice) / yearlyWeeklyCost
        return Int(round(savings * 100))
    }
    
    /// Процент скидки для пакета генераций.
    /// Базовая цена (самая невыгодная) = пакет с наибольшей ценой за 1 генерацию.
    private func calculatePackSavingsPercentage(for product: ProductInfo, allPacks: [ProductInfo]) -> Int {
        // Собираем пары (продукт, цена_за_генерацию)
        var pricePerGen: [(ProductInfo, Double)] = []
        for p in allPacks {
            let price = extractPriceValue(from: p.localizedPrice)
            let gens = Double(paywallCache.generationLimit(for: p.vendorProductId, title: p.localizedTitle) ?? 0)
            guard price > 0, gens > 0 else { continue }
            pricePerGen.append((p, price / gens))
        }
        guard !pricePerGen.isEmpty else { return 0 }
        
        // Базовый (самый дорогой за генерацию) — невыгодный пакет
        guard let (baseProduct, basePpg) = pricePerGen.max(by: { $0.1 < $1.1 }) else { return 0 }
        // Для самого дорогого пакета скидки нет
        if product.vendorProductId == baseProduct.vendorProductId { return 0 }
        
        let productPrice = extractPriceValue(from: product.localizedPrice)
        let productGens = Double(paywallCache.generationLimit(for: product.vendorProductId, title: product.localizedTitle) ?? 0)
        guard productPrice > 0, productGens > 0 else { return 0 }
        
        let productPpg = productPrice / productGens
        let savings = (basePpg - productPpg) / basePpg
        return Int(round(savings * 100))
    }
    
    private func extractPriceValue(from priceString: String) -> Double {
        // Удаляем все символы кроме цифр и точки
        let cleanedString = priceString.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        return Double(cleanedString) ?? 0.0
    }
    
    // Для более чистого отображения цены в карточке: скрываем завершающие .00 или ,00, не трогая валютный символ и порядок локали.
    private func formatPriceForCard(_ localizedPrice: String) -> String {
        localizedPrice.replacingOccurrences(
            of: "([\\.,]00)(?=\\D*$)",
            with: "",
            options: .regularExpression
        )
    }
    
    private func handleSubscription() {
        guard !isPurchasing else { return }
        
        let products = getDisplayedProducts()
        guard selectedPlan < products.count else {
            print("[paywall] PaywallView.handleSubscription: пропуск selectedPlan=\(selectedPlan) products.count=\(products.count)")
            return
        }
        
        let product = products[selectedPlan]
        print("[paywall] PaywallView.handleSubscription: старт vendorProductId=\(product.vendorProductId) tier=\(paywallCache.currentPlacementTier.rawValue) displayed.count=\(products.count)")

        isPurchasing = true

        if let adaptyProduct = paywallCache.getAdaptyProduct(for: product.vendorProductId) {
            print("[paywall] PaywallView.handleSubscription: путь Adapty.makePurchase")
            AdaptyService.shared.makePurchase(product: adaptyProduct) { result in
                DispatchQueue.main.async {
                    self.isPurchasing = false

                    switch result {
                    case .success:
                        print("[paywall] PaywallView.handleSubscription: Adapty success id=\(product.vendorProductId)")
                        self.finishSuccessfulPurchase(for: product)

                    case .failure(let error):
                        // Проверяем, не является ли это отменой пользователем
                        if let nsError = error as NSError?, nsError.domain == "AdaptyService" && nsError.code == 1001 {
                            print("[paywall] PaywallView.handleSubscription: пользователь отменил (code 1001)")
                            // Пользователь отменил покупку - не показываем ошибку
                        } else {
                            print("[paywall] PaywallView.handleSubscription: Adapty failure \(error)")
                            // Реальная ошибка покупки - показываем уведомление
                            NotificationManager.shared.showError("paywall_error_purchase_failed".localized(with: error.localizedDescription))
                        }
                    }
                }
            }
            return
        }

        if let storeKitProduct = paywallCache.getStoreKitProduct(for: product.vendorProductId) {
            print("[paywall] PaywallView.handleSubscription: путь StoreKit локально id=\(product.vendorProductId)")
            Task {
                await purchaseLocalStoreKitProduct(storeKitProduct, productInfo: product)
            }
            return
        }

        isPurchasing = false
        print("[paywall] PaywallView.handleSubscription: нет AdaptyPaywallProduct и StoreKit.Product — product_not_found id=\(product.vendorProductId)")
        NotificationManager.shared.showError("paywall_error_product_not_found".localized)
    }

    @MainActor
    private func purchaseLocalStoreKitProduct(_ storeKitProduct: StoreKit.Product, productInfo: ProductInfo) async {
        print("[paywall] PaywallView.purchaseLocalStoreKit: старт id=\(productInfo.vendorProductId)")
        do {
            let result = try await storeKitProduct.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPurchasing = false
                print("[paywall] PaywallView.purchaseLocalStoreKit: verified+finish OK id=\(productInfo.vendorProductId)")
                finishSuccessfulPurchase(for: productInfo)
            case .userCancelled:
                print("[paywall] PaywallView.purchaseLocalStoreKit: userCancelled id=\(productInfo.vendorProductId)")
                isPurchasing = false
            case .pending:
                print("[paywall] PaywallView.purchaseLocalStoreKit: pending id=\(productInfo.vendorProductId)")
                isPurchasing = false
            @unknown default:
                print("[paywall] PaywallView.purchaseLocalStoreKit: unknown result id=\(productInfo.vendorProductId)")
                isPurchasing = false
            }
        } catch {
            isPurchasing = false
            print("[paywall] PaywallView.purchaseLocalStoreKit: error \(error)")
            NotificationManager.shared.showError("paywall_error_purchase_failed".localized(with: error.localizedDescription))
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    private func finishSuccessfulPurchase(for product: ProductInfo) {
        // Единая пост-обработка нужна для Adapty и локального StoreKit: UI получает один и тот же результат покупки.
        if isPackProduct(product),
           let packSize = paywallCache.generationLimit(for: product.vendorProductId) {
            appState.addBonusGenerations(packSize)
            // Статус isProUser не меняем — пакеты не дают подписку.
            NotificationManager.shared.showSuccess("paywall_success_generations_added".localized(with: packSize))
        } else {
            // Подписка (новая или продление):
            // всегда обновляем PRO-статус и полностью обновляем подписочный лимит.
            appState.isProUser = true
            appState.onBecamePro()
            NotificationManager.shared.showSuccess("paywall_success_subscription".localized)
        }

        dismissPaywallPresentation()
    }
    
    private func handleRestore() {
        guard !isRestoring else { return }
        
        isRestoring = true
        print("[paywall] PaywallView.handleRestore: старт")
        
        let expectedIds = Set(paywallCache.productsCache.values.map { $0.vendorProductId })
        AdaptyService.shared.restorePurchases(expectedProductIds: expectedIds) { result in
            DispatchQueue.main.async {
                self.isRestoring = false
                
                switch result {
                case .success:
                    // Проверяем итоговый статус через сервис: там учтены fallback-сценарии после restore.
                    let hasActiveSubscription = AdaptyService.shared.hasActiveSubscription()
                    print("[paywall] PaywallView.handleRestore: success premiumActive=\(hasActiveSubscription)")
                    if hasActiveSubscription {
                        self.appState.isProUser = true
                        // Инициализируем период только если ещё не был задан,
                        // но НЕ сбрасываем proGenerationsUsed — нельзя рестором обнулять счётчик.
                        self.appState.initProPeriodIfNeeded()
                        self.dismissPaywallPresentation()
                        NotificationManager.shared.showSuccess("paywall_success_restore".localized)
                    } else {
                        print("[paywall] PaywallView.handleRestore: нет активной premium подписки в профиле")
                        NotificationManager.shared.showError("paywall_error_no_subscription_to_restore".localized)
                    }
                    
                case .failure(let error):
                    print("[paywall] PaywallView.handleRestore: failure \(error)")
                    // Ошибка восстановления
                    NotificationManager.shared.showError("paywall_error_restore_failed".localized(with: error.localizedDescription))
                }
            }
        }
    }
    
    private func getButtonTitle() -> String {
        let products = getDisplayedProducts()
        guard selectedPlan < products.count else { return "subscribe".localized }
        let product = products[selectedPlan]
        
        // Для пакетов делаем CTA конкретным: пользователь сразу видит, сколько генераций получит после покупки.
        if isPackProduct(product),
           let count = paywallCache.generationLimit(for: product.vendorProductId, title: product.localizedTitle) {
            return "pack_buy_format".localized(with: count)
        }
        
        return product.isTrial ? "start_free_trial".localized : "subscribe".localized
    }
    
    private func isSelectedPackProduct() -> Bool {
        let products = getDisplayedProducts()
        guard selectedPlan < products.count else { return false }
        return isPackProduct(products[selectedPlan])
    }

    private func isPackProduct(_ product: ProductInfo) -> Bool {
        if paywallCache.paywallConfig?.purchasePlanIds?.contains(product.vendorProductId) == true {
            return true
        }
        return product.vendorProductId.hasPrefix("purchase_") || product.vendorProductId.hasPrefix("purchases_")
    }
}

/// Строка под ценой на карточке подписки: токены (число + `sparkles` как в навбаре) или текст периода.
/// `fileprivate`: только этот файл; иначе у `internal` `PricingPlanCard` нельзя хранить `private`-тип в свойстве.
fileprivate enum PlanUnderPrice: Equatable {
    case none
    case tokenCount(Int)
    case caption(String)
}

/// Плитки тарифов/пакетов на пейволе: один вид «как в тёмной теме», независимо от темы приложения (текст на тёмной подложке).
fileprivate enum PaywallPlanTileChrome {
    static let title = Color.white.opacity(0.85)
    static let secondary = Color.white.opacity(0.72)
    static let savingsPillBackground = Color.white.opacity(0.14)
}

/// Холст и мелкий текст пейвола целиком: как в dark, пока открыт оверлей (не тянем светлый `AppTheme` под градиенты).
fileprivate enum PaywallShellChrome {
    static let canvasBackground = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let closeButton = Color.white.opacity(0.58)
    static let footerLink = Color.white.opacity(0.52)
}

fileprivate struct PricingPlanCard: View {
    let title: String
    let subtitle: String
    let price: String
    let underPrice: PlanUnderPrice
    let isPackProduct: Bool
    let isSelected: Bool
    let isRecommended: Bool

    private var underPriceTokenIconColor: Color {
        PaywallPlanTileChrome.secondary
    }

    private var subtitleColor: Color {
        // Скидка: «-N%» (пакеты) или «Save N%» (годовая подписка) — акцент; остальное — вторичный цвет.
        if subtitle.hasPrefix("-") && subtitle.contains("%") {
            return AppTheme.Colors.accent
        }
        if subtitle.range(of: "\\d+%", options: .regularExpression) != nil {
            return AppTheme.Colors.accent
        }
        return PaywallPlanTileChrome.secondary
    }
    
    private var isSavingsSubtitle: Bool {
        subtitle.hasPrefix("-") && subtitle.contains("%")
    }

    /// Годовая «Save N%» (локализовано): не пакетный «-N%», но с процентом — чип слева под заголовком, как у скидки на пакетах справа.
    private var isAnnualSavingsChipSubtitle: Bool {
        guard !isPackProduct, !subtitle.isEmpty else { return false }
        guard !isSavingsSubtitle else { return false }
        return subtitle.range(of: "\\d+%", options: .regularExpression) != nil
    }

    @ViewBuilder
    private var underPriceView: some View {
        switch underPrice {
        case .none:
            EmptyView()
        case .tokenCount(let n):
            // Тот же маркер токенов, что в `ProStatusBadge` / `PrimaryGenerationButtonLabel` / CTA пейвола — `sparkles`, не SF Symbol «звезда».
            HStack(spacing: 5) {
                Text(n, format: .number)
                    .font(AppTheme.Typography.period)
                    .foregroundColor(underPriceTokenIconColor)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(underPriceTokenIconColor)
            }
        case .caption(let s):
            Text(s)
                .font(AppTheme.Typography.period)
                .foregroundColor(PaywallPlanTileChrome.secondary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            VStack(spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(AppTheme.Typography.cardTitle)
                                .foregroundColor(PaywallPlanTileChrome.title)
                                .lineLimit(1)
                                .minimumScaleFactor(isPackProduct ? 0.7 : 1)
                            
                            if isPackProduct {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(PaywallPlanTileChrome.title)
                                    .layoutPriority(1)
                            }
                        }
                        
                        if isAnnualSavingsChipSubtitle {
                            Text(subtitle)
                                .font(AppTheme.Typography.caption)
                                .foregroundColor(AppTheme.Colors.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(PaywallPlanTileChrome.savingsPillBackground)
                                .cornerRadius(6)
                        } else if !subtitle.isEmpty && (!isPackProduct || !isSavingsSubtitle) {
                            Text(subtitle)
                                .font(AppTheme.Typography.bodySecondary)
                                .foregroundColor(subtitleColor)
                        }
                    }
                    .layoutPriority(isPackProduct ? 1 : 0)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 8) {
                            if isPackProduct && !subtitle.isEmpty && isSavingsSubtitle {
                                // Для пакетов делаем скидку менее акцентной: зелёный текст на мягкой серой подложке как у Surprise me.
                                Text(subtitle.uppercased())
                                    .font(AppTheme.Typography.caption)
                                    .foregroundColor(AppTheme.Colors.accent)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(PaywallPlanTileChrome.savingsPillBackground)
                                    .cornerRadius(6)
                            }
                            
                            Text(price)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(PaywallPlanTileChrome.title)
                                .lineLimit(1)
                                .minimumScaleFactor(isPackProduct ? 0.82 : 1)
                        }
                        
                        underPriceView
                    }
                }
            }
            .padding(AppTheme.Spacing.medium)
            // Та же тёмная подложка, что и в dark: не зависит от темы приложения (без «светлого» материала и лишнего контраста обводки).
            .background {
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large)
                    .fill(AppTheme.Colors.paywallCardBackground.opacity(0.94))
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large)
                    .strokeBorder(
                        isSelected ? AppTheme.Colors.primary : Color.white.opacity(0.16),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
    }
} 