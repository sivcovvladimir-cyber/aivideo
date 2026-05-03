import Foundation
import ImageIO
import AVFoundation
import UIKit

public enum MediaType: String, Codable {
    case image
    case video
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        
        switch rawValue.lowercased() {
        case "image":
            self = .image
        case "video":
            self = .video
        default:
            // Если неизвестное значение, по умолчанию считаем image
            self = .image
        }
    }
}

struct GeneratedMedia: Identifiable, Codable, Equatable {
    let id: String
    var localPath: String
    let createdAt: Date
    // Legacy fields (face swap compatibility)
    let styleId: Int
    let userPhotoId: String
    let type: MediaType

    // Logo metadata (optional — отсутствует у старых записей)
    let logoStyleId: String?
    let logoFontId: String?
    let logoColorIds: [String]?
    let backgroundColorId: String?
    let brandName: String?
    let logoDescription: String?
    let prompt: String?
    /// ID модели генерации, если известно.
    let aiModelId: String?
    /// ID палетки (preset/custom), если известно.
    let paletteId: String?

    // Computed properties
    var imageURL: String { localPath }
    var isVideo: Bool { type == .video }

    /// Путь к уменьшенной копии (512px, JPEG 80%) рядом с оригиналом.
    var thumbnailPath: String {
        (localPath as NSString).deletingPathExtension + "_thumb.jpg"
    }

    /// true, если thumbnail уже существует на диске.
    var hasThumbnail: Bool {
        FileManager.default.fileExists(atPath: thumbnailPath)
    }

}

// MARK: - Thumbnail Generation

extension GeneratedMedia {
    private static let thumbMaxPixel: CGFloat = 512
    private static let thumbJPEGQuality: CGFloat = 0.80

    /// Создаёт thumbnail рядом с оригиналом: для изображений делает downsample, для видео берёт первый кадр.
    /// Возвращает true, если файл создан или уже существовал.
    @discardableResult
    static func generateThumbnail(for media: GeneratedMedia) -> Bool {
        let dest = media.thumbnailPath
        if FileManager.default.fileExists(atPath: dest) { return true }
        if media.isVideo {
            return generateVideoThumbnail(for: media, destinationPath: dest)
        }
        guard let data = FileManager.default.contents(atPath: media.localPath),
              let downsampled = downsample(data, maxPixel: thumbMaxPixel),
              let jpeg = downsampled.jpegData(compressionQuality: thumbJPEGQuality)
        else { return false }
        return FileManager.default.createFile(atPath: dest, contents: jpeg)
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func generateVideoThumbnail(for media: GeneratedMedia, destinationPath: String) -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: media.localPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbMaxPixel, height: thumbMaxPixel)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            guard let jpeg = image.jpegData(compressionQuality: thumbJPEGQuality) else { return false }
            return FileManager.default.createFile(atPath: destinationPath, contents: jpeg)
        } catch {
            return false
        }
    }
}

// Alias для обратной совместимости
typealias GeneratedImage = GeneratedMedia 