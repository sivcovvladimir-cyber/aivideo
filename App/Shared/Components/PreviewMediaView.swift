import SwiftUI
import UIKit

// Общий медиа-слой для превью-плиток: постер может быть remote URL или уже загруженным UIImage, motion-слой поверх — локальное/remote видео или WebP.
struct PreviewMediaView<Placeholder: View>: View {
    let imageURL: URL?
    let image: UIImage?
    let motionURL: String?
    let shouldPlayMotion: Bool
    let loopsMotionVideo: Bool
    let debugLogTag: String?
    let debugContext: String?
    /// Первый показ motion (не постер); hero ждёт это перед fallback-отсчётом для не-AV превью.
    let onMotionPlaybackReady: (() -> Void)?
    /// Для hero обычное видео переключает слайд в момент, когда ролик должен был уйти на новый цикл.
    let onMotionPlaybackLoop: (() -> Void)?
    let placeholder: () -> Placeholder

    @State private var lastLoggedSignature: String?
    @State private var lastLoggedGeometrySignature: String?

    init(
        imageURL: URL? = nil,
        image: UIImage? = nil,
        motionURL: String? = nil,
        shouldPlayMotion: Bool,
        loopsMotionVideo: Bool = true,
        debugLogTag: String? = nil,
        debugContext: String? = nil,
        onMotionPlaybackReady: (() -> Void)? = nil,
        onMotionPlaybackLoop: (() -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.imageURL = imageURL
        self.image = image
        self.motionURL = motionURL
        self.shouldPlayMotion = shouldPlayMotion
        self.loopsMotionVideo = loopsMotionVideo
        self.debugLogTag = debugLogTag
        self.debugContext = debugContext
        self.onMotionPlaybackReady = onMotionPlaybackReady
        self.onMotionPlaybackLoop = onMotionPlaybackLoop
        self.placeholder = placeholder
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            // Aspect-fill должен считаться от размера слота плитки/detail, а не от intrinsic-размера постера или WKWebView.
            ZStack {
                poster
                    .frame(width: size.width, height: size.height)
                    .clipped()

                if shouldPlayMotion, let motionURL {
                    MediaVideoPlayer(
                        mediaURL: motionURL,
                        shouldPlay: true,
                        loopsVideo: loopsMotionVideo,
                        debugLogTag: debugLogTag,
                        onPlaybackReady: onMotionPlaybackReady,
                        onPlaybackLoop: onMotionPlaybackLoop
                    )
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear {
                logGeometryIfNeeded(size: size, reason: "geometry-appear")
            }
            .onChange(of: size) { _, newSize in
                logGeometryIfNeeded(size: newSize, reason: "geometry-change")
            }
        }
        .clipped()
        .onAppear {
            logDisplayedMediaIfNeeded(reason: "appear")
        }
        .onChange(of: shouldPlayMotion) { _, _ in
            logDisplayedMediaIfNeeded(reason: "play-change")
        }
        .onChange(of: motionURL) { _, _ in
            logDisplayedMediaIfNeeded(reason: "motion-change")
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let imageURL {
            CachedAsyncImage(url: imageURL, debugLogTag: debugLogTag) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder()
            }
        } else {
            placeholder()
        }
    }

    private func logDisplayedMediaIfNeeded(reason: String) {
        guard let debugLogTag else { return }
        let imageDescription = imageURL?.absoluteString ?? (image == nil ? "nil" : "preloaded-uiimage")
        let motionDescription = motionURL ?? "nil"
        let posterCacheState = posterCacheStateDescription()
        let motionKind = motionKindDescription()
        let signature = "\(debugContext ?? "?")|\(imageDescription)|\(motionDescription)|\(shouldPlayMotion)|\(posterCacheState)|\(motionKind)"
        guard lastLoggedSignature != signature else { return }
        lastLoggedSignature = signature
        print("\(debugLogTag) PreviewMediaView \(reason) context=\(debugContext ?? "?") shouldPlayMotion=\(shouldPlayMotion) posterCache=\(posterCacheState) motionKind=\(motionKind) poster=\(imageDescription) motion=\(motionDescription)")
    }

    private func logGeometryIfNeeded(size: CGSize, reason: String) {
        guard let debugLogTag else { return }
        let roundedWidth = Int(size.width.rounded())
        let roundedHeight = Int(size.height.rounded())
        let signature = "\(debugContext ?? "?")|\(roundedWidth)x\(roundedHeight)"
        guard lastLoggedGeometrySignature != signature else { return }
        lastLoggedGeometrySignature = signature
        print("\(debugLogTag) PreviewMediaView \(reason) context=\(debugContext ?? "?") bounds=\(String(format: "%.1f", size.width))x\(String(format: "%.1f", size.height))")
    }

    private func posterCacheStateDescription() -> String {
        if image != nil { return "provided-uiimage" }
        guard let imageURL else { return "none" }
        let urlString = imageURL.absoluteString
        guard urlString.hasPrefix("http") else {
            return imageURL.isFileURL ? "local-file" : "non-http"
        }
        return ImageDownloader.shared.getCachedImage(from: urlString) == nil ? "MISS" : "HIT"
    }

    private func motionKindDescription() -> String {
        guard let motionURL else { return "none" }
        let lower = motionURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .lowercased() ?? motionURL.lowercased()
        if lower.hasSuffix(".webp") || lower.hasSuffix("%2ewebp") { return "animated-raster-webp-wkwebview" }
        if lower.hasSuffix(".gif") || lower.hasSuffix("%2egif") { return "animated-raster-gif-wkwebview" }
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v") { return "video-avplayer" }
        return "unknown"
    }
}
