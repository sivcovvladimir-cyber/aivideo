import SwiftUI
import UIKit

// Общий медиа-слой для превью-плиток: постер может быть remote URL или уже загруженным UIImage, motion-слой поверх — локальное/remote видео или WebP.
struct PreviewMediaView<Placeholder: View>: View {
    let imageURL: URL?
    let image: UIImage?
    let motionURL: String?
    let shouldPlayMotion: Bool
    let loopsMotionVideo: Bool
    let preloadsMotionWhenHidden: Bool
    let showsLoadingIndicator: Bool
    let prefersMotionWhenCached: Bool
    let showsPosterBeforeMotion: Bool
    /// Звук превью-видео (0…1, на detail сейчас 0.1); `nil` — без звука как в каталоге (`MediaVideoPlayer` по умолчанию).
    let motionPlaybackVolumeOverride: Float?
    let debugLogTag: String?
    let debugContext: String?
    /// Первый показ motion (не постер); hero ждёт это перед fallback-отсчётом для не-AV превью.
    let onMotionPlaybackReady: (() -> Void)?
    /// Для hero обычное видео переключает слайд в момент, когда ролик должен был уйти на новый цикл.
    let onMotionPlaybackLoop: (() -> Void)?
    let placeholder: () -> Placeholder

    @State private var lastLoggedSignature: String?
    @State private var lastLoggedGeometrySignature: String?
    @State private var isMotionPlaybackReady = false
    @State private var isMotionCachedOnDisk = false
    /// Remote постер после фоновой подгрузки, пока на экране был bundled (см. `poster`).
    @State private var upgradedRemotePoster: UIImage?
    /// Инвалидирует in-flight `downloadImage`, если сменился URL постера или сбросили кэш картинок.
    @State private var remotePosterLoadGeneration: Int = 0

    init(
        imageURL: URL? = nil,
        image: UIImage? = nil,
        motionURL: String? = nil,
        shouldPlayMotion: Bool,
        loopsMotionVideo: Bool = true,
        preloadsMotionWhenHidden: Bool = false,
        showsLoadingIndicator: Bool = false,
        prefersMotionWhenCached: Bool = false,
        showsPosterBeforeMotion: Bool = true,
        motionPlaybackVolumeOverride: Float? = nil,
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
        self.preloadsMotionWhenHidden = preloadsMotionWhenHidden
        self.showsLoadingIndicator = showsLoadingIndicator
        self.prefersMotionWhenCached = prefersMotionWhenCached
        self.showsPosterBeforeMotion = showsPosterBeforeMotion
        self.motionPlaybackVolumeOverride = motionPlaybackVolumeOverride
        self.debugLogTag = debugLogTag
        self.debugContext = debugContext
        self.onMotionPlaybackReady = onMotionPlaybackReady
        self.onMotionPlaybackLoop = onMotionPlaybackLoop
        self.placeholder = placeholder
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let suppressPoster = shouldSuppressPosterUntilMotionReady

            // Aspect-fill должен считаться от размера слота плитки/detail, а не от intrinsic-размера постера или WKWebView.
            ZStack {
                if !suppressPoster {
                    poster
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else if shouldShowPlaceholderWhenPosterSuppressed {
                    placeholder()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }

                // Для detail-карусели можем заранее поднять player на соседней странице (paused),
                // чтобы после свайпа активное видео начинало играть без паузы на инициализацию.
                if shouldInstantiateMotionLayer, let motionURL {
                    MediaVideoPlayer(
                        mediaURL: motionURL,
                        shouldPlay: shouldPlayMotion,
                        preloadsWhenPaused: preloadsMotionWhenHidden,
                        loopsVideo: loopsMotionVideo,
                        debugLogTag: debugLogTag,
                        playbackVolumeOverride: motionPlaybackVolumeOverride,
                        onPlaybackReady: {
                            if let tag = debugLogTag {
                                // print("\(tag) PreviewMediaView onPlaybackReady context=\(debugContext ?? "?") suppressPoster=\(shouldSuppressPosterUntilMotionReady) cachedOnDisk=\(isMotionCachedOnDisk)")
                            }
                            isMotionPlaybackReady = true
                            onMotionPlaybackReady?()
                        },
                        onPlaybackLoop: onMotionPlaybackLoop
                    )
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .allowsHitTesting(false)
                }

                if shouldShowLoadingOverlay {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                        // Лоадер поверх карточки: тапы должны проходить к Button-обёртке, а не застревать здесь.
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
            resetMotionReadinessIfNeeded()
            refreshMotionCacheState()
            logDisplayedMediaIfNeeded(reason: "appear")
        }
        .onChange(of: shouldPlayMotion) { _, _ in
            resetMotionReadinessIfNeeded()
            refreshMotionCacheState()
            logDisplayedMediaIfNeeded(reason: "play-change")
        }
        .onChange(of: motionURL) { _, _ in
            resetMotionReadinessIfNeeded()
            refreshMotionCacheState()
            logDisplayedMediaIfNeeded(reason: "motion-change")
        }
        .onChange(of: imageURL?.absoluteString) { _, _ in
            upgradedRemotePoster = nil
            remotePosterLoadGeneration += 1
            logDisplayedMediaIfNeeded(reason: "poster-url-change")
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            upgradedRemotePoster = nil
            remotePosterLoadGeneration += 1
            logDisplayedMediaIfNeeded(reason: "image-cache-cleared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .effectPreviewVideoCacheUpdated)) { note in
            guard motionURL != nil else { return }
            // Нотификация может прийти с URL в слегка ином представлении (encoding/query порядок), поэтому просто пересчитываем локальный флаг.
            refreshMotionCacheState()
            if let updatedURL = note.userInfo?["url"] as? String,
               let motionURL,
               updatedURL == motionURL {
                if let tag = debugLogTag {
                    // print("\(tag) PreviewMediaView cache-updated context=\(debugContext ?? "?") isMotionPlaybackReady=\(isMotionPlaybackReady) suppressPoster=\(shouldSuppressPosterUntilMotionReady) showLoader=\(shouldShowLoadingOverlay)")
                }
                logDisplayedMediaIfNeeded(reason: "cache-updated")
            }
        }
    }

    @ViewBuilder
    private var poster: some View {
        let remoteFromCache = syncCachedRemotePosterImage()
        let remoteDisplayed = remoteFromCache ?? upgradedRemotePoster

        if let ui = remoteDisplayed {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else if let bundled = image, let urlString = imageURL?.absoluteString, urlString.hasPrefix("http") {
            // Есть ассет и remote URL, но кэша ещё нет: показываем bundled, параллельно качаем URL; после появления в кэше — ветка `remoteDisplayed`.
            Image(uiImage: bundled)
                .resizable()
                .scaledToFill()
                .task(id: "\(urlString)|\(remotePosterLoadGeneration)") {
                    let gen = remotePosterLoadGeneration
                    await prefetchRemotePosterWhileBundledVisible(urlString: urlString, generation: gen)
                }
        } else if let bundled = image {
            Image(uiImage: bundled)
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

    /// Тот же порог, что в `CachedAsyncImagePolicy`: иначе «HIT» из RAM даёт пустой/1px слой и кажется, что remote-постер «не грузится», хотя bundled при этом виден.
    private func effectPreviewRemotePosterIfRenderable(_ ui: UIImage?) -> UIImage? {
        guard let ui else { return nil }
        let w = ui.size.width * ui.scale
        let h = ui.size.height * ui.scale
        guard w >= 2, h >= 2, ui.cgImage != nil else { return nil }
        return ui
    }

    /// Синхронный hit по RAM/диску `ImageDownloader` для remote preview image.
    private func syncCachedRemotePosterImage() -> UIImage? {
        guard let imageURL, imageURL.absoluteString.hasPrefix("http") else { return nil }
        return effectPreviewRemotePosterIfRenderable(
            ImageDownloader.shared.getCachedImage(from: imageURL.absoluteString)
        )
    }

    /// Фоновая подгрузка remote-постера, пока пользователь уже видит bundled (без `Continuation`, чтобы отмена `.task` не оставляла висящий resume).
    private func prefetchRemotePosterWhileBundledVisible(urlString: String, generation: Int) async {
        guard image != nil else { return }
        if let rawHit = ImageDownloader.shared.getCachedImage(from: urlString) {
            if let hit = effectPreviewRemotePosterIfRenderable(rawHit) {
                await MainActor.run {
                    guard generation == remotePosterLoadGeneration else { return }
                    upgradedRemotePoster = hit
                }
                return
            }
            ImageDownloader.shared.invalidateCachedRemoteImage(for: urlString)
        }
        await MainActor.run {
            guard generation == remotePosterLoadGeneration else { return }
            ImageDownloader.shared.downloadImage(from: urlString, effectPreviewLogTag: debugLogTag) { _ in
                Task { @MainActor in
                    guard generation == remotePosterLoadGeneration else { return }
                    upgradedRemotePoster = effectPreviewRemotePosterIfRenderable(
                        ImageDownloader.shared.getCachedImage(from: urlString)
                    )
                }
            }
        }
    }

    private func logDisplayedMediaIfNeeded(reason: String) {
        guard let debugLogTag else { return }
        let imageDescription = imageURL?.absoluteString ?? (image == nil ? "nil" : "preloaded-uiimage")
        let motionDescription = motionURL ?? "nil"
        let posterCacheState = posterCacheStateDescription()
        let motionKind = motionKindDescription()
        let signature = "\(debugContext ?? "?")|\(imageDescription)|\(motionDescription)|\(shouldPlayMotion)|\(posterCacheState)|\(motionKind)|\(shouldSuppressPosterUntilMotionReady)|\(shouldShowLoadingOverlay)"
        guard lastLoggedSignature != signature else { return }
        lastLoggedSignature = signature
        // print("\(debugLogTag) PreviewMediaView \(reason) context=\(debugContext ?? "?") shouldPlayMotion=\(shouldPlayMotion) posterCache=\(posterCacheState) motionKind=\(motionKind) suppressPoster=\(shouldSuppressPosterUntilMotionReady) showLoader=\(shouldShowLoadingOverlay) poster=\(imageDescription) motion=\(motionDescription)")
    }

    private func logGeometryIfNeeded(size: CGSize, reason: String) {
        guard let debugLogTag else { return }
        let roundedWidth = Int(size.width.rounded())
        let roundedHeight = Int(size.height.rounded())
        let signature = "\(debugContext ?? "?")|\(roundedWidth)x\(roundedHeight)"
        guard lastLoggedGeometrySignature != signature else { return }
        lastLoggedGeometrySignature = signature
        // print("\(debugLogTag) PreviewMediaView \(reason) context=\(debugContext ?? "?") bounds=\(String(format: "%.1f", size.width))x\(String(format: "%.1f", size.height))")
    }

    private func posterCacheStateDescription() -> String {
        guard let imageURL else {
            return image != nil ? "bundled-only" : "none"
        }
        let urlString = imageURL.absoluteString
        guard urlString.hasPrefix("http") else {
            return imageURL.isFileURL ? "local-file" : "non-http"
        }
        let hit = ImageDownloader.shared.getCachedImage(from: urlString) != nil
        let tag = hit ? "HIT" : "MISS"
        if image != nil { return "\(tag)+bundled" }
        return tag
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

    /// Лоадер на плитках/detail нужен только в режиме активного motion: если видео ещё не готово, держим индикатор поверх постера/фона.
    private var shouldShowLoadingOverlay: Bool {
        (showsLoadingIndicator || suppressesPosterBecauseMotionIsCached || suppressesPosterBeforeMotionByPolicy) &&
        shouldPlayMotion &&
        motionURL != nil &&
        !isMotionPlaybackReady
    }

    /// Когда suppress включён именно из-за cached AV-motion, placeholder не нужен: оставляем только loader -> video.
    private var shouldShowPlaceholderWhenPosterSuppressed: Bool {
        !suppressesPosterBecauseMotionIsCached && !suppressesPosterBeforeMotionByPolicy && !shouldShowLoadingOverlay
    }

    /// Motion уже в локальном кэше (AV — `EffectPreviewVideoDiskCache`, WebP/GIF — `ImageDownloader`): скрываем постер до готовности слоя, как для mp4.
    private var suppressesPosterBecauseMotionIsCached: Bool {
        prefersMotionWhenCached
            && !showsPosterBeforeMotion
            && shouldPlayMotion
            && isMotionCachedOnDisk
    }
    
    /// Политика каталога (main/view all): единообразно показывать/скрывать постер перед motion для AV и WebP.
    private var suppressesPosterBeforeMotionByPolicy: Bool {
        guard !showsPosterBeforeMotion,
              shouldPlayMotion,
              motionURL != nil,
              !isMotionPlaybackReady else {
            return false
        }
        // При `showsPosterBeforeMotion=false` скрываем постер только для "тёплого" старта:
        // если motion ещё не в кэше, постер должен оставаться видимым до готовности playback.
        return isMotionCachedOnDisk
    }

    /// Если ролик уже в дисковом кэше, пропускаем промежуточный постер и показываем flow «loader -> video ready».
    private var shouldSuppressPosterUntilMotionReady: Bool {
        // Для сценария «плитка с видео»: пока motion не готов, держим только loader и не показываем постер,
        // иначе пользователь видит промежуточную фазу «loader поверх картинки».
        if showsLoadingIndicator,
           shouldPlayMotion,
           motionURL != nil,
           !isMotionPlaybackReady {
            return true
        }

        return suppressesPosterBeforeMotionByPolicy || suppressesPosterBecauseMotionIsCached
    }

    private var shouldInstantiateMotionLayer: Bool {
        (shouldPlayMotion || preloadsMotionWhenHidden) && motionURL != nil
    }

    private func resetMotionReadinessIfNeeded() {
        // Считаем «готовность motion» только как факт реального onPlaybackReady; иначе при быстрых сменах shouldPlay возможна вспышка постера между loader и видео.
        isMotionPlaybackReady = false
    }

    /// Карточка должна реагировать не только на локальное состояние, но и на фоновый prewarm: кэш мог заполниться уже после первого рендера.
    private func refreshMotionCacheState() {
        guard let motionURL else {
            isMotionCachedOnDisk = false
            return
        }
        if MediaVideoPlayer.isRasterMotionAssetURLString(motionURL) {
            isMotionCachedOnDisk = ImageDownloader.shared.hasRemoteImagePayloadCached(for: motionURL)
        } else {
            isMotionCachedOnDisk = EffectPreviewVideoDiskCache.hasCachedVideo(for: motionURL)
        }
    }
}
