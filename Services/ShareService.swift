import SwiftUI
import UIKit

class ShareService: ObservableObject {
    
    /// Поделиться изображением
    /// - Parameters:
    ///   - image: UIImage для шаринга
    ///   - isProUser: Является ли пользователь PRO
    ///   - sourceView: UIView для iPad (popover)
    ///   - sourceRect: CGRect для iPad (popover)
    func shareImage(_ image: UIImage, isProUser: Bool = false, from sourceView: UIView? = nil, sourceRect: CGRect = .zero) {
        // Добавляем вотермарк только для непримиум пользователей
        let finalImage = isProUser ? image : (image.addWatermark() ?? image)
        
        // Создаем текст для шаринга
        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "AI Video"
        
        // Используем App Store ID из конфигурации
        guard let appStoreID = ConfigurationManager.shared.getValue(for: .appStoreID) else {
            print("❌ [ShareService] App Store ID not configured")
            return
        }
        let appStoreURL = "https://apps.apple.com/app/id\(appStoreID)"
        let shareText = "\(appName): \(appStoreURL)"
        
        let activityViewController = UIActivityViewController(
            activityItems: [finalImage, shareText],
            applicationActivities: nil
        )
        
        // Настройка для iPad
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.any]
        }
        
        // Получаем текущий UIWindow и находим самый верхний контроллер
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            
            // Находим самый верхний контроллер
            var topController = window.rootViewController
            while let presentedController = topController?.presentedViewController {
                topController = presentedController
            }
            
            // Проверяем, что контроллер не занят представлением другого контроллера
            if topController?.presentedViewController == nil {
                topController?.present(activityViewController, animated: true)
            } else {
                print("⚠️ Cannot present share sheet - another view controller is being presented")
            }
        }
    }
    
    /// Поделиться изображением по URL
    /// - Parameters:
    ///   - imageURL: URL изображения
    ///   - isProUser: Является ли пользователь PRO
    ///   - sourceView: UIView для iPad (popover)
    ///   - sourceRect: CGRect для iPad (popover)
    func shareImageFromURL(_ imageURL: String, isProUser: Bool = false, from sourceView: UIView? = nil, sourceRect: CGRect = .zero) {
        // Проверяем, это локальный файл или удаленный URL
        if imageURL.hasPrefix("http") {
            // Удаленный URL - сначала пытаемся получить из кэша
            if let cachedImage = ImageDownloader.shared.getCachedImage(from: imageURL) {
                shareImage(cachedImage, isProUser: isProUser, from: sourceView, sourceRect: sourceRect)
                return
            }
            
            // Если нет в кэше, загружаем
            if let url = URL(string: imageURL) {
                URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                    DispatchQueue.main.async {
                        if let data = data, let image = UIImage(data: data) {
                            self?.shareImage(image, isProUser: isProUser, from: sourceView, sourceRect: sourceRect)
                        } else {
                            print("❌ Failed to load image for sharing: \(error?.localizedDescription ?? "Unknown error")")
                        }
                    }
                }.resume()
            } else {
                print("❌ Invalid remote URL: \(imageURL)")
            }
        } else {
            // Локальный файл - читаем напрямую
            if let uiImage = UIImage(contentsOfFile: imageURL) {
                shareImage(uiImage, isProUser: isProUser, from: sourceView, sourceRect: sourceRect)
            } else {
                print("❌ Failed to load local image: \(imageURL)")
            }
        }
    }

    func shareVideoFromURL(_ videoURL: String, from sourceView: UIView? = nil, sourceRect: CGRect = .zero) {
        let normalized = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let item: Any
        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://"), let url = URL(string: normalized) {
            item = url
        } else {
            item = URL(fileURLWithPath: normalized)
        }

        let activityViewController = UIActivityViewController(
            activityItems: [item],
            applicationActivities: nil
        )

        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.any]
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            var topController = window.rootViewController
            while let presentedController = topController?.presentedViewController {
                topController = presentedController
            }
            topController?.present(activityViewController, animated: true)
        }
    }
    
    /// Поделиться изображением из GeneratedImage
    /// - Parameters:
    ///   - generatedImage: GeneratedImage объект
    ///   - isProUser: Является ли пользователь PRO
    ///   - sourceView: UIView для iPad (popover)
    ///   - sourceRect: CGRect для iPad (popover)
    func shareGeneratedImage(_ generatedImage: GeneratedImage, isProUser: Bool = false, from sourceView: UIView? = nil, sourceRect: CGRect = .zero) {
        if generatedImage.isVideo {
            shareVideoFromURL(generatedImage.imageURL, from: sourceView, sourceRect: sourceRect)
            return
        }

        if generatedImage.imageURL.hasPrefix("http") {
            // Удаленное изображение
            shareImageFromURL(generatedImage.imageURL, isProUser: isProUser, from: sourceView, sourceRect: sourceRect)
        } else {
            // Локальное изображение
            shareImageFromURL(generatedImage.localPath, isProUser: isProUser, from: sourceView, sourceRect: sourceRect)
        }
    }
    
    /// Поделиться приложением
    /// - Parameters:
    ///   - sourceView: UIView для iPad (popover)
    ///   - sourceRect: CGRect для iPad (popover)
    func shareApp(from sourceView: UIView? = nil, sourceRect: CGRect = .zero) {
        // Получаем информацию о приложении
        let appName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "AI Video"
        let appDescription = "Create stunning AI-powered videos and images in seconds!"
        
        // Используем App Store ID из конфигурации
        guard let appStoreID = ConfigurationManager.shared.getValue(for: .appStoreID) else {
            print("❌ [ShareService] App Store ID not configured")
            return
        }
        let appStoreURL = "https://apps.apple.com/app/id\(appStoreID)"
        
        // Создаем текст для шаринга
        let shareText = "\(appName)\n\n\(appDescription)\n\nDownload now: \(appStoreURL)"
        
        let activityViewController = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )
        
        // Настройка для iPad
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.any]
        }
        
        // Получаем текущий UIWindow и находим самый верхний контроллер
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            
            // Находим самый верхний контроллер
            var topController = window.rootViewController
            while let presentedController = topController?.presentedViewController {
                topController = presentedController
            }
            
            // Проверяем, что контроллер не занят представлением другого контроллера
            if topController?.presentedViewController == nil {
                topController?.present(activityViewController, animated: true)
            } else {
                print("⚠️ Cannot present share sheet - another view controller is being presented")
            }
        }
    }
} 