import Foundation

final class GeneratedImageService {
    static let shared = GeneratedImageService()
    private init() {}
    
    private let generatedImagesDirectoryName = "GeneratedImages"
    private let userDefaults = UserDefaults.standard
    private let generatedMediaKey = "generated_media"
    
    // MARK: - Сохранение изображения (legacy)
    func saveGeneratedImage(data: Data, styleId: Int, userPhotoId: String, resultUrl: String) throws -> GeneratedMedia {
        let imageId = UUID().uuidString
        let fileName = "\(imageId).jpg"
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let generatedImagesDirectory = documentsPath.appendingPathComponent(generatedImagesDirectoryName)
        if !FileManager.default.fileExists(atPath: generatedImagesDirectory.path) {
            try FileManager.default.createDirectory(at: generatedImagesDirectory, withIntermediateDirectories: true)
        }
        let localPath = generatedImagesDirectory.appendingPathComponent(fileName).path
        try data.write(to: URL(fileURLWithPath: localPath))

        let generatedMedia = GeneratedMedia(
            id: imageId,
            localPath: localPath,
            createdAt: Date(),
            styleId: styleId,
            userPhotoId: userPhotoId,
            type: .image,
            logoStyleId: nil,
            logoFontId: nil,
            logoColorIds: nil,
            backgroundColorId: nil,
            brandName: nil,
            logoDescription: nil,
            prompt: nil,
            aiModelId: nil,
            paletteId: nil
        )

        // После сохранения файла — превью для Library рядом с медиа.
        GeneratedMedia.generateThumbnail(for: generatedMedia)

        var allMedia = loadGeneratedImages()
        allMedia.insert(generatedMedia, at: 0)
        saveGeneratedImages(allMedia)
        print("💾 [GeneratedImageService] Saved image: \(imageId)")
        return generatedMedia
    }

    // Сохраняет готовый AI Video результат из PixVerse в общий локальный индекс Library.
    func saveGeneratedMedia(data: Data, type: MediaType, prompt: String?, resultUrl: String) throws -> GeneratedMedia {
        let mediaId = UUID().uuidString
        let fileExtension = type == .video ? "mp4" : "jpg"
        let fileName = "\(mediaId).\(fileExtension)"
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let generatedImagesDirectory = documentsPath.appendingPathComponent(generatedImagesDirectoryName)
        if !FileManager.default.fileExists(atPath: generatedImagesDirectory.path) {
            try FileManager.default.createDirectory(at: generatedImagesDirectory, withIntermediateDirectories: true)
        }
        let localPath = generatedImagesDirectory.appendingPathComponent(fileName).path
        try data.write(to: URL(fileURLWithPath: localPath))

        let generatedMedia = GeneratedMedia(
            id: mediaId,
            localPath: localPath,
            createdAt: Date(),
            styleId: 0,
            userPhotoId: "",
            type: type,
            logoStyleId: nil,
            logoFontId: nil,
            logoColorIds: nil,
            backgroundColorId: nil,
            brandName: nil,
            logoDescription: nil,
            prompt: prompt,
            aiModelId: nil,
            paletteId: nil
        )

        GeneratedMedia.generateThumbnail(for: generatedMedia)

        var allMedia = loadGeneratedImages()
        allMedia.insert(generatedMedia, at: 0)
        saveGeneratedImages(allMedia)
        print("💾 [GeneratedImageService] Saved PixVerse media: \(mediaId) from \(resultUrl)")
        return generatedMedia
    }

    // MARK: - Загрузка всех сгенерированных изображений из UserDefaults
    func loadGeneratedImages() -> [GeneratedMedia] {
        guard let data = userDefaults.data(forKey: generatedMediaKey) else {
            return []
        }
        
        guard let media = try? JSONDecoder().decode([GeneratedMedia].self, from: data) else {
            return []
        }
        
        // Валидируем существование файлов и исправляем пути при необходимости
        var validMedia: [GeneratedMedia] = []
        
        for item in media {
            if let validatedItem = validateAndFixImagePath(item) {
                validMedia.append(validatedItem)
            }
        }
        
        // Сохраняем очищенный список только если что-то изменилось
        if validMedia.count != media.count {
            saveGeneratedImages(validMedia)
        }
        
        // Сортируем по дате создания (новые первыми)
        let sortedMedia = validMedia.sorted { $0.createdAt > $1.createdAt }
        
        return sortedMedia
    }
    
    // MARK: - Валидация и исправление путей к файлам
    private func validateAndFixImagePath(_ media: GeneratedMedia) -> GeneratedMedia? {
        // Проверяем существование файла по текущему пути
        if FileManager.default.fileExists(atPath: media.localPath) {
            return media
        }
        
        // Файл не найден по текущему пути, пытаемся найти по имени файла
        let fileName = URL(fileURLWithPath: media.localPath).lastPathComponent
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let generatedImagesDirectory = documentsPath.appendingPathComponent(generatedImagesDirectoryName)
        let expectedPath = generatedImagesDirectory.appendingPathComponent(fileName).path
        
        if FileManager.default.fileExists(atPath: expectedPath) {
            // Создаем обновленную версию с исправленным путем
            var fixedMedia = media
            fixedMedia.localPath = expectedPath
            return fixedMedia
        }

        // Файл не найден — пропускаем элемент (не логируем, чтобы не засорять консоль).
        return nil
    }
    
    // MARK: - Сохранение метаданных в UserDefaults
    private func saveGeneratedImages(_ media: [GeneratedMedia]) {
        do {
            let encoded = try JSONEncoder().encode(media)
            userDefaults.set(encoded, forKey: generatedMediaKey)
            print("💾 [GeneratedImageService] Saved \(media.count) generated images to UserDefaults")
        } catch {
            print("❌ [GeneratedImageService] Failed to encode media for UserDefaults: \(error)")
        }
    }
    
    // MARK: - Удаление изображения
    func deleteGeneratedImage(_ image: GeneratedMedia) {
        try? FileManager.default.removeItem(atPath: image.localPath)
        try? FileManager.default.removeItem(atPath: image.thumbnailPath)
        
        var allMedia = loadGeneratedImages()
        allMedia.removeAll { $0.id == image.id }
        saveGeneratedImages(allMedia)
        
        print("🗑️ [GeneratedImageService] Deleted image and metadata for ID: \(image.id)")
    }

    /// Суммарный размер каталога `GeneratedImages` (медиа + `_thumb`); то же дерево файлов, что затрагивает «Очистить галерею».
    func estimatedGalleryFolderDiskBytes() -> Int64 {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documentsPath.appendingPathComponent(generatedImagesDirectoryName, isDirectory: true)
        return ImageDownloader.totalRegularFileBytes(in: dir)
    }

    /// Очищает локальную галерею, оставляя только элементы из избранного.
    /// Глобальные записи Supabase не затрагиваются — работаем только с локальным storage + UserDefaults.
    func clearGeneratedImages(keepingFavoriteIds favoriteIds: Set<String>) {
        let allMedia = loadGeneratedImages()
        let retainedMedia = allMedia.filter { favoriteIds.contains($0.id) }
        let removedMedia = allMedia.filter { !favoriteIds.contains($0.id) }

        for media in removedMedia {
            try? FileManager.default.removeItem(atPath: media.localPath)
            try? FileManager.default.removeItem(atPath: media.thumbnailPath)
        }

        // Обновляем локальную "базу" галереи в UserDefaults.
        saveGeneratedImages(retainedMedia)
        print("🧹 [GeneratedImageService] Gallery cleanup done. Kept: \(retainedMedia.count), removed: \(removedMedia.count)")
    }
    
    // MARK: - Supabase (отключено)
    /// Удалённый серверный лог генераций для этого клиента не используется.
    /// Методы оставлены пустыми для обратной совместимости с существующими вызовами.
    func logGenerationToSupabase(userId: String?, userPhotoId: String, styleId: Int, resultUrl: String, status: String, errorMessage: String?, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        completion(.success(()))
    }
    
    func incrementEffectRowUsage(effectRowId: Int, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        completion(.success(()))
    }
} 