import SwiftUI

// В generic-struct нельзя держать `static let` storage; число попыток — на уровне файла.
private enum CachedAsyncImagePolicy {
    static let maxDownloadAttempts: Int = 3

    static func isRenderableCachedImage(_ image: UIImage) -> Bool {
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        return w >= 2 && h >= 2 && image.cgImage != nil
    }
}

/// Кэшированная версия AsyncImage для быстрого отображения изображений
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    /// Если задан (например `"[effects-preview]"`), пишет в консоль этапы загрузки и кэша.
    let debugLogTag: String?

    @State private var image: UIImage?
    @State private var cacheVersion = 0
    /// Совпадение с активной `.task`-сессией: отбрасываем completion после смены URL/сброса кэша, не блокируем повторный вход через `isLoading`.
    @State private var activeLoadKey: String = ""
    /// Откуда взято текущее `image`: при смене URL в той же ячейке LazyVStack сбрасываем bitmap, иначе мелькает превью «чужого» эффекта.
    @State private var imageSourceURLString: String?

    init(
        url: URL?,
        debugLogTag: String? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.debugLogTag = debugLogTag
        self.content = content
        self.placeholder = placeholder
    }

    private var loadTaskIdentity: String {
        "\(cacheVersion)|\(url?.absoluteString ?? "")"
    }

    var body: some View {
        Group {
            if let image = image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .id(cacheVersion)
        .task(id: loadTaskIdentity) {
            await runImageLoad(loadKey: loadTaskIdentity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            log("notification imageCacheCleared → clearImage()")
            clearImage()
        }
    }

    private var urlDesc: String {
        guard let url else { return "nil" }
        let s = url.absoluteString
        if s.count > 120 { return String(s.prefix(120)) + "…(\(s.count) chars)" }
        return s
    }

    private func log(_ message: String) {
        if let tag = debugLogTag {
            // print("\(tag) CachedAsyncImage \(message)")
            _ = tag
            _ = message
        }
    }

    private func clearImage() {
        image = nil
        imageSourceURLString = nil
        cacheVersion += 1
    }

    /// Загрузка привязана к `task(id:)`: отмена при смене URL/версии кэша без «залипшего» isLoading; completion игнорируется, если сессия устарела.
    @MainActor
    private func runImageLoad(loadKey: String) async {
        activeLoadKey = loadKey
        log("runImageLoad begin key=\(loadKey.prefix(96))")

        guard let url = url else {
            log("runImageLoad abort: url=nil")
            image = nil
            imageSourceURLString = nil
            return
        }

        let urlString = url.absoluteString
        if imageSourceURLString != urlString {
            image = nil
            imageSourceURLString = nil
        }

        if url.isFileURL {
            if let localImage = UIImage(contentsOfFile: url.path) {
                log("runImageLoad OK local file path=\(url.path)")
                image = localImage
                imageSourceURLString = urlString
            } else {
                let exists = FileManager.default.fileExists(atPath: url.path)
                print("❌ [CachedAsyncImage] Failed to load local file: \(url.path). Exists=\(exists)")
            }
            return
        }

        guard urlString.hasPrefix("http") else {
            log("runImageLoad abort: not http(s) urlString=\(urlString.prefix(80))")
            return
        }

        if let cachedImage = ImageDownloader.shared.getCachedImage(from: urlString) {
            if CachedAsyncImagePolicy.isRenderableCachedImage(cachedImage) {
                log("runImageLoad HIT getCachedImage(from:) bytes~=\(cachedImage.pngData()?.count ?? -1)")
                guard activeLoadKey == loadKey else { return }
                image = cachedImage
                imageSourceURLString = urlString
                return
            }
            log("runImageLoad HIT but bitmap invalid → invalidateCachedRemoteImage")
            ImageDownloader.shared.invalidateCachedRemoteImage(for: urlString)
        }

        for attemptIndex in 0..<CachedAsyncImagePolicy.maxDownloadAttempts {
            guard !Task.isCancelled, activeLoadKey == loadKey else {
                log("runImageLoad cancelled before attempt \(attemptIndex + 1)")
                return
            }
            log("runImageLoad MISS → downloadImage(from:) attempt \(attemptIndex + 1)/\(CachedAsyncImagePolicy.maxDownloadAttempts)")
            image = nil
            imageSourceURLString = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ImageDownloader.shared.downloadImage(from: urlString, effectPreviewLogTag: debugLogTag) { result in
                    Task { @MainActor in
                        defer { continuation.resume() }
                        guard self.activeLoadKey == loadKey else {
                            self.log("download completion IGNORED (stale session)")
                            return
                        }
                        switch result {
                        case .success(let path):
                            self.log("downloadImage completion success path=\(path.suffix(80))")
                            if let fromMem = ImageDownloader.shared.getCachedImage(from: urlString),
                               CachedAsyncImagePolicy.isRenderableCachedImage(fromMem) {
                                self.image = fromMem
                                self.imageSourceURLString = urlString
                                self.log("after download: image from getCachedImage(from:) OK")
                            } else if let diskImg = UIImage(contentsOfFile: path),
                                      CachedAsyncImagePolicy.isRenderableCachedImage(diskImg) {
                                self.image = diskImg
                                self.imageSourceURLString = urlString
                                self.log("after download: UIImage(contentsOfFile:) OK (fallback)")
                            } else {
                                self.log("after download: FAILURE could not decode UIImage from path → invalidate")
                                ImageDownloader.shared.invalidateCachedRemoteImage(for: urlString)
                            }
                        case .failure(let error):
                            self.log("downloadImage completion failure error=\(error)")
                            print("❌ [CachedAsyncImage] Failed to load '\(urlString)': \(error)")
                        }
                    }
                }
            }
            guard activeLoadKey == loadKey else { return }
            if image != nil { return }
            if attemptIndex < CachedAsyncImagePolicy.maxDownloadAttempts - 1 {
                let backoff = 300_000_000 + UInt64(attemptIndex) * 200_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }
}

extension CachedAsyncImage {
    init(url: URL?) where Content == AnyView, Placeholder == AnyView {
        self.init(
            url: url,
            debugLogTag: nil,
            content: { image in
                AnyView(
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
            },
            placeholder: {
                AnyView(
                    Rectangle()
                        .fill(Color(red: 0.74, green: 0.74, blue: 0.74))
                )
            }
        )
    }
}
