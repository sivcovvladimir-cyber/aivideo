import Foundation

/// Режим звука для lip sync: TTS по тексту или загрузка файла.
enum LipSyncInputMode: String, Codable, CaseIterable, Identifiable {
    case lines
    case uploadAudio

    var id: String { rawValue }
}

/// Пресет голоса из GET /videos/voices.
struct PixVerseVoice: Identifiable, Codable, Equatable {
    let speakerId: String
    let displayName: String
    let previewURL: URL?

    var id: String { speakerId }

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case displayName = "display_name"
        case url
    }

    init(speakerId: String, displayName: String, previewURL: URL?) {
        self.speakerId = speakerId
        self.displayName = displayName
        self.previewURL = previewURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringId = try container.decodeIfPresent(String.self, forKey: .speakerId) {
            speakerId = stringId
        } else if let intId = try container.decodeIfPresent(Int.self, forKey: .speakerId) {
            speakerId = String(intId)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .speakerId, in: container, debugDescription: "Missing speaker_id")
        }
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? speakerId
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !urlString.isEmpty {
            previewURL = URL(string: urlString)
        } else {
            previewURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speakerId, forKey: .speakerId)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(previewURL?.absoluteString, forKey: .url)
    }
}

struct PixVerseVoicesResponse: Decodable {
    let ttsList: [PixVerseVoice]

    enum CodingKeys: String, CodingKey {
        case ttsList = "tts_list"
    }
}

/// Лимиты lip sync в UI (PixVerse web — 30 с аудио; TTS — 200 символов).
enum LipSyncLimits {
    static let maxTextCharacters = 200
    static let maxAudioSeconds = 30.0
    static let textBlockCharacters = 50
    static let audioBlockSeconds = 5
    static let pricingBaseVideoSeconds = 5
}
