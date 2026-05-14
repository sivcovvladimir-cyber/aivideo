import SwiftUI
import AVFoundation
import CryptoKit
#if canImport(SDWebImageSwiftUI)
import SDWebImageSwiftUI
#endif
#if canImport(SDWebImage)
import SDWebImage
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    /// Когда превью-видео появилось в дисковом кэше, карточки могут сразу переключиться на flow «loader -> motion» без промежуточного постера.
    static let effectPreviewVideoCacheUpdated = Notification.Name("effectPreviewVideoCacheUpdated")
}

struct MediaVideoPlayer: View {
    let mediaURL: String
    let shouldPlay: Bool
    /// Для соседних карточек detail: инициализируем motion-слой заранее даже в paused-состоянии.
    let preloadsWhenPaused: Bool
    /// Бесшовный loop через `AVPlayerLooper` (превью эффектов и видео в галерее).
    let loopsVideo: Bool
    /// Логи этапов превью эффектов (`"[effects-preview]"`); для галереи — `nil`.
    let debugLogTag: String?
    /// Превью эффектов по умолчанию без звука; звук — в полноэкранном Media Detail.
    let isMuted: Bool
    /// Если задано (0…1), игнорируем `isMuted`: `AVPlayer.isMuted = false`, `volume` = значение (например 0.1 на paywall / effect detail).
    let playbackVolumeOverride: Float?
    /// Remote preview video кэшируем на диск: при возврате на экран не ждём повторный network-buffer AVPlayer.
    let usesDiskCache: Bool
    /// Только полноэкранная галерея: `VideoPlayer` может игнорировать safe area. В карточках каталога — `false`, иначе плеер разъезжает layout и накладывается на соседние ячейки.
    let expandsVideoToIgnoreSafeArea: Bool
    /// Первый кадр motion готов (AV слой / WebP после verify); для hero — старт fallback-отсчёта не по появлению постера.
    let onPlaybackReady: (() -> Void)?
    /// Один цикл обычного видео закончился; hero переключает слайд именно в этот момент.
    let onPlaybackLoop: (() -> Void)?

    init(
        mediaURL: String,
        shouldPlay: Bool,
        preloadsWhenPaused: Bool = false,
        loopsVideo: Bool = true,
        debugLogTag: String? = nil,
        isMuted: Bool = true,
        playbackVolumeOverride: Float? = nil,
        usesDiskCache: Bool = true,
        expandsVideoToIgnoreSafeArea: Bool = false,
        onPlaybackReady: (() -> Void)? = nil,
        onPlaybackLoop: (() -> Void)? = nil
    ) {
        self.mediaURL = mediaURL
        self.shouldPlay = shouldPlay
        self.preloadsWhenPaused = preloadsWhenPaused
        self.loopsVideo = loopsVideo
        self.debugLogTag = debugLogTag
        self.isMuted = isMuted
        self.playbackVolumeOverride = playbackVolumeOverride
        self.usesDiskCache = usesDiskCache
        self.expandsVideoToIgnoreSafeArea = expandsVideoToIgnoreSafeArea
        self.onPlaybackReady = onPlaybackReady
        self.onPlaybackLoop = onPlaybackLoop
    }

    @State private var player: AVPlayer?
    @State private var playerLooper: AVPlayerLooper?
    @State private var plainLoopObserver: NSObjectProtocol?
    @StateObject private var readinessObserver = MediaVideoPlayerReadinessObserver()
    @State private var playbackReadyNotified = false
    @State private var playbackReadyCallbackGeneration = 0

    private var url: URL? {
        let normalized = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
            return URL(string: normalized)
        }
        return URL(fileURLWithPath: normalized)
    }

    /// Превью каталога PixVerse: motion-слой часто — remote WebP/GIF (не MP4). Если ошибочно отправить такой URL в `EffectPreviewVideoDiskCache` + AVPlayer, получаем NSURLError -1011 и «тихое» превью.
    /// Учитываем `URL.pathExtension` (после `%2F` в пути) и редкий закодированный суффикс `%2Ewebp`, а не только `hasSuffix` по сырой строке.
    private var isRasterMotionPreviewURL: Bool {
        Self.isRasterMotionAssetURLString(mediaURL)
    }

    static func isRasterMotionAssetURLString(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let withoutQuery = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? trimmed
        let low = withoutQuery.lowercased()
        if low.hasSuffix(".webp") || low.hasSuffix(".gif") { return true }
        // После `lowercased()` сегмент `%2Ewebp` становится `%2ewebp`.
        if low.hasSuffix("%2ewebp") { return true }
        if low.hasSuffix("%2egif") { return true }
        if let u = URL(string: trimmed) {
            let ext = u.pathExtension.lowercased()
            if ext == "webp" || ext == "gif" { return true }
            let last = u.lastPathComponent.lowercased()
            if last.hasSuffix(".webp") || last.hasSuffix(".gif") { return true }
        }
        return false
    }

    /// Для flow «лоадер → готовый motion»: нужен быстрый sync-check, что URL подходит под AV playback (а не WebP/GIF).
    static func isAVMotionAssetURLString(_ raw: String) -> Bool {
        !isRasterMotionAssetURLString(raw)
    }

    #if canImport(SDWebImage)
    /// SDWebImage хранит WebP/GIF по ключу конкретного URL: если файл лежит только у зеркала, старт с канонического R2 снова бьёт в сеть при каждом открытии экрана.
    static func preferredRasterMotionURLForSDWebImageCache(canonical url: URL) -> URL {
        guard let canonicalKey = SDWebImageManager.shared.cacheKey(for: url) else {
            return url
        }
        if SDImageCache.shared.imageFromMemoryCache(forKey: canonicalKey) != nil { return url }
        if SDImageCache.shared.diskImageDataExists(withKey: canonicalKey) { return url }
        guard let fallback = PreviewMediaURLFallback.fallbackURL(from: url),
              fallback != url,
              let fallbackKey = SDWebImageManager.shared.cacheKey(for: fallback) else {
            return url
        }
        if SDImageCache.shared.imageFromMemoryCache(forKey: fallbackKey) != nil { return fallback }
        if SDImageCache.shared.diskImageDataExists(withKey: fallbackKey) { return fallback }
        return url
    }

    /// Быстрый hit для `PreviewMediaView` / политики лоадера: учитываем и канон, и зеркальный ключ кэша.
    static func isRasterMotionCachedInSDWebImage(forCanonical urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let preferred = preferredRasterMotionURLForSDWebImageCache(canonical: url)
        guard let key = SDWebImageManager.shared.cacheKey(for: preferred) else { return false }
        if SDImageCache.shared.imageFromMemoryCache(forKey: key) != nil { return true }
        return SDImageCache.shared.diskImageDataExists(withKey: key)
    }
    #endif

    var body: some View {
        Group {
            if isRasterMotionPreviewURL {
                // Для WebP/GIF без этого прогрева соседних карточек не будет: раньше при `shouldPlay=false`
                // мы отдавали `Color.clear`, и WKWebView создавался только после свайпа.
                if (shouldPlay || preloadsWhenPaused), let u = url {
                    AnimatedRasterMotionView(url: u, shouldPlay: shouldPlay, debugLogTag: debugLogTag, onPlaybackReady: onPlaybackReady)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            } else {
                videoPlayerStack
            }
        }
        .onAppear {
            let kind = isRasterMotionPreviewURL ? "animated-raster-sdwebimage" : "avplayer-video"
            logVideo("appear mediaKind=\(kind) url=\(mediaURL.prefix(120))")
        }
    }

    private var videoPlayerStack: some View {
        ZStack {
            if expandsVideoToIgnoreSafeArea {
                AppTheme.Colors.background
            }

            if let player {
                AVPlayerLayerView(
                    player: player,
                    isReadyForDisplay: $readinessObserver.isReadyForDisplay,
                    debugLogTag: debugLogTag
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(readinessObserver.isReadyForDisplay ? 1 : 0)
                .modifier(FullscreenVideoLayerModifier(enabled: expandsVideoToIgnoreSafeArea))
            } else {
                if expandsVideoToIgnoreSafeArea {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                }
            }
        }
        .task(id: mediaURL) {
            await rebuildPlayer()
        }
        .onChange(of: shouldPlay) { _, isActive in
            logVideo("onChange shouldPlay=\(isActive) playerNil=\(player == nil)")
            applyPlayback(isActive)
            if isActive {
                if readinessObserver.isReadyForDisplay { notifyPlaybackReadyIfNeeded() }
            } else {
                playbackReadyCallbackGeneration += 1
                playbackReadyNotified = false
            }
        }
        .onDisappear {
            logVideo("onDisappear tearDownPlayer()")
            tearDownPlayer()
        }
        .onChange(of: readinessObserver.isReadyForDisplay) { _, ready in
            if ready {
                // Синхронизируем play/pause: buildPlayer мог быть вызван с устаревшим shouldPlay,
                // поэтому подтверждаем состояние в момент готовности первого кадра.
                applyPlayback(shouldPlay)
                notifyPlaybackReadyIfNeeded()
            }
        }
        .onAppear {
            if readinessObserver.isReadyForDisplay {
                // Плеер уже готов (прогрет соседней карточкой): синхронизируем play/pause при появлении.
                applyPlayback(shouldPlay)
            }
            if shouldPlay, readinessObserver.isReadyForDisplay {
                notifyPlaybackReadyIfNeeded()
            }
        }
    }

    private func logVideo(_ message: String) {
        if let tag = debugLogTag {
            // print("\(tag) MediaVideoPlayer \(message)")
        }
    }

    @MainActor
    private func notifyPlaybackReadyIfNeeded() {
        guard shouldPlay, !playbackReadyNotified else { return }
        playbackReadyNotified = true
        // AVFoundation часто дергаёт готовность слоя в том же тике, что и `onChange` SwiftUI;
        // колбэк в родителе (hero `@State`) синхронно даёт «Publishing changes from within view updates» и undefined behavior.
        let callback = onPlaybackReady
        let generation = playbackReadyCallbackGeneration
        DispatchQueue.main.async {
            guard playbackReadyCallbackGeneration == generation, shouldPlay, playbackReadyNotified else { return }
            callback?()
        }
    }

    @MainActor
    private func tearDownPlayer() {
        playbackReadyCallbackGeneration += 1
        playbackReadyNotified = false
        readinessObserver.reset()
        if let obs = plainLoopObserver {
            NotificationCenter.default.removeObserver(obs)
            plainLoopObserver = nil
        }
        // AVPlayerLooper держит template item в очереди: снимаем looper до очистки queue.
        playerLooper = nil
        player?.pause()
        if let q = player as? AVQueuePlayer {
            q.removeAllItems()
        } else {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
    }

    private func rebuildPlayer() async {
        logVideo("task(id: mediaURL) begin len=\(mediaURL.count) usesDiskCache=\(usesDiskCache)")
        tearDownPlayer()

        guard let url else {
            logVideo("rebuildPlayer ABORT url=nil raw=\(mediaURL.prefix(100))")
            return
        }

        let playbackURL = await resolvePlaybackURL(for: url)
        buildPlayer(with: playbackURL)
    }

    private func resolvePlaybackURL(for url: URL) async -> URL {
        let scheme = url.scheme?.lowercased()
        guard usesDiskCache, let scheme, ["http", "https"].contains(scheme) else {
            logVideo("videoCache SKIP scheme=\(url.scheme ?? "?") usesDiskCache=\(usesDiskCache)")
            return url
        }

        let result = await EffectPreviewVideoDiskCache.shared.playbackURL(for: url)
        switch result {
        case .hit(let fileURL, let bytes):
            logVideo("videoCache HIT bytes=\(bytes) file=\(fileURL.lastPathComponent)")
            return fileURL
        case .miss(let fileURL, let bytes):
            logVideo("videoCache MISS→SAVED bytes=\(bytes) file=\(fileURL.lastPathComponent)")
            return fileURL
        case .failed(let error):
            logVideo("videoCache FAILED fallbackRemote error=\(error.localizedDescription)")
            return url
        }
    }

    @MainActor
    private func buildPlayer(with playbackURL: URL) {
        playbackReadyNotified = false
        logVideo("buildPlayer url.scheme=\(playbackURL.scheme ?? "?") host=\(playbackURL.host ?? "?") loops=\(loopsVideo) shouldPlay=\(shouldPlay)")

        if loopsVideo {
            let template = AVPlayerItem(url: playbackURL)
            applyItemAudioPolicy(to: template)

            let queue = AVQueuePlayer()
            applyAudioPolicy(to: queue)
            playerLooper = AVPlayerLooper(player: queue, templateItem: template)
            player = queue
            if expandsVideoToIgnoreSafeArea {
                observeReadiness(of: queue)
            }
            logVideo("buildPlayer AVQueuePlayer + AVPlayerLooper")
        } else {
            let item = AVPlayerItem(url: playbackURL)
            applyItemAudioPolicy(to: item)

            let next = AVPlayer(playerItem: item)
            applyAudioPolicy(to: next)
            player = next
            if expandsVideoToIgnoreSafeArea {
                observeReadiness(of: next)
            }
            let loopCallback = onPlaybackLoop
            plainLoopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak next] _ in
                DispatchQueue.main.async {
                    loopCallback?()
                }
                next?.seek(to: .zero)
                next?.play()
            }
            logVideo("buildPlayer plain AVPlayer + end observer (fallback loop)")
        }
        applyPlayback(shouldPlay)
        if shouldPlay, readinessObserver.isReadyForDisplay {
            notifyPlaybackReadyIfNeeded()
        }
    }

    private func constrainedPlaybackVolume() -> Float {
        min(1, max(0, playbackVolumeOverride ?? (isMuted ? 0 : 1)))
    }

    /// Дополнительно прижимаем громкость на уровне `AVPlayerItem` (`AVAudioMix`) — так override стабильнее, чем только `player.volume`.
    private func applyItemAudioPolicy(to item: AVPlayerItem) {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(constrainedPlaybackVolume(), at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    @MainActor
    private func applyAudioPolicy(to player: AVPlayer) {
        let v = constrainedPlaybackVolume()
        player.isMuted = v < 0.0001
        player.volume = v
    }

    @MainActor
    private func applyPlayback(_ play: Bool) {
        guard let player else { return }
        applyAudioPolicy(to: player)
        if play {
            player.play()
            logVideo("applyPlayback play()")
        } else {
            player.pause()
            logVideo("applyPlayback pause()")
        }
    }

    @MainActor
    private func observeReadiness(of player: AVPlayer) {
        readinessObserver.observe(player)
    }
}

private struct FullscreenVideoLayerModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

private final class MediaVideoPlayerReadinessObserver: ObservableObject {
    @Published var isReadyForDisplay = false

    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?

    func reset() {
        currentItemObservation = nil
        itemStatusObservation = nil
        isReadyForDisplay = false
    }

    func observe(_ player: AVPlayer) {
        reset()
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, change in
            let item = change.newValue ?? nil
            DispatchQueue.main.async {
                self?.observeStatus(of: item)
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem?) {
        itemStatusObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.isReadyForDisplay = observedItem.status == .readyToPlay
            }
        }
    }
}

fileprivate enum EffectPreviewVideoDiskCacheResult {
    case hit(URL, bytes: Int64)
    case miss(URL, bytes: Int64)
    case failed(Error)
}

// Синхронный «заголовок» приоритета до первого `playbackURL`: `AppState.openEffectDetail` выставляет URL раньше, чем SwiftUI успеет поднять соседние prewarm-плееры.
private enum EffectDetailPreviewPriorityBootstrap {
    static let lock = NSLock()
    static var pendingURLString: String?

    static func setPendingURLString(_ raw: String?) {
        lock.lock()
        pendingURLString = raw
        lock.unlock()
    }

    static func peekPendingURLString() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pendingURLString
    }
}

/// Первая сетевая попытка только по R2 с лимитом; зеркало — после таймаута/ошибки (постеры: 10 с в `ImageDownloader`; motion MP4/WebP-prewarm: 15 с ниже).
private enum EffectPreviewPrimaryR2AttemptPolicy {
    static let motionVideoDownloadTimeoutSeconds: TimeInterval = 15
    static let rasterPrewarmFirstAttemptTimeoutSeconds: TimeInterval = 15
}

#if canImport(SDWebImage)
private final class PrewarmRasterFirstAttemptGate: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}
#endif

/// Централизуем policy для Effects (home/browse/detail): где и что прогревать, и какой URL на detail получает приоритет.
/// Это первая итерация оркестратора: физические кэши остаются прежними (`EffectPreviewVideoDiskCache`/`ImageDownloader`), а решения о приоритетах уносим из View.
actor EffectsMediaOrchestrator {
    static let shared = EffectsMediaOrchestrator()

    private let videoDiskCache = EffectPreviewVideoDiskCache.shared
    private let debugTag = "[effects-preview]"
    private var activeHomeHeroSessionID: String?
    private var activeDetailSessionID: String?
    private var catalogPriorityDebounceTask: Task<Void, Never>?
    private let catalogPriorityDebounceNs: UInt64 = 1_000_000_000
    private var onboardingCatalogWarmupTask: Task<Void, Never>?
    private var onboardingCatalogWarmupSignature: String?
    private var catalogTailWarmupTask: Task<Void, Never>?
    private var catalogTailWarmupSignature: String?

    /// Параметры фонового прогрева каталога с онбординга (скролла нет — имитируем раскрытие сверху вниз).
    private enum OnboardingHomeCatalogWarmup {
        /// Сколько верхних горизонталей (hero + секции) участвуют в первой волне; на каждой следующей волне в окно добавляется следующая рельса.
        static let initialRailWindow = 3
        /// Сколько плиток на рельсу за одну волну. `1` даёт пошаговое «диагональное» раскрытие (одна ячейка на активную рельс за цикл); `3` — крупнее батчи, меньше HTTP-шагов.
        static let tilesPerWaveStride = 3
    }

    /// До показа detail заранее помечаем приоритетный URL, чтобы соседние prewarm-задачи не успели занять очередь.
    nonisolated func prepareDetailEntryPriority(previewVideoURLString: String?) {
        EffectPreviewVideoDiskCache.prepareDetailPreviewDownloadPriority(urlString: previewVideoURLString)
    }

    /// На detail активная карточка меняется при свайпе: обновляем приоритет именно для текущего пресета.
    func updateDetailCurrentPresetPriority(previewVideoURL: URL?) async {
        await videoDiskCache.setDetailPreviewDownloadPriority(url: previewVideoURL)
    }

    /// При выходе с detail снимаем приоритет, чтобы он не влиял на другие экраны.
    func resetDetailPriority() async {
        await videoDiskCache.resetDetailPreviewDownloadPriority()
    }

    /// Home rails / view-all only: даём приоритет карточке, которая только что стала видимой пользователю.
    /// Не используется для hero/detail — у них отдельные политики приоритета.
    func updateCatalogCurrentPresetPriority(previewVideoURL: URL?) async {
        await videoDiskCache.setCatalogPreviewDownloadPriority(url: previewVideoURL)
    }

    /// Home rails / view-all only: anti-jitter debounce для быстрых скроллов.
    /// Не затрагивает hero/detail и не должен вызываться из этих экранов.
    /// Приоритет реально повышаем только если карточка остаётся видимой достаточное время.
    func scheduleCatalogCurrentPresetPriority(previewVideoURL: URL?) {
        catalogPriorityDebounceTask?.cancel()
        catalogPriorityDebounceTask = Task { [catalogPriorityDebounceNs] in
            try? await Task.sleep(nanoseconds: catalogPriorityDebounceNs)
            if Task.isCancelled { return }
            await self.videoDiskCache.setCatalogPreviewDownloadPriority(url: previewVideoURL)
        }
    }

    /// Централизованная переоценка фоновой очереди для main-экрана:
    /// сначала пересчитываем фактический хвост, и только если он изменился — перезапускаем warmup-задачу.
    func reevaluateCatalogTailWarmupForHome(payload: EffectsHomePayload) {
        let prioritizedMotion = prioritizedHomeLandingPreviewURLs(from: payload)
        let prioritizedPoster = prioritizedHomeLandingPosterURLs(from: payload)

        let lookaheadMotion = homeVerticalLookaheadMotionURLs(from: payload)
        let lookaheadPoster = homeVerticalLookaheadPosterURLs(from: payload)

        let allMotion = orderedHomeLandingMotionPreviewURLs(from: payload)
        let allPoster = orderedHomeLandingPosterURLs(from: payload)

        let queueMotion = uniqueOrdered(prioritizedMotion + lookaheadMotion + allMotion)
        let queuePoster = uniqueOrdered(prioritizedPoster + lookaheadPoster + allPoster)

        let signature = "home||\(queueMotion.joined(separator: "|"))||\(queuePoster.joined(separator: "|"))"
        guard signature != catalogTailWarmupSignature else { return }

        catalogTailWarmupTask?.cancel()
        catalogTailWarmupSignature = signature
        catalogTailWarmupTask = Task {
            await self.runCatalogTailWarmup(
                motionURLs: queueMotion,
                posterURLs: queuePoster,
                debugLogTag: "\(self.debugTag)[home-tail]"
            )
        }
    }

    /// Централизованная переоценка фоновой очереди для View All.
    func reevaluateCatalogTailWarmupForBrowse(section: EffectsHomeSection) {
        let motionURLs = orderedBrowseMotionPreviewURLs(from: section)
        let posterURLs = orderedBrowsePosterURLs(from: section)
        let signature = "browse:\(section.id)||\(motionURLs.joined(separator: "|"))||\(posterURLs.joined(separator: "|"))"
        guard signature != catalogTailWarmupSignature else { return }

        catalogTailWarmupTask?.cancel()
        catalogTailWarmupSignature = signature
        catalogTailWarmupTask = Task {
            await self.runCatalogTailWarmup(
                motionURLs: motionURLs,
                posterURLs: posterURLs,
                debugLogTag: "\(self.debugTag)[browse-tail]"
            )
        }
    }

    /// На home прогреваем только hero-URL, когда экран активен.
    func prewarmHomeHeroIfNeeded(sceneIsActive: Bool, heroVideoURLString: String?) async {
        guard sceneIsActive, let heroVideoURLString else { return }
        await videoDiskCache.prewarm(
            remoteURLStrings: [heroVideoURLString],
            debugLogTag: debugTag
        )
    }

    /// Дроп подписей и in-flight задач прогрева после Debug «Очистить кэш»: иначе при повторном входе в онбординг/мейн `signature` совпадает, `await task.value` отдаёт мгновенный hit, и реального прогрева не происходит.
    func resetCatalogWarmupStateAfterCacheClear() {
        onboardingCatalogWarmupTask?.cancel()
        onboardingCatalogWarmupTask = nil
        onboardingCatalogWarmupSignature = nil
        catalogTailWarmupTask?.cancel()
        catalogTailWarmupTask = nil
        catalogTailWarmupSignature = nil
    }

    /// На detail прогреваем текущий и ближайшие соседние пресеты карусели.
    func prewarmDetailIfNeeded(
        sceneIsActive: Bool,
        selectedPreset: EffectPreset?,
        carouselPresets: [EffectPreset]
    ) async {
        guard sceneIsActive else { return }
        let urls = nearbyDetailPreviewURLs(selectedPreset: selectedPreset, carouselPresets: carouselPresets)
        await videoDiskCache.prewarm(
            remoteURLStrings: urls,
            debugLogTag: debugTag
        )
    }

    /// Home hero: один активный session за раз; если screen не active, прогрев не запускаем.
    func updateHomeHeroSession(
        sceneIsActive: Bool,
        heroSessionID: String,
        heroVideoURLString: String?
    ) async {
        if sceneIsActive {
            activeHomeHeroSessionID = heroSessionID
        } else if activeHomeHeroSessionID == heroSessionID {
            activeHomeHeroSessionID = nil
        }
        guard sceneIsActive, activeHomeHeroSessionID == heroSessionID else { return }
        await prewarmHomeHeroIfNeeded(sceneIsActive: sceneIsActive, heroVideoURLString: heroVideoURLString)
    }

    /// Прогрев для онбординга: «диагональные» волны главной (постеры → motion), без привязки к скроллу.
    /// `EffectPreviewVideoDiskCache`: на время прогрева отключаем catalog-priority gate — иначе главная ставит приоритет на одну видимую карточку и весь MP4-prewarm онбординга ждёт её.
    /// Хвост главной (`reevaluateCatalogTailWarmupForHome`) ждёт завершения этой задачи, чтобы не забивать тот же актор очередью «motion всего каталога».
    func prewarmHomeLandingFromOnboardingIfNeeded(
        sceneIsActive: Bool,
        payload: EffectsHomePayload
    ) async {
        guard sceneIsActive else { return }
        let rails = homeOnboardingWarmupRails(from: payload)
        let steps = onboardingDiagonalWarmupSteps(rails: rails)
        let signature = steps.map { "\($0.posters.joined(separator: "|"))@@\($0.motions.joined(separator: "|"))" }
            .joined(separator: "##")

        let task: Task<Void, Never>
        if onboardingCatalogWarmupSignature == signature,
           let existingTask = onboardingCatalogWarmupTask,
           !existingTask.isCancelled {
            task = existingTask
        } else {
            onboardingCatalogWarmupTask?.cancel()
            onboardingCatalogWarmupSignature = signature
            task = Task {
                await self.runOnboardingDiagonalCatalogWarmup(steps: steps)
            }
            onboardingCatalogWarmupTask = task
        }
        await task.value
    }

    /// Detail session объединяет два шага: приоритет текущего пресета + prewarm соседей.
    func updateDetailSession(
        sceneIsActive: Bool,
        detailSessionID: String,
        selectedPreset: EffectPreset?,
        carouselPresets: [EffectPreset]
    ) async {
        if sceneIsActive {
            activeDetailSessionID = detailSessionID
        } else if activeDetailSessionID == detailSessionID {
            activeDetailSessionID = nil
        }
        guard activeDetailSessionID == detailSessionID else { return }
        await updateDetailCurrentPresetPriority(previewVideoURL: selectedPreset?.previewVideoURL)
        await prewarmDetailIfNeeded(
            sceneIsActive: sceneIsActive,
            selectedPreset: selectedPreset,
            carouselPresets: carouselPresets
        )
    }

    private func nearbyDetailPreviewURLs(
        selectedPreset: EffectPreset?,
        carouselPresets: [EffectPreset]
    ) -> [String] {
        guard !carouselPresets.isEmpty else {
            return selectedPreset?.previewVideoURL.map { [$0.absoluteString] } ?? []
        }
        guard let selectedPreset,
              let idx = carouselPresets.firstIndex(where: { $0.id == selectedPreset.id }) else {
            return Array(carouselPresets.prefix(3)).compactMap { $0.previewVideoURL?.absoluteString }
        }
        var result: [EffectPreset] = [carouselPresets[idx]]
        if carouselPresets.count > 1 {
            result.append(carouselPresets[(idx + 1) % carouselPresets.count])
        }
        if carouselPresets.count > 2 {
            result.append(carouselPresets[(idx + carouselPresets.count - 1) % carouselPresets.count])
        }
        return result.compactMap { $0.previewVideoURL?.absoluteString }
    }

    /// Приоритет загрузки на первом заходе в EffectsHome:
    /// 1) активный hero (индекс 0), 2) первые 3 карточки первой секции, 3) первые 3 карточки второй секции.
    private func prioritizedHomeLandingPreviewURLs(from payload: EffectsHomePayload) -> [String] {
        var urls: [String] = []

        if let hero = payload.hero,
           let firstHeroURL = hero.items.first?.preset.previewVideoURL?.absoluteString {
            urls.append(firstHeroURL)
        }

        if let firstSection = payload.sections.first {
            urls.append(contentsOf: firstSection.items.prefix(3).compactMap { $0.preset.previewVideoURL?.absoluteString })
        }

        if payload.sections.count > 1 {
            urls.append(contentsOf: payload.sections[1].items.prefix(3).compactMap { $0.preset.previewVideoURL?.absoluteString })
        }

        // Убираем дубли, сохраняя приоритетный порядок.
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Полный порядок motion-прогрева как в UI-проходе рельс: hero -> все карточки section[0] -> section[1] -> ...
    private func orderedHomeLandingMotionPreviewURLs(from payload: EffectsHomePayload) -> [String] {
        var urls: [String] = []
        if let hero = payload.hero {
            urls.append(contentsOf: hero.items.compactMap { $0.preset.previewVideoURL?.absoluteString })
        }
        for section in payload.sections {
            urls.append(contentsOf: section.items.compactMap { $0.preset.previewVideoURL?.absoluteString })
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Приоритет постеров на первом заходе: те же карточки, что и в motion-priority блоке.
    private func prioritizedHomeLandingPosterURLs(from payload: EffectsHomePayload) -> [String] {
        var urls: [String] = []
        if let hero = payload.hero {
            urls.append(contentsOf: hero.items.prefix(1).compactMap { $0.preset.previewImageURL?.absoluteString })
        }
        if let firstSection = payload.sections.first {
            urls.append(contentsOf: firstSection.items.prefix(3).compactMap { $0.preset.previewImageURL?.absoluteString })
        }
        if payload.sections.count > 1 {
            urls.append(contentsOf: payload.sections[1].items.prefix(3).compactMap { $0.preset.previewImageURL?.absoluteString })
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Полный порядок прогрева постеров в рельсовом порядке.
    private func orderedHomeLandingPosterURLs(from payload: EffectsHomePayload) -> [String] {
        var urls: [String] = []
        if let hero = payload.hero {
            urls.append(contentsOf: hero.items.compactMap { $0.preset.previewImageURL?.absoluteString })
        }
        for section in payload.sections {
            urls.append(contentsOf: section.items.compactMap { $0.preset.previewImageURL?.absoluteString })
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// После hero + 2x3 main-экрана подхватываем первые 3 карточки следующей секции как "next fold" lookahead.
    private func homeVerticalLookaheadMotionURLs(from payload: EffectsHomePayload) -> [String] {
        guard payload.sections.count > 2 else { return [] }
        return payload.sections[2].items.prefix(3).compactMap { $0.preset.previewVideoURL?.absoluteString }
    }

    private func homeVerticalLookaheadPosterURLs(from payload: EffectsHomePayload) -> [String] {
        guard payload.sections.count > 2 else { return [] }
        return payload.sections[2].items.prefix(3).compactMap { $0.preset.previewImageURL?.absoluteString }
    }

    private func orderedBrowseMotionPreviewURLs(from section: EffectsHomeSection) -> [String] {
        var seen = Set<String>()
        let urls = section.items.compactMap { $0.preset.previewVideoURL?.absoluteString }
        return urls.filter { seen.insert($0).inserted }
    }

    private func orderedBrowsePosterURLs(from section: EffectsHomeSection) -> [String] {
        var seen = Set<String>()
        let urls = section.items.compactMap { $0.preset.previewImageURL?.absoluteString }
        return urls.filter { seen.insert($0).inserted }
    }

    /// Страховка для очередей prewarm: сохраняем порядок приоритетов, но не отправляем один и тот же URL повторно.
    private func uniqueOrdered(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Одна ячейка рельса онбордингового прогрева: постер и motion совпадают по индексу с карточкой в payload.
    private struct OnboardingHomeWarmupCell {
        let posterURL: String?
        let motionURL: String?
    }

    /// Рельсы как на главной: hero (если есть), затем секции по порядку.
    private func homeOnboardingWarmupRails(from payload: EffectsHomePayload) -> [[OnboardingHomeWarmupCell]] {
        var rails: [[OnboardingHomeWarmupCell]] = []
        if let hero = payload.hero {
            let heroRail = hero.items.map {
                OnboardingHomeWarmupCell(
                    posterURL: $0.preset.previewImageURL?.absoluteString,
                    motionURL: $0.preset.previewVideoURL?.absoluteString
                )
            }
            if !heroRail.isEmpty {
                rails.append(heroRail)
            }
        }
        for section in payload.sections {
            let sectionRail = section.items.map {
                OnboardingHomeWarmupCell(
                    posterURL: $0.preset.previewImageURL?.absoluteString,
                    motionURL: $0.preset.previewVideoURL?.absoluteString
                )
            }
            if !sectionRail.isEmpty {
                rails.append(sectionRail)
            }
        }
        return rails
    }

    /// Диагональное окно: старт с `OnboardingHomeCatalogWarmup.initialRailWindow` рельс по `tilesPerWaveStride` плиток; каждый следующий цикл добавляет следующую рельсу и сдвигает уже открытые на +stride, пока не исчерпаем каталог.
    /// Каждый шаг = одна рельса в текущем цикле: сначала постеры шага, затем сразу motion этого же шага; дубликаты URL отбрасываем глобально.
    private func onboardingDiagonalWarmupSteps(
        rails: [[OnboardingHomeWarmupCell]]
    ) -> [(posters: [String], motions: [String])] {
        guard !rails.isEmpty else { return [] }
        let initialRailCount = OnboardingHomeCatalogWarmup.initialRailWindow
        let tileStride = OnboardingHomeCatalogWarmup.tilesPerWaveStride
        let numRails = rails.count
        var steps: [(posters: [String], motions: [String])] = []
        var seenPoster = Set<String>()
        var seenMotion = Set<String>()
        var cycle = 0
        while true {
            let maxRailExclusive = min(initialRailCount + cycle, numRails)
            var didEmitStepInCycle = false
            for r in 0..<maxRailExclusive {
                let firstCycleForRail = max(0, r - (initialRailCount - 1))
                guard cycle >= firstCycleForRail else { continue }
                let chunk = cycle - firstCycleForRail
                let lo = chunk * tileStride
                let rail = rails[r]
                guard lo < rail.count else { continue }
                let hi = min(lo + tileStride, rail.count)
                var posterStep: [String] = []
                var motionStep: [String] = []
                for idx in lo..<hi {
                    let cell = rail[idx]
                    if let p = cell.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                       p.hasPrefix("http"),
                       seenPoster.insert(p).inserted {
                        posterStep.append(p)
                    }
                    if let m = cell.motionURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                       m.hasPrefix("http"),
                       seenMotion.insert(m).inserted {
                        motionStep.append(m)
                    }
                }
                if !posterStep.isEmpty || !motionStep.isEmpty {
                    steps.append((posterStep, motionStep))
                    didEmitStepInCycle = true
                }
            }
            if !didEmitStepInCycle { break }
            cycle += 1
        }
        return steps
    }

    /// Онбординг: каждый диагональный шаг прогреваем парой "posters -> motion" (включая raster webp/gif).
    private func runOnboardingDiagonalCatalogWarmup(
        steps: [(posters: [String], motions: [String])]
    ) async {
        await videoDiskCache.setSkipCatalogPreviewPriorityGateForOnboardingBulkPrewarm(true)
        for (idx, step) in steps.enumerated() {
            if Task.isCancelled {
                await videoDiskCache.setSkipCatalogPreviewPriorityGateForOnboardingBulkPrewarm(false)
                return
            }
            let waveTag = "\(debugTag)[onboarding][step\(idx)]"
            await prewarmPosterURLsSequentially(step.posters, debugLogTag: waveTag)
            if Task.isCancelled {
                await videoDiskCache.setSkipCatalogPreviewPriorityGateForOnboardingBulkPrewarm(false)
                return
            }
            await prewarmMotionURLsSequentially(step.motions, debugLogTag: waveTag)
        }
        await videoDiskCache.setSkipCatalogPreviewPriorityGateForOnboardingBulkPrewarm(false)
    }

    /// Хвост каталога не должен забивать `EffectPreviewVideoDiskCache` параллельно с онбординговым диагональным прогревом — иначе на главной «висят» лоадеры, пока очередь хвоста не исчерпана.
    private func awaitOnboardingCatalogWarmupIfNeeded() async {
        guard let task = onboardingCatalogWarmupTask else { return }
        await task.value
    }

    /// Фоновая догрузка хвоста каталога: сначала motion, потом постеры; каждый шаг идёт последовательно и может быть прерван более новой переоценкой очереди.
    private func runCatalogTailWarmup(
        motionURLs: [String],
        posterURLs: [String],
        debugLogTag: String
    ) async {
        await awaitOnboardingCatalogWarmupIfNeeded()
        await prewarmPosterURLsSequentially(posterURLs, debugLogTag: debugLogTag)
        await prewarmMotionURLsSequentially(motionURLs, debugLogTag: debugLogTag)
    }

    private func prewarmMotionURLsSequentially(_ urls: [String], debugLogTag: String) async {
        guard !urls.isEmpty else { return }
        for raw in urls {
            if Task.isCancelled { return }
            if MediaVideoPlayer.isRasterMotionAssetURLString(raw) {
                await prewarmRasterMotionURLIfNeeded(raw, debugLogTag: debugLogTag)
            } else {
                await videoDiskCache.prewarm(
                    remoteURLStrings: [raw],
                    debugLogTag: debugLogTag
                )
            }
        }
    }

    private func prewarmPosterURLsSequentially(_ urls: [String], debugLogTag: String) async {
        guard !urls.isEmpty else { return }
        for raw in urls {
            if Task.isCancelled { return }
            await prewarmRemoteImageURLIfNeeded(raw, debugLogTag: debugLogTag)
        }
    }

    #if canImport(SDWebImage)
    /// Prewarm WebP/GIF: только R2 с лимитом, затем зеркало — без опережающего запроса зеркала.
    private func sdPrewarmLoadRasterCandidate(url: URL, r2FirstAttemptTimeout: TimeInterval?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = PrewarmRasterFirstAttemptGate()
            var timeoutWorkItem: DispatchWorkItem?

            let finish: (Bool) -> Void = { success in
                timeoutWorkItem?.cancel()
                DispatchQueue.main.async {
                    guard gate.take() else { return }
                    continuation.resume(returning: success)
                }
            }

            if let t = r2FirstAttemptTimeout, t > 0 {
                let item = DispatchWorkItem {
                    finish(false)
                }
                timeoutWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
            }

            SDWebImageManager.shared.loadImage(
                with: url,
                options: [],
                context: [.animatedImageClass: SDAnimatedImage.self],
                progress: nil
            ) { image, data, _, _, isFinished, _ in
                guard isFinished else { return }
                let ok = image != nil || data != nil
                DispatchQueue.main.async {
                    finish(ok)
                }
            }
        }
    }
    #endif

    private func prewarmRasterMotionURLIfNeeded(_ urlString: String, debugLogTag: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http"), !trimmed.isEmpty else { return }
        #if canImport(SDWebImage)
        guard let primaryURL = URL(string: trimmed) else { return }
        let candidates = [primaryURL] + (PreviewMediaURLFallback.fallbackURL(from: primaryURL).map { [$0] } ?? [])
        let hasMirror = candidates.count > 1
        for (index, candidate) in candidates.enumerated() {
            guard let cacheKey = SDWebImageManager.shared.cacheKey(for: candidate) else { continue }
            if SDImageCache.shared.imageFromMemoryCache(forKey: cacheKey) != nil ||
                SDImageCache.shared.diskImageDataExists(withKey: cacheKey) {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .effectPreviewVideoCacheUpdated,
                        object: nil,
                        userInfo: ["url": trimmed]
                    )
                }
                return
            }
            let r2Timeout: TimeInterval? = (index == 0 && hasMirror)
                ? EffectPreviewPrimaryR2AttemptPolicy.rasterPrewarmFirstAttemptTimeoutSeconds
                : nil
            let loaded = await sdPrewarmLoadRasterCandidate(url: candidate, r2FirstAttemptTimeout: r2Timeout)
            if loaded {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .effectPreviewVideoCacheUpdated,
                        object: nil,
                        userInfo: ["url": trimmed]
                    )
                }
                return
            }
        }
        #else
        await prewarmRemoteImageURLIfNeeded(trimmed, debugLogTag: debugLogTag)
        #endif
    }

    private func prewarmRemoteImageURLIfNeeded(_ urlString: String, debugLogTag: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http"), !trimmed.isEmpty else { return }
        if ImageDownloader.shared.getCachedImage(from: trimmed) != nil { return }
        await withCheckedContinuation { continuation in
            ImageDownloader.shared.downloadImage(
                from: trimmed,
                effectPreviewLogTag: debugLogTag,
                networkRequestTimeout: ImageDownloader.effectPreviewPosterNetworkRequestTimeoutSeconds
            ) { _ in
                continuation.resume()
            }
        }
    }
}

/// Дисковый кэш remote preview-video: AVPlayer сам не использует наш image cache, поэтому сохраняем ролики в Caches и играем локальный файл.
actor EffectPreviewVideoDiskCache {
    static let shared = EffectPreviewVideoDiskCache()

    private var inFlight: [URL: Task<URL, Error>] = [:]

    /// На экране Effect Detail: один remote MP4 имеет приоритет — остальные `playbackURL` ждут, пока он не окажется в кэше (или приоритет снят). Снижает гонку с соседями карусели и «хвостами» загрузок после ухода с главной.
    private var highPriorityDetailPreviewURL: URL?
    private var detailPriorityGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Для home rails/view-all: последняя видимая карточка получает наивысший приоритет загрузки.
    private var highPriorityCatalogPreviewURL: URL?
    private var catalogPriorityGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Пока идёт массовый prewarm с онбординга, гейт «видимая карточка главной» отключаем — иначе все MP4 ждут один приоритетный URL.
    private var skipCatalogPreviewPriorityGateForOnboardingBulkPrewarm = false

    private static let cacheDirectoryName = "EffectPreviewVideos"

    /// Включается только на время `runOnboardingDiagonalCatalogWarmup`, чтобы prewarm не блокировался `setCatalogPreviewDownloadPriority` с главной.
    func setSkipCatalogPreviewPriorityGateForOnboardingBulkPrewarm(_ value: Bool) {
        skipCatalogPreviewPriorityGateForOnboardingBulkPrewarm = value
    }

    /// Вызывается с Main **до** `currentScreen = .effectDetail`, чтобы первый же `playbackURL` знал приоритетный URL.
    nonisolated static func prepareDetailPreviewDownloadPriority(urlString: String?) {
        EffectDetailPreviewPriorityBootstrap.setPendingURLString(urlString)
    }

    nonisolated static func clearPendingDetailPreviewDownloadPriorityBootstrap() {
        EffectDetailPreviewPriorityBootstrap.setPendingURLString(nil)
    }

    /// Смена выбранного пресета в карусели detail: приоритет только для AV-видео (MP4/MOV), иначе не ставим гейт.
    func setDetailPreviewDownloadPriority(url: URL?) {
        let newURL = url.flatMap { Self.normalizedAVHTTPURL(from: $0.absoluteString) }
        if newURL?.absoluteString != highPriorityDetailPreviewURL?.absoluteString {
            highPriorityDetailPreviewURL = newURL
            resumeDetailPriorityGateWaiters()
        }
    }

    /// Уход с detail: снять приоритет и разблокировать очередь.
    func resetDetailPreviewDownloadPriority() {
        highPriorityDetailPreviewURL = nil
        Self.clearPendingDetailPreviewDownloadPriorityBootstrap()
        resumeDetailPriorityGateWaiters()
    }

    /// Home rails / view-all: приоритет отдаём карточке, которую пользователь видит прямо сейчас.
    func setCatalogPreviewDownloadPriority(url: URL?) {
        let newURL = url.flatMap { Self.normalizedAVHTTPURL(from: $0.absoluteString) }
        if newURL?.absoluteString != highPriorityCatalogPreviewURL?.absoluteString {
            highPriorityCatalogPreviewURL = newURL
            resumeCatalogPriorityGateWaiters()
        }
    }

    private func syncDetailPreviewPriorityFromBootstrapIfNeeded() {
        guard highPriorityDetailPreviewURL == nil else { return }
        guard let raw = EffectDetailPreviewPriorityBootstrap.peekPendingURLString(),
              let u = Self.normalizedAVHTTPURL(from: raw) else { return }
        highPriorityDetailPreviewURL = u
    }

    private func resumeDetailPriorityGateWaiters() {
        let waiters = detailPriorityGateWaiters
        detailPriorityGateWaiters.removeAll()
        for w in waiters {
            w.resume()
        }
    }

    private func resumeCatalogPriorityGateWaiters() {
        let waiters = catalogPriorityGateWaiters
        catalogPriorityGateWaiters.removeAll()
        for w in waiters {
            w.resume()
        }
    }

    private func resumeDetailPriorityGateIfPriorityFileReady(for remoteURL: URL, fileURL: URL) {
        guard let p = highPriorityDetailPreviewURL,
              p.absoluteString == remoteURL.absoluteString,
              let b = fileSize(at: fileURL), b > 0 else { return }
        resumeDetailPriorityGateWaiters()
    }

    private func resumeDetailPriorityGateIfPriorityFailed(for remoteURL: URL) {
        guard let p = highPriorityDetailPreviewURL,
              p.absoluteString == remoteURL.absoluteString else { return }
        // При падении приоритетной загрузки снимаем priority, иначе остальные URL могут бесконечно ждать этот файл.
        highPriorityDetailPreviewURL = nil
        resumeDetailPriorityGateWaiters()
    }

    private func resumeCatalogPriorityGateIfPriorityFileReady(for remoteURL: URL, fileURL: URL) {
        guard let p = highPriorityCatalogPreviewURL,
              p.absoluteString == remoteURL.absoluteString,
              let b = fileSize(at: fileURL), b > 0 else { return }
        resumeCatalogPriorityGateWaiters()
    }

    private func resumeCatalogPriorityGateIfPriorityFailed(for remoteURL: URL) {
        guard let p = highPriorityCatalogPreviewURL,
              p.absoluteString == remoteURL.absoluteString else { return }
        // Аналогично detail: failure на приоритетном URL не должен блокировать очередь остальных карточек.
        highPriorityCatalogPreviewURL = nil
        resumeCatalogPriorityGateWaiters()
    }

    private func waitBehindDetailPreviewPriorityGateIfNeeded(for remoteURL: URL) async {
        while !Task.isCancelled {
            syncDetailPreviewPriorityFromBootstrapIfNeeded()
            guard let priority = highPriorityDetailPreviewURL else { return }
            guard priority.absoluteString != remoteURL.absoluteString else { return }
            let priorityFile = cacheFileURL(for: priority)
            if let bytes = fileSize(at: priorityFile), bytes > 0 { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                detailPriorityGateWaiters.append(continuation)
            }
        }
    }

    private func waitBehindCatalogPreviewPriorityGateIfNeeded(for remoteURL: URL) async {
        while !Task.isCancelled {
            if skipCatalogPreviewPriorityGateForOnboardingBulkPrewarm { return }
            guard let priority = highPriorityCatalogPreviewURL else { return }
            guard priority.absoluteString != remoteURL.absoluteString else { return }
            let priorityFile = cacheFileURL(for: priority)
            if let bytes = fileSize(at: priorityFile), bytes > 0 { return }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                catalogPriorityGateWaiters.append(continuation)
            }
        }
    }

    /// Debug / «Очистить кэш»: снимаем in-flight загрузки и удаляем каталог превью-видео (MP4 и т.д.); не трогает файлы галереи и `GalleryThumbnailCache`.
    func clearAll() {
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
        highPriorityDetailPreviewURL = nil
        highPriorityCatalogPreviewURL = nil
        skipCatalogPreviewPriorityGateForOnboardingBulkPrewarm = false
        Self.clearPendingDetailPreviewDownloadPriorityBootstrap()
        resumeDetailPriorityGateWaiters()
        resumeCatalogPriorityGateWaiters()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }

    fileprivate func playbackURL(for remoteURL: URL) async -> EffectPreviewVideoDiskCacheResult {
        syncDetailPreviewPriorityFromBootstrapIfNeeded()
        let fileURL = cacheFileURL(for: remoteURL)
        let remoteURLString = remoteURL.absoluteString

        if let bytes = fileSize(at: fileURL), bytes > 0 {
            resumeDetailPriorityGateIfPriorityFileReady(for: remoteURL, fileURL: fileURL)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .effectPreviewVideoCacheUpdated,
                    object: nil,
                    userInfo: ["url": remoteURLString]
                )
            }
            return .hit(fileURL, bytes: bytes)
        }
        if let aliasedURL = aliasFallbackCachedFileIfNeeded(for: remoteURL, canonicalFileURL: fileURL),
           let bytes = fileSize(at: aliasedURL), bytes > 0 {
            resumeDetailPriorityGateIfPriorityFileReady(for: remoteURL, fileURL: aliasedURL)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .effectPreviewVideoCacheUpdated,
                    object: nil,
                    userInfo: ["url": remoteURLString]
                )
            }
            return .hit(aliasedURL, bytes: bytes)
        }

        await waitBehindDetailPreviewPriorityGateIfNeeded(for: remoteURL)
        await waitBehindCatalogPreviewPriorityGateIfNeeded(for: remoteURL)
        if Task.isCancelled {
            return .failed(URLError(.cancelled))
        }

        do {
            let task: Task<URL, Error>
            if let existing = inFlight[remoteURL] {
                task = existing
            } else {
                task = Task {
                    try await Self.download(remoteURL: remoteURL, to: fileURL)
                }
                inFlight[remoteURL] = task
            }

            let savedURL = try await task.value
            inFlight[remoteURL] = nil
            resumeDetailPriorityGateIfPriorityFileReady(for: remoteURL, fileURL: savedURL)
            resumeCatalogPriorityGateIfPriorityFileReady(for: remoteURL, fileURL: savedURL)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .effectPreviewVideoCacheUpdated,
                    object: nil,
                    userInfo: ["url": remoteURLString]
                )
            }
            return .miss(savedURL, bytes: fileSize(at: savedURL) ?? 0)
        } catch {
            inFlight[remoteURL] = nil
            resumeDetailPriorityGateIfPriorityFailed(for: remoteURL)
            resumeCatalogPriorityGateIfPriorityFailed(for: remoteURL)
            return .failed(error)
        }
    }

    /// Прогрев дискового кэша только для верхних видимых карточек: сохраняем remote preview-video заранее, чтобы при показе AVPlayer стартовал с локального файла.
    func prewarm(remoteURLStrings: [String], debugLogTag: String? = nil) async {
        let unique = Self.uniqueHTTPURLs(from: remoteURLStrings)
            .filter { !MediaVideoPlayer.isRasterMotionAssetURLString($0.absoluteString) }
        guard !unique.isEmpty else { return }
        for remoteURL in unique {
            if Task.isCancelled { return }
            _ = await playbackURL(for: remoteURL)
            // if let debugLogTag {
            //     print("\(debugLogTag) EffectPreviewVideoDiskCache prewarm url=\(remoteURL.absoluteString.prefix(110))")
            // }
        }
    }

    private func cacheFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        return Self.cacheFileURL(digest: digest, ext: ext)
    }

    /// Миграция старого ключа fallback -> канонический URL: если файл уже есть под зеркалом, переиспользуем его и дублируем под основной ключ.
    private func aliasFallbackCachedFileIfNeeded(for remoteURL: URL, canonicalFileURL: URL) -> URL? {
        guard let fallbackURL = PreviewMediaURLFallback.fallbackURL(from: remoteURL), fallbackURL != remoteURL else {
            return nil
        }
        let fallbackFileURL = cacheFileURL(for: fallbackURL)
        guard let fallbackBytes = fileSize(at: fallbackFileURL), fallbackBytes > 0 else {
            return nil
        }
        if (fileSize(at: canonicalFileURL) ?? 0) <= 0 {
            try? FileManager.default.removeItem(at: canonicalFileURL)
            try? FileManager.default.copyItem(at: fallbackFileURL, to: canonicalFileURL)
        }
        if let canonicalBytes = fileSize(at: canonicalFileURL), canonicalBytes > 0 {
            return canonicalFileURL
        }
        return fallbackFileURL
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// Корень дискового кэша превью-видео (тот же путь, что внутри актора); для debug-оценки размера без await.
    nonisolated static func cacheRootURLForDiagnostics() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    /// Быстрая проверка для UI-решения «сразу loader → motion без промежуточного постера».
    nonisolated static func hasCachedVideo(for remoteURLString: String) -> Bool {
        guard let remoteURL = normalizedHTTPURL(from: remoteURLString),
              !MediaVideoPlayer.isRasterMotionAssetURLString(remoteURLString) else {
            return false
        }
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let fileURL = cacheFileURL(digest: digest, ext: ext)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > 0 {
            return true
        }
        guard let fallbackURL = PreviewMediaURLFallback.fallbackURL(from: remoteURL),
              fallbackURL != remoteURL else {
            return false
        }
        let fallbackDigest = SHA256.hash(data: Data(fallbackURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let fallbackExt = fallbackURL.pathExtension.isEmpty ? "mp4" : fallbackURL.pathExtension
        let fallbackFileURL = cacheFileURL(digest: fallbackDigest, ext: fallbackExt)
        guard let fallbackAttrs = try? FileManager.default.attributesOfItem(atPath: fallbackFileURL.path),
              let fallbackSize = fallbackAttrs[.size] as? NSNumber,
              fallbackSize.int64Value > 0 else {
            return false
        }
        // Нормализуем кэш на лету: после первого попадания по legacy fallback UI и prewarm видят канонический ключ.
        let canonicalAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let canonicalSize = (canonicalAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        if canonicalSize <= 0 {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.copyItem(at: fallbackFileURL, to: fileURL)
        }
        return true
    }

    /// Сумма байт файлов в каталоге превью (до `clearAll()`).
    nonisolated static func estimatedDiskUsageBytes() -> Int64 {
        ImageDownloader.totalRegularFileBytes(in: cacheRootURLForDiagnostics())
    }

    nonisolated private static func cacheFileURL(digest: String, ext: String) -> URL {
        cacheDirectory.appendingPathComponent("\(digest).\(ext)", isDirectory: false)
    }

    nonisolated private static func normalizedHTTPURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    nonisolated private static func normalizedAVHTTPURL(from raw: String) -> URL? {
        guard let url = normalizedHTTPURL(from: raw),
              !MediaVideoPlayer.isRasterMotionAssetURLString(url.absoluteString) else {
            return nil
        }
        return url
    }

    nonisolated private static func uniqueHTTPURLs(from rawValues: [String]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        result.reserveCapacity(rawValues.count)
        for raw in rawValues {
            guard let url = normalizedHTTPURL(from: raw) else { continue }
            if seen.insert(url.absoluteString).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func download(remoteURL: URL, to destinationURL: URL) async throws -> URL {
        // R2 в части регионов «висит» без быстрого error — без лимита на первую попытку prewarm/плеер долго стоят в очереди и fallback не наступает.
        let primaryTimeout: TimeInterval? = PreviewMediaURLFallback.fallbackURL(from: remoteURL) != nil
            ? EffectPreviewPrimaryR2AttemptPolicy.motionVideoDownloadTimeoutSeconds
            : nil
        do {
            return try await performDownload(from: remoteURL, to: destinationURL, timeout: primaryTimeout)
        } catch {
            // Если исходный CDN недоступен (региональные блокировки), делаем retry по PixVerse URL, вычисленному из имени файла.
            guard let fallbackURL = PreviewMediaURLFallback.fallbackURL(from: remoteURL),
                  fallbackURL != remoteURL else {
                throw error
            }
            return try await performDownload(from: fallbackURL, to: destinationURL, timeout: nil)
        }
    }

    private static func performDownload(from sourceURL: URL, to destinationURL: URL, timeout: TimeInterval?) async throws -> URL {
        let request: URLRequest
        if let timeout {
            request = URLRequest(
                url: sourceURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: timeout
            )
        } else {
            request = URLRequest(url: sourceURL)
        }
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
    }
}

/// Встроенный слой видео для карточек/hero/detail: aspect-fill обрезает края и не даёт системного letterbox/контролов `VideoPlayer`.
private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var isReadyForDisplay: Bool
    let debugLogTag: String?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.backgroundColor = UIColor.clear.cgColor
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.layer.masksToBounds = true
        // AVPlayerLayer — UIView: SwiftUI's .allowsHitTesting(false) работает только на уровне SwiftUI.
        // Чтобы UIKit-слой не перехватывал касания до кнопки-обёртки — отключаем интерактивность здесь.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.observe(uiView.playerLayer, player: player, isReadyForDisplay: $isReadyForDisplay, debugLogTag: debugLogTag)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var observedLayer: AVPlayerLayer?
        private weak var observedPlayer: AVPlayer?
        private var readyObservation: NSKeyValueObservation?

        func observe(_ layer: AVPlayerLayer, player: AVPlayer, isReadyForDisplay: Binding<Bool>, debugLogTag: String?) {
            guard observedLayer !== layer || observedPlayer !== player else { return }
            observedLayer = layer
            observedPlayer = player
            isReadyForDisplay.wrappedValue = layer.isReadyForDisplay
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { observedLayer, _ in
                DispatchQueue.main.async {
                    let ready = observedLayer.isReadyForDisplay
                    isReadyForDisplay.wrappedValue = ready
                    if let debugLogTag {
                        // print("\(debugLogTag) MediaVideoPlayer layer.readyForDisplay=\(ready)")
                    }
                }
            }
        }
    }
}

private final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Даже если UIKit где-то переустановит `isUserInteractionEnabled`, слой превью не должен воровать тапы у карточки-Button.
        false
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

// Animated WebP/GIF через `UIImage` превращается в первый статичный кадр; для motion используем SDWebImageSwiftUI + libwebp вместо WKWebView.
#if canImport(SDWebImageSwiftUI)
private struct AnimatedRasterMotionView: View {
    let url: URL
    let shouldPlay: Bool
    let debugLogTag: String?
    let onPlaybackReady: (() -> Void)?
    @State private var didEmitPlaybackReady = false
    /// Флаг с `onSuccess`: без него при включении `shouldPlay` после preload родитель не получит ready, т.к. `onSuccess` уже прошёл.
    @State private var rasterImageDidFinishLoading = false
    /// Реальный `Binding` для `AnimatedImage`: `get`-only binding не триггерит повторный `updateUIView` после async completion SDWebImage (устаревший снимок `isAnimating`).
    @State private var isAnimatingForSD: Bool = false
    /// Текущий URL источника raster-motion: при недоступности R2 переключаемся на PixVerse fallback без смены внешнего API.
    @State private var activeURL: URL
    @State private var didTryPixverseFallback = false

    init(url: URL, shouldPlay: Bool, debugLogTag: String?, onPlaybackReady: (() -> Void)?) {
        self.url = url
        self.shouldPlay = shouldPlay
        self.debugLogTag = debugLogTag
        self.onPlaybackReady = onPlaybackReady
        #if canImport(SDWebImage)
        let initialURL = MediaVideoPlayer.preferredRasterMotionURLForSDWebImageCache(canonical: url)
        _activeURL = State(initialValue: initialURL)
        _didTryPixverseFallback = State(initialValue: initialURL != url)
        #else
        _activeURL = State(initialValue: url)
        _didTryPixverseFallback = State(initialValue: false)
        #endif
    }

    var body: some View {
        AnimatedImage(url: activeURL, isAnimating: $isAnimatingForSD)
            .resizable()
            .playbackRate(1)
            // Явно без индикатора SDWebImage: общий лоадер и постер контролирует `PreviewMediaView`.
            .indicator(nil)
            .onViewUpdate { view, _ in
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.isUserInteractionEnabled = false
                // После загрузки кадра `configureView` не всегда повторно дергает startAnimating — на detail виден «застывший» первый кадр.
                // Не полагаемся на `isAnimating`: иногда true, а кадр не бежит (особенно после network decode).
                if shouldPlay, view.image != nil {
                    view.startAnimating()
                } else {
                    if view.isAnimating {
                        view.stopAnimating()
                    }
                }
                guard shouldPlay, view.image != nil else { return }
                DispatchQueue.main.async {
                    rasterImageDidFinishLoading = true
                    notifyPlaybackReadyIfPlaying()
                }
            }
            // `onViewUpdate` вызывается только из `updateUIView`; после async-load SDWebImage второй раз не приходит — ready раньше ловили только после пересоздания ячейки.
            .onSuccess { _, _, _ in
                DispatchQueue.main.async {
                    rasterImageDidFinishLoading = true
                    notifyPlaybackReadyIfPlaying()
                    nudgeRasterAnimatingAfterLoad()
                }
            }
            .onFailure { _ in
                DispatchQueue.main.async {
                    if tryActivatePixverseFallbackIfNeeded() {
                        return
                    }
                    // Если WebP/GIF не декодировался, завершаем ожидание motion: `PreviewMediaView` вернёт постер вместо вечного тёмного блока/лоадера.
                    rasterImageDidFinishLoading = true
                    notifyPlaybackReadyIfPlaying()
                }
            }
            .scaledToFill()
            .clipped()
            .allowsHitTesting(false)
            .onAppear {
                isAnimatingForSD = shouldPlay
                if shouldPlay { nudgeRasterAnimatingAfterLoad() }
            }
            .onChange(of: url) { _, newURL in
                didEmitPlaybackReady = false
                rasterImageDidFinishLoading = false
                #if canImport(SDWebImage)
                let initialURL = MediaVideoPlayer.preferredRasterMotionURLForSDWebImageCache(canonical: newURL)
                activeURL = initialURL
                didTryPixverseFallback = initialURL != newURL
                #else
                didTryPixverseFallback = false
                activeURL = newURL
                #endif
                isAnimatingForSD = shouldPlay
            }
            .onChange(of: shouldPlay) { _, isPlaying in
                isAnimatingForSD = isPlaying
                if !isPlaying {
                    didEmitPlaybackReady = false
                } else {
                    notifyPlaybackReadyIfPlaying()
                    // Декод мог завершиться на соседнем слайде (`shouldPlay == false`); при активации слоя нужен ещё один проход configure.
                    nudgeRasterAnimatingAfterLoad()
                }
            }
    }

    /// Для регионов с недоступным `*.r2.dev`: один автоматический retry по PixVerse URL, собранному из исходного имени файла.
    private func tryActivatePixverseFallbackIfNeeded() -> Bool {
        guard !didTryPixverseFallback,
              let fallbackURL = PreviewMediaURLFallback.fallbackURL(from: url),
              fallbackURL != activeURL else {
            return false
        }
        didTryPixverseFallback = true
        didEmitPlaybackReady = false
        rasterImageDidFinishLoading = false
        activeURL = fallbackURL
        isAnimatingForSD = shouldPlay
        if shouldPlay {
            nudgeRasterAnimatingAfterLoad()
        }
        return true
    }

    /// Completion SDWebImage дергает `finishUpdateView` со снимком `AnimatedImage`, где `isAnimating` мог быть false (preload); без смены `Binding` SwiftUI не пересобирает representable — анимация не стартует.
    private func nudgeRasterAnimatingAfterLoad() {
        guard shouldPlay else { return }
        DispatchQueue.main.async {
            guard shouldPlay else { return }
            isAnimatingForSD = false
            DispatchQueue.main.async {
                guard shouldPlay else { return }
                isAnimatingForSD = true
            }
        }
    }

    private func notifyPlaybackReadyIfPlaying() {
        guard shouldPlay else { return }
        guard rasterImageDidFinishLoading else { return }
        emitPlaybackReadyOnce()
    }

    private func emitPlaybackReadyOnce() {
        guard !didEmitPlaybackReady else { return }
        didEmitPlaybackReady = true
        let callback = onPlaybackReady
        DispatchQueue.main.async {
            callback?()
        }
    }
}
#else
private struct AnimatedRasterMotionView: View {
    let url: URL
    let shouldPlay: Bool
    let debugLogTag: String?
    let onPlaybackReady: (() -> Void)?
    @State private var didEmitPlaybackReady = false

    var body: some View {
        CachedAsyncImage(url: url, debugLogTag: debugLogTag) { image in
            image
                .resizable()
                .scaledToFill()
                .onAppear {
                    guard shouldPlay, !didEmitPlaybackReady else { return }
                    didEmitPlaybackReady = true
                    let callback = onPlaybackReady
                    DispatchQueue.main.async {
                        callback?()
                    }
                }
        } placeholder: {
            Color.clear
        }
        .onChange(of: url) { _, _ in
            didEmitPlaybackReady = false
        }
        .onChange(of: shouldPlay) { _, isPlaying in
            if !isPlaying {
                didEmitPlaybackReady = false
            }
        }
    }
}
#endif

// Debug «Clear Cache»: `ImageDownloader` + диск MP4 превью + SDWebImage/WebP cache; не трогает `GalleryThumbnailCache` и локальные файлы галереи.
enum NonGalleryMediaCacheCleaner {
    /// Оценка размера на диске до `clearAll()`: каталоги `ImageCache` + `EffectPreviewVideos`. SDWebImage хранит WebP в своём cache namespace и очищается отдельно.
    static func estimatedDiskBytesBeforeClear() -> Int64 {
        ImageDownloader.shared.estimatedDiskCacheBytes() + EffectPreviewVideoDiskCache.estimatedDiskUsageBytes()
    }

    static func clearAll() async {
        await MainActor.run {
            ImageDownloader.shared.clearCache()
            AppState.shared.resetOnboardingHomeWarmupAfterCacheClear()
        }
        await EffectPreviewVideoDiskCache.shared.clearAll()
        await EffectsMediaOrchestrator.shared.resetCatalogWarmupStateAfterCacheClear()
        #if canImport(SDWebImage)
        await clearSDWebImagePreviewCache()
        #endif
        await MainActor.run {
            NotificationCenter.default.post(name: .nonGalleryPreviewCacheCleared, object: nil)
        }
    }

    #if canImport(SDWebImage)
    /// Animated WebP теперь кэшируется SDWebImage; debug clear должен убирать и memory, и disk cache, иначе старый WebP может оставаться после замены URL/ресурса.
    private static func clearSDWebImagePreviewCache() async {
        SDImageCache.shared.clearMemory()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SDImageCache.shared.clearDisk {
                continuation.resume()
            }
        }
    }
    #endif
}
