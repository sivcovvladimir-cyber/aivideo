import Foundation

/// Последний успешный ответ `get_effects_home`: без него сплеш ждёт сеть; с ним — уходим по таймеру и обновляем payload в фоне.
enum EffectsHomePayloadDiskCache {
    private static let fileName = "effects_home_payload_cache.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(fileName, isDirectory: false)
    }

    static func loadIfPresent() -> EffectsHomePayload? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let payload = try decoder.decode(EffectsHomePayload.self, from: data)
            return payload.mergingHeroPreviewMediaFromSections()
        } catch {
            Swift.print("⚠️ [EffectsHomePayloadDiskCache] decode failed, removing file: \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    static func save(_ payload: EffectsHomePayload) throws {
        let url = fileURL
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
