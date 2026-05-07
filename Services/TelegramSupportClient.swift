import Foundation

/// Отправка обращений в Telegram Bot API (sendMessage). Токен и chat_id берутся из APIKeys.plist.
enum TelegramSupportClient {
    enum SendError: LocalizedError {
        case invalidURL
        case httpStatus(Int)
        case telegramRejected(String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Telegram API URL"
            case .httpStatus(let code): return "HTTP \(code)"
            case .telegramRejected(let description): return description
            case .decoding: return "Bad response"
            }
        }
    }

    private struct SendMessageResponse: Decodable {
        let ok: Bool
        let description: String?
    }

    /// Отправляет текст в чат; сообщение обрезается до лимита Telegram (4096 символов).
    static func sendMessage(text: String, botToken: String, chatId: String) async throws {
        let capped = String(text.prefix(4096))
        let normalizedToken = botToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.telegram.org"
        components.path = "/bot\(normalizedToken)/sendMessage"

        guard let url = components.url else {
            print("❌ [ContactSupport] Invalid Telegram URL. token_length=\(normalizedToken.count)")
            throw SendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "chat_id": chatId,
                "text": capped
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SendError.decoding }
        guard (200 ... 299).contains(http.statusCode) else {
            throw SendError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SendMessageResponse.self, from: data)
        guard decoded.ok else {
            throw SendError.telegramRejected(decoded.description ?? "Unknown error")
        }
    }
}
