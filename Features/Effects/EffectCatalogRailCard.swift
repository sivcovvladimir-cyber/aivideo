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

    private var runVideo: Bool {
        allowsMotionPreview &&
        motionURLString != nil &&
        autoplayEnabled &&
        isVisibleInHierarchy &&
        scenePhase == .active &&
        !forcePauseMotion
    }

    /// Если autoplay для карточки выключен лимитом, всё равно прогреваем motion-слой в paused режиме:
    /// это убирает «рывок» при последующем включении воспроизведения.
    private var preloadVideoWhenPaused: Bool {
        allowsMotionPreview &&
        motionURLString != nil &&
        !autoplayEnabled &&
        isVisibleInHierarchy &&
        scenePhase == .active &&
        !forcePauseMotion
    }

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
            // Иначе родитель (`EffectsHomeView`) меняет `@State` в том же проходе layout, что и появление ячейки — SwiftUI предупреждает про undefined behavior.
            DispatchQueue.main.async {
                onVisibilityChanged?(true)
            }
        }
        .onDisappear {
            isVisibleInHierarchy = false
            DispatchQueue.main.async {
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
