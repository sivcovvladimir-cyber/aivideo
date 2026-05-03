import CryptoKit
import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    static let imageCacheCleared = Notification.Name("imageCacheCleared")
    /// После debug «Очистить кэш»: сброшены ImageCache, диск превью-видео эффектов и данные WebKit (`WKWebsiteDataStore`); слушатели могут перезапросить превью.
    static let nonGalleryPreviewCacheCleared = Notification.Name("nonGalleryPreviewCacheCleared")
}

/// Протокол для скачивания и кэширования изображений
public protocol ImageDownloaderProtocol {
    /// Скачивает изображение по URL и сохраняет локально (`effectPreviewLogTag` — опциональные логи превью эффектов).
    func downloadImage(from url: String, effectPreviewLogTag: String?, completion: @escaping (Result<String, NetworkError>) -> Void)
    /// Сетка Last Results: ужатый превью (меньше трафика и памяти, чем полный оригинал).
    func loadLastResultsThumbnail(from urlString: String, completion: @escaping (UIImage?) -> Void)
    /// Проверяет, есть ли уже закэшированный превью-файл Last Results (RAM/диск) для URL.
    func hasCachedLastResultsThumbnail(for urlString: String) -> Bool
    /// Уже загруженное превью сетки Last Results — тем же ключом, что `loadLastResultsThumbnail` (для мгновенного показа в MediaDetail).
    func getCachedLastResultsThumbnail(for urlString: String) -> UIImage?
    /// Снимает урезанное превью Last Results и полный файл по тому же URL (общий кэш), когда строка выпала из 48h-окна.
    func removeLastResultsThumbnail(for urlString: String)
    /// Предзагружает изображение в кэш
    func preloadImage(from url: String)
    /// Получает изображение из кэша
    func getCachedImage(from url: String) -> UIImage?
    /// Снимает RAM+диск по одному remote URL (битый файл после скачивания / повторная попытка превью).
    func invalidateCachedRemoteImage(for url: String)
    /// Очищает кэш
    func clearCache()
}

/// Сервис для скачивания и кэширования изображений
public class ImageDownloader: ImageDownloaderProtocol {
    // MARK: - Singleton
    public static let shared = ImageDownloader()
    
    // Статистика
    private var successfulDownloads = 0
    private var successfulCacheHits = 0
    private var failedDownloads = 0
    
    private init() {
        createCacheDirectory()
    }

    // MARK: - Properties
    private let memoryCache = NSCache<NSString, UIImage>()
    private let session = URLSession.shared
    private let fileManager = FileManager.default
    
    private var cacheDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("ImageCache")
    }
    
    // MARK: - Setup
    private func createCacheDirectory() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        
        // Настройка memory cache
        memoryCache.countLimit = 100 // Максимум 100 изображений в памяти
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // Максимум 50MB в памяти
    }

    // MARK: - Last Results (сетка): даунсэмпл + JPEG

    private static let lastResultsThumbMaxPixel: CGFloat = 512
    private static let lastResultsThumbJPEGQuality: CGFloat = 0.7

    /// Стабильный ключ кэша для урезанного превью по URL (отдельно от полного кэша галереи).
    private func lastResultsThumbnailCacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    public func loadLastResultsThumbnail(from urlString: String, completion: @escaping (UIImage?) -> Void) {
        guard urlString.hasPrefix("http"), URL(string: urlString) != nil else {
            completion(nil)
            return
        }

        let cacheKey = "lr_thumb_\(lastResultsThumbnailCacheKey(for: urlString))"
        let nsKey = NSString(string: cacheKey)
        let thumbPath = cacheDirectory.appendingPathComponent("\(cacheKey).jpg")

        if let mem = memoryCache.object(forKey: nsKey) {
            completion(mem)
            return
        }

        if fileManager.fileExists(atPath: thumbPath.path),
           let img = UIImage(contentsOfFile: thumbPath.path) {
            memoryCache.setObject(img, forKey: nsKey)
            completion(img)
            return
        }

        // Один источник данных с MediaDetail: сначала общий полный файл на диске (downloadImage кладёт туда же).
        let fullCachedPath = diskCachePath(for: urlString)
        if fileManager.fileExists(atPath: fullCachedPath.path),
           let data = try? Data(contentsOf: fullCachedPath), !data.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.buildAndCacheLastResultsThumb(from: data, thumbPath: thumbPath, nsKey: nsKey, completion: completion)
            }
            return
        }

        // Одно скачивание по сети — через downloadImage; затем миниатюра с тех же байт на диске.
        downloadImage(from: urlString, effectPreviewLogTag: nil) { [weak self] result in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            switch result {
            case .success(let path):
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    self.buildAndCacheLastResultsThumb(from: data, thumbPath: thumbPath, nsKey: nsKey, completion: completion)
                }
            case .failure:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Строит JPEG-миниатюру Last Results из уже загруженных байт (полный кэш) и кладёт в lr_thumb-память/диск.
    private func buildAndCacheLastResultsThumb(from data: Data, thumbPath: URL, nsKey: NSString, completion: @escaping (UIImage?) -> Void) {
        guard let down = Self.downsampleImageData(data, maxPixelSize: Self.lastResultsThumbMaxPixel) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let jpeg = down.jpegData(compressionQuality: Self.lastResultsThumbJPEGQuality)
        guard let jpeg, let finalImage = UIImage(data: jpeg) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        try? jpeg.write(to: thumbPath)
        memoryCache.setObject(finalImage, forKey: nsKey)
        DispatchQueue.main.async { completion(finalImage) }
    }

    public func hasCachedLastResultsThumbnail(for urlString: String) -> Bool {
        guard urlString.hasPrefix("http") else { return false }
        let cacheKey = "lr_thumb_\(lastResultsThumbnailCacheKey(for: urlString))"
        let nsKey = NSString(string: cacheKey)
        if memoryCache.object(forKey: nsKey) != nil { return true }
        let thumbPath = cacheDirectory.appendingPathComponent("\(cacheKey).jpg")
        if fileManager.fileExists(atPath: thumbPath.path) { return true }
        let fullPath = diskCachePath(for: urlString)
        return fileManager.fileExists(atPath: fullPath.path)
    }

    public func getCachedLastResultsThumbnail(for urlString: String) -> UIImage? {
        guard urlString.hasPrefix("http") else { return nil }
        let cacheKey = "lr_thumb_\(lastResultsThumbnailCacheKey(for: urlString))"
        let nsKey = NSString(string: cacheKey)
        if let mem = memoryCache.object(forKey: nsKey) { return mem }
        let thumbPath = cacheDirectory.appendingPathComponent("\(cacheKey).jpg")
        if fileManager.fileExists(atPath: thumbPath.path),
           let img = UIImage(contentsOfFile: thumbPath.path) {
            memoryCache.setObject(img, forKey: nsKey)
            return img
        }
        return nil
    }

    public func removeLastResultsThumbnail(for urlString: String) {
        guard urlString.hasPrefix("http") else { return }
        let cacheKey = "lr_thumb_\(lastResultsThumbnailCacheKey(for: urlString))"
        let lrKey = NSString(string: cacheKey)
        memoryCache.removeObject(forKey: lrKey)
        let thumbPath = cacheDirectory.appendingPathComponent("\(cacheKey).jpg")
        if fileManager.fileExists(atPath: thumbPath.path) {
            try? fileManager.removeItem(at: thumbPath)
        }
        let urlKey = NSString(string: urlString)
        memoryCache.removeObject(forKey: urlKey)
        let fullPath = diskCachePath(for: urlString)
        if fileManager.fileExists(atPath: fullPath.path) {
            try? fileManager.removeItem(at: fullPath)
        }
    }

    /// Даунсэмпл через Image I/O — не держим полный кадр в памяти как UIImage(data:).
    private static func downsampleImageData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let down: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, down as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Public Methods
    public func downloadImage(from url: String, effectPreviewLogTag: String? = nil, completion: @escaping (Result<String, NetworkError>) -> Void) {
        func elog(_ message: String) {
            if let tag = effectPreviewLogTag {
                print("\(tag) ImageDownloader \(message)")
            }
        }

        elog("downloadImage begin url.len=\(url.count) prefix=\(url.prefix(96))")

        // Проверяем если это локальный файл
        if !url.hasPrefix("http") {
            // Для локальных файлов проверяем существование и валидность
            if fileManager.fileExists(atPath: url) {
                // Проверяем, что файл можно прочитать как изображение
                if let _ = UIImage(contentsOfFile: url) {
                    completion(.success(url))
                } else {
                    print("⚠️ [ImageDownloader] Corrupted local file: \(url)")
                    completion(.failure(.invalidResponse))
                }
            } else {
                print("⚠️ [ImageDownloader] Local file not found: \(url)")
                completion(.failure(.invalidResponse))
            }
            return
        }
        
        // Проверяем кэш на диске для remote изображений
        let cachedPath = diskCachePath(for: url)
        if fileManager.fileExists(atPath: cachedPath.path) {
            elog("disk file EXISTS path.suffix=\(String(cachedPath.path.suffix(64)))")
            // Проверяем, что кэшированный файл можно прочитать как изображение
            if let diskImage = UIImage(contentsOfFile: cachedPath.path) {
                elog("disk UIImage OK size=\(diskImage.size); warming memoryCache key=fullURLString")
                // Тот же ключ, что у `getCachedImage(from:)` — иначе после холодного старта RAM пустой и превью не подхватывается с диска.
                let memKey = NSString(string: url)
                memoryCache.setObject(diskImage, forKey: memKey)
                completion(.success(cachedPath.path))
            } else {
                elog("disk file UNREADABLE as UIImage → remove and re-fetch")
                print("⚠️ [ImageDownloader] Corrupted cached file, removing: \(cachedPath.path)")
                try? fileManager.removeItem(atPath: cachedPath.path)
                // Продолжаем с загрузкой
                downloadAndCache(url: url, effectPreviewLogTag: effectPreviewLogTag, completion: completion)
            }
            return
        }

        elog("no disk file → downloadAndCache network")
        // Скачиваем изображение
        downloadAndCache(url: url, effectPreviewLogTag: effectPreviewLogTag, completion: completion)
    }
    
    public func preloadImage(from url: String) {
        // Пропускаем если это локальный файл
        if !url.hasPrefix("http") {
            return
        }
        
        let key = NSString(string: url)
        
        // Быстрая проверка memory cache
        if memoryCache.object(forKey: key) != nil {
            return
        }
        
        // Проверяем disk cache в фоне
        DispatchQueue.global(qos: .background).async {
            let cachedPath = self.diskCachePath(for: url)
            if self.fileManager.fileExists(atPath: cachedPath.path),
               let image = UIImage(contentsOfFile: cachedPath.path) {
                DispatchQueue.main.async {
                    self.memoryCache.setObject(image, forKey: key)
                    self.successfulCacheHits += 1
                }
                return
            }
            
            // Скачиваем если нет в кэше (без блокировки)
            self.downloadAndCache(url: url, effectPreviewLogTag: nil) { result in
                switch result {
                case .success(let localPath):
                    // Загружаем изображение в memory cache
                    if let image = UIImage(contentsOfFile: localPath) {
                        DispatchQueue.main.async {
                            self.memoryCache.setObject(image, forKey: key)
                        }
                    }
                case .failure(let error):
                    print("⚠️ [ImageDownloader] Preload failed for '\(url)': \(error)")
                }
            }
        }
    }
    
    public func getCachedImage(from url: String) -> UIImage? {
        // Для локальных файлов возвращаем nil - пусть CachedAsyncImage обрабатывает напрямую
        if !url.hasPrefix("http") {
            return nil
        }
        
        let key = NSString(string: url)
        
        // Проверяем memory cache
        if let cachedImage = memoryCache.object(forKey: key) {
            successfulCacheHits += 1
            return cachedImage
        }
        
        // Проверяем disk cache синхронно для быстрого доступа
        let cachedPath = diskCachePath(for: url)
        if fileManager.fileExists(atPath: cachedPath.path),
           let image = UIImage(contentsOfFile: cachedPath.path) {
            // Добавляем в memory cache
            memoryCache.setObject(image, forKey: key)
            successfulCacheHits += 1
            return image
        }
        
        return nil
    }

    public func invalidateCachedRemoteImage(for url: String) {
        guard url.hasPrefix("http") else { return }
        memoryCache.removeObject(forKey: NSString(string: url))
        let cachedPath = diskCachePath(for: url)
        if fileManager.fileExists(atPath: cachedPath.path) {
            try? fileManager.removeItem(at: cachedPath)
        }
    }
    
    public func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectory)
        createCacheDirectory()
        
        // Отправляем уведомление об очистке кэша
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .imageCacheCleared, object: nil)
        }
    }

    /// Размер файлов в `Documents/ImageCache` на диске (то, что снимает `clearCache()`; RAM не учитывается).
    public func estimatedDiskCacheBytes() -> Int64 {
        Self.totalRegularFileBytes(in: cacheDirectory)
    }

    /// Общий размер обычных файлов в каталоге (рекурсивно); для оценки кэша в debug-настройках.
    static func totalRegularFileBytes(in directoryURL: URL) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  rv.isRegularFile == true,
                  let size = rv.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
    
    /// Кэширует изображение по ключу
    public func cacheImage(_ image: UIImage, forKey key: String) {
        let nsKey = NSString(string: key)
        
        // Добавляем в memory cache для мгновенного доступа
        memoryCache.setObject(image, forKey: nsKey)
        
        // Также сохраняем на диск
        let imageData = image.jpegData(compressionQuality: 0.8)
        let cachedPath = cacheDirectory.appendingPathComponent("\(key).jpg")
        try? imageData?.write(to: cachedPath)
    }
    
    /// Кэширует изображение по ключу с указанным расширением
    public func cacheImage(_ image: UIImage, forKey key: String, withExtension ext: String) {
        let nsKey = NSString(string: key)
        
        // Добавляем в memory cache для мгновенного доступа
        memoryCache.setObject(image, forKey: nsKey)
        
        // Сохраняем на диск с указанным расширением
        let imageData = image.jpegData(compressionQuality: 0.8)
        let cachedPath = cacheDirectory.appendingPathComponent("\(key).\(ext)")
        try? imageData?.write(to: cachedPath)
    }
    
    /// Получает изображение по ключу
    public func getCachedImage(forKey key: String) -> UIImage? {
        let nsKey = NSString(string: key)
        
        // Сначала проверяем memory cache (самый быстрый)
        if let cachedImage = memoryCache.object(forKey: nsKey) {
            return cachedImage
        }
        
        // Затем проверяем disk cache (медленнее) - ищем файлы с любым расширением изображения
        let imageExtensions = ["jpg", "jpeg", "png", "webp"]
        for ext in imageExtensions {
            let cachedPath = cacheDirectory.appendingPathComponent("\(key).\(ext)")
            if fileManager.fileExists(atPath: cachedPath.path),
               let image = UIImage(contentsOfFile: cachedPath.path) {
                // Добавляем в memory cache для следующих обращений
                memoryCache.setObject(image, forKey: nsKey)
                return image
            }
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    private func downloadAndCache(url: String, effectPreviewLogTag: String?, completion: @escaping (Result<String, NetworkError>) -> Void) {
        func elog(_ message: String) {
            if let tag = effectPreviewLogTag {
                print("\(tag) ImageDownloader \(message)")
            }
        }

        guard let downloadURL = URL(string: url) else {
            failedDownloads += 1
            elog("downloadAndCache ABORT invalid URL string")
            completion(.failure(.invalidURL))
            return
        }

        elog("URLSession.dataTask START host=\(downloadURL.host ?? "?")")
        session.dataTask(with: downloadURL) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.failedDownloads += 1
                elog("dataTask error=\(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(.requestFailed(error)))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.failedDownloads += 1
                elog("dataTask response not HTTPURLResponse")
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }

            elog("HTTP status=\(httpResponse.statusCode) bytes=\(data?.count ?? -1)")

            guard httpResponse.statusCode == 200 else {
                self.failedDownloads += 1
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }

            guard let data = data else {
                self.failedDownloads += 1
                elog("dataTask data=nil")
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }

            // Создаем изображение в фоне
            DispatchQueue.global(qos: .background).async {
                guard let image = UIImage(data: data) else {
                    self.failedDownloads += 1
                    elog("UIImage(data:) FAILED — not decodable image bytes (wrong format or empty payload)")
                    DispatchQueue.main.async {
                        completion(.failure(.invalidResponse))
                    }
                    return
                }

                elog("UIImage(data:) OK size=\(image.size); memoryCache setObject fullURL; writing disk")
                // RAM-ключ = полная строка URL (совпадает с `getCachedImage(from:)` и `CachedAsyncImage`).
                DispatchQueue.main.async {
                    let memKey = NSString(string: url)
                    self.memoryCache.setObject(image, forKey: memKey)
                }

                // Сохраняем на диск в фоне
                let cachedPath = self.diskCachePath(for: url)
                do {
                    try data.write(to: cachedPath)
                    self.successfulDownloads += 1
                    elog("disk write OK path.suffix=\(String(cachedPath.path.suffix(64)))")
                } catch {
                    self.failedDownloads += 1
                    elog("disk write FAILED \(error.localizedDescription)")
                }

                DispatchQueue.main.async {
                    completion(.success(cachedPath.path))
                }
            }
        }.resume()
    }
    
    private func diskCachePath(for url: String) -> URL {
        let fileName = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return cacheDirectory.appendingPathComponent("\(fileName).jpg")
    }
    
    /// Извлекает имя файла из URL (без расширения)
    private func extractFileName(from urlString: String) -> String {
        let components = urlString.components(separatedBy: "/")
        let fullFileName = components.last ?? urlString
        
        // Убираем расширение для поиска в кэше
        // Обрабатываем файлы с множественными точками правильно
        // annafoxy._1753709020788_forest_fairy_--v_7_girl-bc747c42-a9e7-48c7-89cc-a5b6a6921ff6-min.webp → annafoxy._1753709020788_forest_fairy_--v_7_girl-bc747c42-a9e7-48c7-89cc-a5b6a6921ff6-min
        
        // Находим последнюю точку (расширение файла)
        if let lastDotIndex = fullFileName.lastIndex(of: ".") {
            let fileNameWithoutExtension = String(fullFileName[..<lastDotIndex])
            return fileNameWithoutExtension
        }
        
        return fullFileName
    }
    
    // MARK: - Statistics
    public func getStatistics() -> (downloads: Int, cacheHits: Int, failures: Int) {
        return (successfulDownloads, successfulCacheHits, failedDownloads)
    }
    
    public func printStatistics() {
        let stats = getStatistics()
        print("📊 [ImageDownloader] Statistics - Downloads: \(stats.downloads), Cache hits: \(stats.cacheHits), Failures: \(stats.failures)")
    }
    
    // MARK: - Cache Management
} 