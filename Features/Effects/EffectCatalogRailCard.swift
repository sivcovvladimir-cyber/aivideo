import SwiftUI

/// Карточка эффекта в ленте/сетке каталога: постер + опциональное превью-видео (loop), воспроизведение только пока ячейка на экране (`onAppear` / `onDisappear`) и приложение активно.
enum EffectCatalogCardLayout: Equatable {
    /// Главная: горизонтальный скролл, фиксированный размер.
    case railFixed142x190
    /// Browse: ячейка `LazyVGrid` на всю ширину колонки; медиа внутри обрезается aspect-fill под этот слот.
    case gridTwoColumnCell(aspectWidthOverHeight: CGFloat)
}

struct EffectCatalogRailCard: View {
    let item: EffectsHomeItem
    let layout: EffectCatalogCardLayout
    let allowsMotionPreview: Bool
    let showsPosterBeforeMotion: Bool
    let autoplayEnabled: Bool
    let forcePauseMotion: Bool
    let onVisibilityChanged: ((Bool) -> Void)?
    let onTap: () -> Void

    @State private var isVisibleInHierarchy = true
    @State private var isActuallyVisibleOnScreen = false
    /// Порог geometry (≥35% площади в viewport): отдельно от `isActuallyVisibleOnScreen`, чтобы при медленном скролле не перезапускать 150 мс на каждом кадре `onChange(frame)`.
    @State private var geometryReportsVisible = false
    /// Задержка 150 мс после входа в viewport только для AV motion (mp4/mov); WebP/GIF — без паузы.
    @State private var pendingVisibleTask: Task<Void, Never>?

    private static let avMotionAutoplayDebounceNs: UInt64 = 150_000_000
    @Environment(\.scenePhase) private var scenePhase

    init(
        item: EffectsHomeItem,
        layout: EffectCatalogCardLayout,
        allowsMotionPreview: Bool,
        showsPosterBeforeMotion: Bool,
        autoplayEnabled: Bool = true,
        forcePauseMotion: Bool = false,
        onVisibilityChanged: ((Bool) -> Void)? = nil,
        onTap: @escaping () -> Void
    ) {
        self.item = item
        self.layout = layout
        self.allowsMotionPreview = allowsMotionPreview
        self.showsPosterBeforeMotion = showsPosterBeforeMotion
        self.autoplayEnabled = autoplayEnabled
        self.forcePauseMotion = forcePauseMotion
        self.onVisibilityChanged = onVisibilityChanged
        self.onTap = onTap
    }

    private var sessionScope: String {
        switch layout {
        case .railFixed142x190:
            return "home-rail"
        case .gridTwoColumnCell:
            return "browse-grid"
        }
    }

    private var mediaSessionID: String {
        "\(sessionScope)|preset:\(item.preset.id)"
    }

    private var motionURLString: String? {
        item.preset.previewVideoURL?.absoluteString
    }

    private var shouldPassMotionURLToPreview: Bool {
        allowsMotionPreview && motionURLString != nil
    }

    /// WebP/GIF через SDWebImage: лёгче AVPlayer — дебаунс 150 мс на вход в viewport не нужен.
    private var isRasterMotionPreview: Bool {
        guard let motionURLString else { return false }
        return MediaVideoPlayer.isRasterMotionAssetURLString(motionURLString)
    }

    private var runVideo: Bool {
        allowsMotionPreview &&
        motionURLString != nil &&
        autoplayEnabled &&
        isVisibleInHierarchy &&
        isActuallyVisibleOnScreen &&
        scenePhase == .active &&
        !forcePauseMotion
    }

    /// Каталог: не поднимаем paused-плеер для видимых, но не-autoplay плиток. Это даёт самый большой выигрыш по числу одновременных AVPlayer при вертикальном скролле; «рывок» при последующем старте сглажен постером из первого кадра видео.
    private var preloadVideoWhenPaused: Bool { false }

    private var debugContext: String {
        let screen: String
        switch layout {
        case .railFixed142x190:
            screen = "home-rail"
        case .gridTwoColumnCell:
            screen = "view-all-grid"
        }
        return "\(screen) id=\(item.preset.id) slug=\(item.preset.slug) title='\(item.preset.title)'"
    }

    var body: some View {
        Button(action: onTap) {
            sizedCard
        }
        .appPlainButtonStyle()
        .contentShape(Rectangle())
        .onAppear {
            isVisibleInHierarchy = true
        }
        .onDisappear {
            pendingVisibleTask?.cancel()
            pendingVisibleTask = nil
            DispatchQueue.main.async {
                isVisibleInHierarchy = false
                geometryReportsVisible = false
                isActuallyVisibleOnScreen = false
                onVisibilityChanged?(false)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateActualVisibility(using: proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        updateActualVisibility(using: frame)
                    }
            }
        }
    }

    /// В `LazyHStack` onAppear может приходить для предзагруженных карточек вне экрана.
    /// Считаем карточку «видимой» только когда заметная часть реально попала в viewport.
    /// Вход в viewport: один таймер 150 мс (и при медленном скролле — не сбрасываем его на каждом кадре движения).
    /// Быстрый скролл: плитка успевает уйти до конца 150 мс — AVPlayer не поднимаем. Выход — сразу.
    private func updateActualVisibility(using globalFrame: CGRect) {
        guard globalFrame.width > 1, globalFrame.height > 1 else { return }

        let viewport = UIScreen.main.bounds
        let intersection = globalFrame.intersection(viewport)
        let visibleArea = max(0, intersection.width) * max(0, intersection.height)
        let fullArea = globalFrame.width * globalFrame.height
        guard fullArea > 0 else { return }

        // Порог убирает дребезг на краях и частично видимых превью.
        let crossesVisibleThreshold = (visibleArea / fullArea) >= 0.35
        guard crossesVisibleThreshold != geometryReportsVisible else { return }

        // `GeometryReader.onChange` приходит в ходе layout-pass; меняем @State отложенно, чтобы
        // не ловить "Publishing changes from within view updates is not allowed".
        if crossesVisibleThreshold {
            DispatchQueue.main.async {
                guard !geometryReportsVisible else { return }
                geometryReportsVisible = true
                guard !isActuallyVisibleOnScreen, pendingVisibleTask == nil else { return }
                if isRasterMotionPreview {
                    isActuallyVisibleOnScreen = true
                    onVisibilityChanged?(true)
                } else {
                    let task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: Self.avMotionAutoplayDebounceNs)
                        guard !Task.isCancelled, geometryReportsVisible, !isActuallyVisibleOnScreen else { return }
                        pendingVisibleTask = nil
                        isActuallyVisibleOnScreen = true
                        onVisibilityChanged?(true)
                    }
                    pendingVisibleTask = task
                }
            }
        } else {
            pendingVisibleTask?.cancel()
            pendingVisibleTask = nil
            DispatchQueue.main.async {
                guard geometryReportsVisible || isActuallyVisibleOnScreen else { return }
                geometryReportsVisible = false
                isActuallyVisibleOnScreen = false
                onVisibilityChanged?(false)
            }
        }
    }

    @ViewBuilder
    private var sizedCard: some View {
        switch layout {
        case .railFixed142x190:
            catalogTile(width: 142, height: 190)
                .cardChrome(item: item)

        case .gridTwoColumnCell(let aspectWH):
            // Сначала фиксируем размер ячейки, затем рисуем видео/постер внутри неё. Так `AVPlayerLayer` не может расширить колонку `LazyVGrid`.
            GeometryReader { proxy in
                catalogTile(width: proxy.size.width, height: proxy.size.height)
                    .cardChrome(item: item)
            }
            .aspectRatio(aspectWH, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    /// Заголовок и градиент привязаны к **слоту плитки**, а не к внутреннему размеру медиа: `WKWebView`/постер не должны раздувать область оверлея (иначе текст пропадает или уезжает).
    private func catalogTile(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Фикс стабильной кликабельности: прозрачная подложка + contentShape дают Button
            // явную hit-area на весь слот карточки независимо от того, какие дочерние слои отключили hit-testing.
            Color.clear

            catalogPreviewMedia
                .frame(width: width, height: height)
                .clipped()

            catalogTitleOverlay
                .frame(width: width, height: height, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }

    private var catalogPreviewMedia: some View {
        PreviewMediaView(
            imageURL: item.preset.previewImageURL,
            image: item.preset.bundledPreviewUIImage(),
            motionURL: shouldPassMotionURLToPreview ? motionURLString : nil,
            shouldPlayMotion: runVideo,
            preloadsMotionWhenHidden: preloadVideoWhenPaused,
            // Для main/view-all suppress постера разрешаем только когда motion превью вообще включён флагом конфига.
            showsLoadingIndicator: false,
            prefersMotionWhenCached: allowsMotionPreview,
            showsPosterBeforeMotion: showsPosterBeforeMotion,
            debugLogTag: nil,
            debugContext: debugContext,
            posterNetworkRequestTimeout: ImageDownloader.effectPreviewPosterNetworkRequestTimeoutSeconds
        ) {
            // Как на detail: сначала лоадер, пока тянется remote-постер; затем картинка и поверх — видео (bundled-картинка без URL показывается сразу, без этого шага).
            if item.preset.previewImageURL != nil {
                ZStack {
                    AppTheme.Colors.cardBackground
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                }
            } else {
                AppTheme.Colors.cardBackground
            }
        }
        // Важно оставить сам PreviewMediaView hit-testable как часть label у Button:
        // если выключить hit-testing на всём слое, SwiftUI может потерять tappable-область карточки в ScrollView/Lazy*.
    }

    private var catalogTitleOverlay: some View {
        // AVPlayerLayer иногда оказывается выше SwiftUI-слоёв внутри превью; здесь слой только типографика/градиент поверх уже обрезанного слота.
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.58)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Текст поверх фото/видео + тёмный scrim: `textPrimary` в light даёт чёрный и пропадает на тени кадра — как на hero, оставляем светлую подпись в любой теме приложения.
            Text(item.preset.title)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(Color.white.opacity(0.95))
                .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(10)
        }
        .allowsHitTesting(false)
    }

}

private struct EffectCatalogCardChrome: ViewModifier {
    let item: EffectsHomeItem

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if item.preset.isProOnly {
                    Image(systemName: "crown")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.primary)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension View {
    func cardChrome(item: EffectsHomeItem) -> some View {
        modifier(EffectCatalogCardChrome(item: item))
    }
}
