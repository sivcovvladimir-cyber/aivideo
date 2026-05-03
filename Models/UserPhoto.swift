import Foundation

// Статус загрузки фото
enum PhotoUploadStatus: String, Codable {
    case uploading = "uploading"      // Загружается в Supabase (включая retry)
    case uploaded = "uploaded"        // Успешно загружено
    case failed = "failed"            // Ошибка загрузки (только после всех попыток)
    case checking = "checking"        // Проверяется доступность
}

struct UserPhoto: Identifiable, Codable, Hashable {
    let id: String
    var remoteUrl: String // Может быть пустым пока фото загружается в облако
    var localPath: String
    var uploadedAt: Date
    let createdAt: Date
    var expiresAt: Date
    var uploadStatus: PhotoUploadStatus // Статус загрузки
    var retryCount: Int = 0 // Счётчик попыток retry
    
    // Инициализатор для создания новых экземпляров
    init(
        id: String,
        remoteUrl: String,
        localPath: String,
        uploadedAt: Date,
        createdAt: Date,
        expiresAt: Date,
        uploadStatus: PhotoUploadStatus,
        retryCount: Int = 0
    ) {
        self.id = id
        self.remoteUrl = remoteUrl
        self.localPath = localPath
        self.uploadedAt = uploadedAt
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.uploadStatus = uploadStatus
        self.retryCount = retryCount
    }
    
    // Проверка, есть ли backup в облаке
    var hasRemoteBackup: Bool {
        return !remoteUrl.isEmpty
    }
    
    // Проверка, готово ли фото для генерации
    var isReadyForGeneration: Bool {
        return uploadStatus == .uploaded && hasRemoteBackup
    }
    
    // Проверка, загружается ли фото
    var isUploading: Bool {
        return uploadStatus == .uploading
    }
    
    // Проверка, есть ли ошибка загрузки
    var hasUploadError: Bool {
        return uploadStatus == .failed
    }
    
    var uniqueID: String {
        "\(id)-\(uploadStatus.rawValue)-\(remoteUrl.hashValue)"
    }
    
    // Hashable implementation
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(remoteUrl)
        hasher.combine(uploadStatus)
    }
    
    static func == (lhs: UserPhoto, rhs: UserPhoto) -> Bool {
        return lhs.id == rhs.id
    }
} 