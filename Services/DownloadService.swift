import SwiftUI
import Photos
import UIKit

class DownloadService: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Float = 0.0
    
    /// Скачать изображение в галерею
    /// - Parameters:
    ///   - image: UIImage для сохранения
    ///   - isProUser: Является ли пользователь PRO
    ///   - completion: Callback с результатом
    func downloadImage(_ image: UIImage, isProUser: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        isDownloading = true
        downloadProgress = 0.0
        
        // Проверяем разрешения
        checkPhotoLibraryPermission { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isDownloading = false
                    completion(false, "Photo library access denied")
                }
                return
            }
            
            // Добавляем вотермарк только для непримиум пользователей
            let finalImage = isProUser ? image : (image.addWatermark() ?? image)
            
            // Сохраняем изображение
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: finalImage)
            }) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isDownloading = false
                    self.downloadProgress = success ? 1.0 : 0.0
                    
                    if success {
                        completion(true, nil)
                    } else {
                        completion(false, error?.localizedDescription ?? "Failed to save image")
                    }
                }
            }
        }
    }
    
    /// Скачать изображение по URL
    /// - Parameters:
    ///   - imageURL: URL изображения
    ///   - isProUser: Является ли пользователь PRO
    ///   - completion: Callback с результатом
    func downloadImageFromURL(_ imageURL: String, isProUser: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        isDownloading = true
        downloadProgress = 0.0
        
        // Проверяем разрешения
        checkPhotoLibraryPermission { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isDownloading = false
                    completion(false, "Photo library access denied")
                }
                return
            }
            
            // Проверяем, это локальный файл или удаленный URL
            if imageURL.hasPrefix("http") {
                // Удаленный URL - сначала пытаемся получить из кэша
                if let cachedImage = ImageDownloader.shared.getCachedImage(from: imageURL) {
                    guard let self = self else { return }
                    self.downloadProgress = 0.5
                    self.downloadImage(cachedImage, isProUser: isProUser, completion: completion)
                    return
                }
                
                // Если нет в кэше, загружаем
                if let url = URL(string: imageURL) {
                    URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            
                            if let data = data, let image = UIImage(data: data) {
                                self.downloadProgress = 0.5
                                self.downloadImage(image, isProUser: isProUser, completion: completion)
                            } else {
                                self.isDownloading = false
                                self.downloadProgress = 0.0
                                completion(false, error?.localizedDescription ?? "Failed to load image")
                            }
                        }
                    }.resume()
                } else {
                    guard let self = self else { return }
                    self.isDownloading = false
                    self.downloadProgress = 0.0
                    completion(false, "Invalid remote URL")
                }
            } else {
                // Локальный файл - читаем напрямую
                if let uiImage = UIImage(contentsOfFile: imageURL) {
                    guard let self = self else { return }
                    self.downloadProgress = 0.5
                    self.downloadImage(uiImage, isProUser: isProUser, completion: completion)
                } else {
                    guard let self = self else { return }
                    self.isDownloading = false
                    self.downloadProgress = 0.0
                    completion(false, "Failed to load local image")
                }
            }
        }
    }

    func downloadVideoFromURL(_ videoURL: String, completion: @escaping (Bool, String?) -> Void) {
        isDownloading = true
        downloadProgress = 0.0

        checkPhotoLibraryPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(false, "Photo library access denied")
                }
                return
            }

            let normalized = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") {
                guard let remoteURL = URL(string: normalized) else {
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        completion(false, "Invalid remote URL")
                    }
                    return
                }
                URLSession.shared.downloadTask(with: remoteURL) { tempURL, _, error in
                    if let error {
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            completion(false, error.localizedDescription)
                        }
                        return
                    }
                    guard let tempURL else {
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            completion(false, "Failed to load video")
                        }
                        return
                    }
                    do {
                        let stableURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension)
                        try FileManager.default.copyItem(at: tempURL, to: stableURL)
                        self.saveVideoToPhotoLibrary(fileURL: stableURL) { success, message in
                            try? FileManager.default.removeItem(at: stableURL)
                            completion(success, message)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.isDownloading = false
                            completion(false, error.localizedDescription)
                        }
                    }
                }.resume()
            } else {
                let localURL = URL(fileURLWithPath: normalized)
                saveVideoToPhotoLibrary(fileURL: localURL, completion: completion)
            }
        }
    }
    
    /// Скачать GeneratedImage
    /// - Parameters:
    ///   - generatedImage: GeneratedImage объект
    ///   - isProUser: Является ли пользователь PRO
    ///   - completion: Callback с результатом
    func downloadGeneratedImage(_ generatedImage: GeneratedImage, isProUser: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        if generatedImage.isVideo {
            downloadVideoFromURL(generatedImage.imageURL, completion: completion)
            return
        }

        if generatedImage.imageURL.hasPrefix("http") {
            // Удаленное изображение
            downloadImageFromURL(generatedImage.imageURL, isProUser: isProUser, completion: completion)
        } else {
            // Локальное изображение
            downloadImageFromURL(generatedImage.localPath, isProUser: isProUser, completion: completion)
        }
    }

    private func saveVideoToPhotoLibrary(fileURL: URL, completion: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloading = false
                self.downloadProgress = success ? 1.0 : 0.0
                if success {
                    completion(true, nil)
                } else {
                    completion(false, error?.localizedDescription ?? "Failed to save video")
                }
            }
        }
    }
    
    /// Проверить разрешение на доступ к галерее
    /// - Parameter completion: Callback с результатом
    private func checkPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        
        switch status {
        case .authorized, .limited:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    completion(status == .authorized || status == .limited)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    /// Показать настройки приложения для разрешений
    func showSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
} 