import SwiftUI
import Foundation

class DeleteService: ObservableObject {
    @Published var isDeleting = false
    
    /// Удалить GeneratedImage
    /// - Parameters:
    ///   - generatedImage: GeneratedImage для удаления
    ///   - appState: AppState для обновления данных
    ///   - completion: Callback с результатом
    func deleteGeneratedImage(_ generatedImage: GeneratedImage, from appState: AppState, completion: @escaping (Bool, String?) -> Void) {
        // Report photo deleted event
        Task {
            await AppAnalyticsService.shared.reportPhotoDeleted(photoId: generatedImage.id)
        }
        
        isDeleting = true
        
        // Удаляем локальный файл если он существует
        deleteLocalFile(generatedImage.localPath) { [weak self] localDeleted in
            self?.deleteLocalFile(generatedImage.thumbnailPath) { _ in }
            Task { @MainActor in
                appState.removeGeneratedMedia(withId: generatedImage.id)
                self?.isDeleting = false
                completion(true, nil)
            }
        }
    }
    
    /// Удалить локальный файл
    /// - Parameters:
    ///   - filePath: Путь к файлу
    ///   - completion: Callback с результатом
    private func deleteLocalFile(_ filePath: String, completion: @escaping (Bool) -> Void) {
        let fileManager = FileManager.default
        
        // Проверяем, существует ли файл
        guard fileManager.fileExists(atPath: filePath) else {
            completion(true) // Файл уже не существует
            return
        }
        
        do {
            try fileManager.removeItem(atPath: filePath)
            print("✅ Local file deleted: \(filePath)")
            completion(true)
        } catch {
            print("❌ Failed to delete local file: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    /// Удалить несколько изображений
    /// - Parameters:
    ///   - generatedImages: Массив GeneratedImage для удаления
    ///   - appState: AppState для обновления данных
    ///   - completion: Callback с результатом
    func deleteMultipleImages(_ generatedImages: [GeneratedImage], from appState: AppState, completion: @escaping (Bool, String?) -> Void) {
        isDeleting = true
        
        let group = DispatchGroup()
        var deleteErrors: [String] = []
        
        for image in generatedImages {
            group.enter()
            deleteLocalFile(image.localPath) { success in
                if !success {
                    deleteErrors.append("Failed to delete: \(image.id)")
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            Task { @MainActor in
                for image in generatedImages {
                    appState.removeGeneratedMedia(withId: image.id)
                }
                self?.isDeleting = false
                if deleteErrors.isEmpty {
                    completion(true, nil)
                } else {
                    completion(false, "Some files couldn't be deleted: \(deleteErrors.joined(separator: ", "))")
                }
            }
        }
    }
    
    /// Очистить все изображения
    /// - Parameters:
    ///   - appState: AppState для обновления данных
    ///   - completion: Callback с результатом
    func clearAllImages(from appState: AppState, completion: @escaping (Bool, String?) -> Void) {
        Task { @MainActor in
            let allImages = appState.generatedMedia
            deleteMultipleImages(allImages, from: appState, completion: completion)
        }
    }
    
    /// Проверить, можно ли удалить изображение
    /// - Parameter generatedImage: GeneratedImage для проверки
    /// - Returns: True если можно удалить
    func canDeleteImage(_ generatedImage: GeneratedImage) -> Bool {
        // Проверяем, существует ли файл или это placeholder
        if generatedImage.imageURL.hasPrefix("placeholder-") {
            return true // Placeholder можно удалить
        }
        
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: generatedImage.localPath) || generatedImage.imageURL.hasPrefix("http")
    }
} 