import SwiftUI
import AVFoundation
import CryptoKit
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct MediaVideoPlayer: View {
    let mediaURL: String
    let shouldPlay: Bool
    /// Бесшовный loop через `AVPlayerLooper` (превью эффектов и видео в галерее).
    let loopsVideo: Bool
    /// Логи этапов превью эффектов (`"[effects-preview]"`); для галереи — `nil`.
    let debugLogTag: String?
    /// Превью эффектов всегда без звука; звук оставляем только в полноэкранном Media Detail.
    let isMuted: Bool
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
        loopsVideo: Bool = true,
        debugLogTag: String? = nil,
        isMuted: Bool = true,
        usesDiskCache: Bool = true,
        expandsVideoToIgnoreSafeArea: Bool = false,
        onPlaybackReady: (() -> Void)? = nil,
        onPlaybackLoop: (() -> Void)? = nil
    ) {
        self.mediaURL = mediaURL
        self.shouldPlay = shouldPlay
        self.loopsVideo = loopsVideo
        self.debugLogTag = debugLogTag
        self.isMuted = isMuted
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

    var body: some View {
        Group {
            if isRasterMotionPreviewURL {
                if shouldPlay, let u = url {
                    AnimatedRasterMotionView(url: u, debugLogTag: debugLogTag, onPlaybackReady: onPlaybackReady)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            } else {
                videoPlayerStack
            }
        }
        .onAppear {
            let kind = isRasterMotionPreviewURL ? "animated-raster-wkwebview" : "avplayer-video"
            logVideo("appear mediaKind=\(kind) url=\(mediaURL.prefix(120))")
        }
    }

    private var videoPlayerStack: some View {
        ZStack {
            if expandsVideoToIgnoreSafeArea {
                AppTheme.Colors.background
            }

            if let player {
                if expandsVideoToIgnoreSafeArea {
                    VideoPlayer(player: player)
                        .opacity(readinessObserver.isReadyForDisplay ? 1 : 0)
                        .ignoresSafeArea()
                } else {
                    AVPlayerLayerView(
                        player: player,
                        isReadyForDisplay: $readinessObserver.isReadyForDisplay,
                        debugLogTag: debugLogTag
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(readinessObserver.isReadyForDisplay ? 1 : 0)
                }
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
                playbackReadyNotified = false
            }
        }
        .onDisappear {
            logVideo("onDisappear tearDownPlayer()")
            tearDownPlayer()
        }
        .onChange(of: readinessObserver.isReadyForDisplay) { _, ready in
            if ready { notifyPlaybackReadyIfNeeded() }
        }
        .onAppear {
            if shouldPlay, readinessObserver.isReadyForDisplay {
                notifyPlaybackReadyIfNeeded()
            }
        }
    }

    private func logVideo(_ message: String) {
        if let tag = debugLogTag {
            print("\(tag) MediaVideoPlayer \(message)")
        }
    }

    @MainActor
    private func notifyPlaybackReadyIfNeeded() {
        guard shouldPlay, !playbackReadyNotified else { return }
        playbackReadyNotified = true
        onPlaybackReady?()
    }

    @MainActor
    private func tearDownPlayer() {
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
            let queue = AVQueuePlayer()
            queue.isMuted = isMuted
            playerLooper = AVPlayerLooper(player: queue, templateItem: template)
            player = queue
            if expandsVideoToIgnoreSafeArea {
                observeReadiness(of: queue)
            }
            logVideo("buildPlayer AVQueuePlayer + AVPlayerLooper")
        } else {
            let next = AVPlayer(url: playbackURL)
            next.isMuted = isMuted
            player = next
            if expandsVideoToIgnoreSafeArea {
                observeReadiness(of: next)
            }
            if let item = next.currentItem {
                plainLoopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak next, onPlaybackLoop] _ in
                    onPlaybackLoop?()
                    next?.seek(to: .zero)
                    next?.play()
                }
            }
            logVideo("buildPlayer plain AVPlayer + end observer (fallback loop)")
        }
        applyPlayback(shouldPlay)
        if shouldPlay, readinessObserver.isReadyForDisplay {
            notifyPlaybackReadyIfNeeded()
        }
    }

    @MainActor
    private func applyPlayback(_ play: Bool) {
        guard let player else { return }
        player.isMuted = isMuted
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

/// Дисковый кэш remote preview-video: AVPlayer сам не использует наш image cache, поэтому сохраняем ролики в Caches и играем локальный файл.
actor EffectPreviewVideoDiskCache {
    static let shared = EffectPreviewVideoDiskCache()

    private var inFlight: [URL: Task<URL, Error>] = [:]

    private static let cacheDirectoryName = "EffectPreviewVideos"

    /// Debug / «Очистить кэш»: снимаем in-flight загрузки и удаляем каталог превью-видео (MP4 и т.д.); не трогает файлы галереи и `GalleryThumbnailCache`.
    func clearAll() {
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    }

    fileprivate func playbackURL(for remoteURL: URL) async -> EffectPreviewVideoDiskCacheResult {
        let fileURL = cacheFileURL(for: remoteURL)

        if let bytes = fileSize(at: fileURL), bytes > 0 {
            return .hit(fileURL, bytes: bytes)
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
            return .miss(savedURL, bytes: fileSize(at: savedURL) ?? 0)
        } catch {
            inFlight[remoteURL] = nil
            return .failed(error)
        }
    }

    private func cacheFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        return Self.cacheDirectory.appendingPathComponent("\(digest).\(ext)", isDirectory: false)
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

    /// Сумма байт файлов в каталоге превью (до `clearAll()`).
    nonisolated static func estimatedDiskUsageBytes() -> Int64 {
        ImageDownloader.totalRegularFileBytes(in: cacheRootURLForDiagnostics())
    }

    private static func download(remoteURL: URL, to destinationURL: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
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
                        print("\(debugLogTag) MediaVideoPlayer layer.readyForDisplay=\(ready)")
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

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

// Animated WebP/GIF через `UIImage` превращается в первый статичный кадр. WKWebView рендерит такие превью как обычный `<img>` и сохраняет анимацию.
#if canImport(WebKit)
private struct AnimatedRasterMotionView: UIViewRepresentable {
    let url: URL
    let debugLogTag: String?
    let onPlaybackReady: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.clipsToBounds = true
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.clipsToBounds = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        context.coordinator.bind(webView: webView, debugLogTag: debugLogTag)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let urlString = url.absoluteString
        context.coordinator.currentURLString = urlString
        context.coordinator.debugLogTag = debugLogTag
        context.coordinator.onPlaybackReady = onPlaybackReady
        guard context.coordinator.loadedURLString != urlString else { return }

        context.coordinator.loadedURLString = urlString
        context.coordinator.prepareNewRasterLoad()
        webView.isHidden = true
        if let debugLogTag {
            print("\(debugLogTag) MediaVideoPlayer animatedRaster load bounds=\(String(format: "%.1f", webView.bounds.width))x\(String(format: "%.1f", webView.bounds.height)) url=\(urlString.prefix(120))")
        }

        webView.loadHTMLString(Self.html(for: urlString), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    fileprivate static func html(for urlString: String) -> String {
        let escaped = urlString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: transparent;
            }
            img {
              position: fixed;
              inset: 0;
              width: 100%;
              height: 100%;
              object-fit: cover;
              display: block;
              visibility: hidden;
            }
            body[data-raster-state="loaded"] img {
              visibility: visible;
            }
          </style>
          <script>
            window.addEventListener('DOMContentLoaded', function() {
              var img = document.querySelector('img');
              if (!img) { return; }
              img.onload = function() {
                document.body.dataset.rasterState = 'loaded';
              };
              img.onerror = function() {
                document.body.dataset.rasterState = 'broken';
              };
              if (img.complete && img.naturalWidth > 0 && img.naturalHeight > 0) {
                document.body.dataset.rasterState = 'loaded';
              }
            });
          </script>
        </head>
        <body>
          <img src="\(escaped)" alt="">
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Повторные `loadHTMLString` при сбое сети/кэша WebKit; после лимита скрываем `WKWebView`, чтобы был виден постер под слоем motion.
        private static let maxRasterRetries: Int = 3

        var loadedURLString: String?
        var currentURLString: String?
        var debugLogTag: String?
        var onPlaybackReady: (() -> Void)?
        private var didEmitPlaybackReady = false
        private weak var webView: WKWebView?
        private var cacheClearObserver: NSObjectProtocol?
        private var rasterRetryCounter: Int = 0
        private var verifyRasterWorkItem: DispatchWorkItem?
        private var retryRasterWorkItem: DispatchWorkItem?

        func cancelAllRasterDelayedWork() {
            verifyRasterWorkItem?.cancel()
            verifyRasterWorkItem = nil
            retryRasterWorkItem?.cancel()
            retryRasterWorkItem = nil
        }

        /// Сброс ретраев при новом URL из SwiftUI: `rasterRetryCounter` остаётся private у координатора.
        func prepareNewRasterLoad() {
            cancelAllRasterDelayedWork()
            rasterRetryCounter = 0
            didEmitPlaybackReady = false
        }

        private func emitPlaybackReadyOnce() {
            guard !didEmitPlaybackReady else { return }
            didEmitPlaybackReady = true
            onPlaybackReady?()
        }

        func bind(webView: WKWebView, debugLogTag: String?) {
            self.webView = webView
            self.debugLogTag = debugLogTag
            webView.navigationDelegate = self
            guard cacheClearObserver == nil else { return }
            // После `WKWebsiteDataStore.removeData` in-memory документ может держать старый кадр — перезагружаем тот же `<img>` URL.
            cacheClearObserver = NotificationCenter.default.addObserver(
                forName: .nonGalleryPreviewCacheCleared,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.loadedURLString = nil
                guard let webView = self.webView, let urlString = self.currentURLString else { return }
                if let tag = self.debugLogTag {
                    print("\(tag) MediaVideoPlayer animatedRaster reload after cache clear url=\(urlString.prefix(96))")
                }
                self.prepareNewRasterLoad()
                webView.isHidden = true
                webView.loadHTMLString(AnimatedRasterMotionView.html(for: urlString), baseURL: nil)
                self.loadedURLString = urlString
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if let tag = debugLogTag {
                print("\(tag) MediaVideoPlayer animatedRaster navigation START bounds=\(String(format: "%.1f", webView.bounds.width))x\(String(format: "%.1f", webView.bounds.height)) url=\((currentURLString ?? "?").prefix(120))")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let script = """
            (function() {
              var img = document.querySelector('img');
              if (!img) { return 'img=nil'; }
              return [
                'complete=' + img.complete,
                'natural=' + img.naturalWidth + 'x' + img.naturalHeight,
                'client=' + img.clientWidth + 'x' + img.clientHeight,
                'body=' + document.body.clientWidth + 'x' + document.body.clientHeight,
                'dpr=' + window.devicePixelRatio
              ].join(' ');
            })();
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, error in
                guard let self, let webView, let tag = self.debugLogTag else { return }
                if let error {
                    print("\(tag) MediaVideoPlayer animatedRaster navigation FINISH metricsError=\(error.localizedDescription) url=\((self.currentURLString ?? "?").prefix(120))")
                } else {
                    print("\(tag) MediaVideoPlayer animatedRaster navigation FINISH bounds=\(String(format: "%.1f", webView.bounds.width))x\(String(format: "%.1f", webView.bounds.height)) metrics=\(result ?? "nil") url=\((self.currentURLString ?? "?").prefix(120))")
                }
            }

            // Ресурс `<img>` может догрузиться после main-frame `didFinish`; проверяем natural size и при «битом» кадре даём ретраи вместо иконки вопроса поверх постера.
            verifyRasterWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.verifyRasterImageLoaded(in: webView)
            }
            verifyRasterWorkItem = work
            // WebP в `<img>` иногда получает natural size чуть позже main-frame `didFinish`; не ретраим слишком рано.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if let tag = debugLogTag {
                print("\(tag) MediaVideoPlayer animatedRaster navigation FAIL error=\(error.localizedDescription) url=\((currentURLString ?? "?").prefix(120))")
            }
            verifyRasterWorkItem?.cancel()
            verifyRasterWorkItem = nil
            scheduleRasterRetry(webView: webView, reason: "didFail")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let tag = debugLogTag {
                print("\(tag) MediaVideoPlayer animatedRaster navigation PROVISIONAL_FAIL error=\(error.localizedDescription) url=\((currentURLString ?? "?").prefix(120))")
            }
            verifyRasterWorkItem?.cancel()
            verifyRasterWorkItem = nil
            scheduleRasterRetry(webView: webView, reason: "provisionalFail")
        }

        private func verifyRasterImageLoaded(in webView: WKWebView) {
            let script = """
            (function() {
              var img = document.querySelector('img');
              if (!img) return 'noimg';
              var w = img.naturalWidth, h = img.naturalHeight;
              if (w > 0 && h > 0) {
                document.body.dataset.rasterState = 'loaded';
                return 'ok';
              }
              return 'broken';
            })();
            """
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                let status = (result as? String) ?? ""
                if status == "ok" {
                    self.rasterRetryCounter = 0
                    webView.isHidden = false
                    self.emitPlaybackReadyOnce()
                    return
                }
                self.scheduleRasterRetry(webView: webView, reason: "verify:\(status)")
            }
        }

        private func scheduleRasterRetry(webView: WKWebView, reason: String) {
            retryRasterWorkItem?.cancel()
            rasterRetryCounter += 1
            guard rasterRetryCounter <= Self.maxRasterRetries else {
                webView.isHidden = true
                webView.stopLoading()
                if let tag = debugLogTag, let u = currentURLString {
                    print("\(tag) MediaVideoPlayer animatedRaster GIVE_UP hideWKWebView retries=\(Self.maxRasterRetries) reason=\(reason) url=\(u.prefix(120))")
                }
                emitPlaybackReadyOnce()
                return
            }
            if let tag = debugLogTag, let u = currentURLString {
                print("\(tag) MediaVideoPlayer animatedRaster RETRY \(rasterRetryCounter)/\(Self.maxRasterRetries) reason=\(reason) url=\(u.prefix(120))")
            }
            let delay: TimeInterval = 0.35 + 0.2 * Double(rasterRetryCounter)
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, let urlString = self.currentURLString else { return }
                webView.isHidden = true
                webView.loadHTMLString(AnimatedRasterMotionView.html(for: urlString), baseURL: nil)
            }
            retryRasterWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        deinit {
            cancelAllRasterDelayedWork()
            if let cacheClearObserver {
                NotificationCenter.default.removeObserver(cacheClearObserver)
            }
        }
    }
}
#else
private struct AnimatedRasterMotionView: View {
    let url: URL
    let debugLogTag: String?
    let onPlaybackReady: (() -> Void)?
    @State private var didEmitPlaybackReady = false

    var body: some View {
        CachedAsyncImage(url: url, debugLogTag: debugLogTag) { image in
            image
                .resizable()
                .scaledToFill()
                .onAppear {
                    guard !didEmitPlaybackReady else { return }
                    didEmitPlaybackReady = true
                    onPlaybackReady?()
                }
        } placeholder: {
            Color.clear
        }
        .onChange(of: url) { _, _ in
            didEmitPlaybackReady = false
        }
    }
}
#endif

// Debug «Clear Cache»: `ImageDownloader` + диск MP4 превью + данные WebKit (кэш WKWebView для animated WebP); не трогает `GalleryThumbnailCache` и локальные файлы галереи.
enum NonGalleryMediaCacheCleaner {
    /// Оценка размера на диске до `clearAll()`: каталоги `ImageCache` + `EffectPreviewVideos`. Данные WebKit без публичного размера записей не суммируем.
    static func estimatedDiskBytesBeforeClear() -> Int64 {
        ImageDownloader.shared.estimatedDiskCacheBytes() + EffectPreviewVideoDiskCache.estimatedDiskUsageBytes()
    }

    static func clearAll() async {
        await MainActor.run {
            ImageDownloader.shared.clearCache()
        }
        await EffectPreviewVideoDiskCache.shared.clearAll()
        #if canImport(WebKit)
        await clearWebKitPreviewWebsiteData()
        #endif
        await MainActor.run {
            NotificationCenter.default.post(name: .nonGalleryPreviewCacheCleared, object: nil)
        }
    }

    #if canImport(WebKit)
    /// Animated WebP в карточках идёт через `WKWebView`; без сброса `WKWebsiteDataStore` картинки остаются в дисковом кэше WebKit после «Очистить кэш».
    private static func clearWebKitPreviewWebsiteData() async {
        // `WKWebsiteDataStore` — `@MainActor`; цепочка fetch + remove по записям — актуальный API без предупреждения про completion-handler `removeData(ofTypes:modifiedSince:)`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                let types = WKWebsiteDataStore.allWebsiteDataTypes()
                print("[effects-preview] NonGalleryMediaCacheCleaner WebKit fetch+remove START types=\(Array(types).sorted())")
                WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
                    WKWebsiteDataStore.default().removeData(ofTypes: types, for: records) {
                        print("[effects-preview] NonGalleryMediaCacheCleaner WebKit fetch+remove FINISH records=\(records.count)")
                        continuation.resume()
                    }
                }
            }
        }
    }
    #endif
}
