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
    let onTap: () -> Void

    @State private var cellOnScreen = false
    @Environment(\.scenePhase) private var scenePhase

    private var runVideo: Bool {
        cellOnScreen && scenePhase == .active
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
            cellOnScreen = true
        }
        .onDisappear {
            cellOnScreen = false
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
            catalogPreviewMedia
                .frame(width: width, height: height)
                .clipped()

            catalogTitleOverlay
                .frame(width: width, height: height, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
    }

    private var catalogPreviewMedia: some View {
        PreviewMediaView(
            imageURL: item.preset.previewImageURL,
            image: item.preset.bundledPreviewUIImage(),
            motionURL: item.preset.previewVideoURL?.absoluteString,
            shouldPlayMotion: runVideo,
            debugLogTag: "[effects-preview]",
            debugContext: debugContext
        ) {
            AppTheme.Colors.cardBackground
        }
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
                .onAppear {
                    print("[effects-preview] EffectCatalogRailCard titleOverlay appear context=\(debugContext)")
                }
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
