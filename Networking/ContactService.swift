import Foundation

class ContactService {
    static let shared = ContactService()

    private init() {}

    // MARK: - Public API

    func submitContactForm(
        message: String,
        replyEmail: String? = nil,
        adaptyProfileId: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success(()))
            return
        }

        // Единый путь support: только Telegram Bot API без legacy-каналов.
        guard let creds = ConfigurationManager.shared.telegramSupportCredentials else {
            let error = NSError(
                domain: "ContactService",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Telegram support is not configured"]
            )
            completion(.failure(error))
            return
        }

        Task {
            do {
                try await TelegramSupportClient.sendMessage(
                    text: buildTelegramSupportMessage(
                        from: trimmed,
                        replyEmail: replyEmail,
                        adaptyProfileId: adaptyProfileId
                    ),
                    botToken: creds.botToken,
                    chatId: creds.chatId
                )
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                print("❌ [ContactSupport] Telegram sendMessage failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func submitNegativeFeedback(message: String, completion: @escaping (Result<Void, Error>) -> Void) {
        submitContactForm(message: message, completion: completion)
    }

    // MARK: - Private

    /// Добавляет технический хвост к сообщению для быстрой диагностики в поддержке.
    private func buildTelegramSupportMessage(
        from message: String,
        replyEmail: String?,
        adaptyProfileId: String?
    ) -> String {
        let appName = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? "AIVideo"
        let bundleId = Bundle.main.bundleIdentifier ?? "—"
        let localeId = Locale.current.identifier
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let appStoreId = (Bundle.main.infoDictionary?["APP_STORE_ID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appStoreLine = (appStoreId?.isEmpty == false) ? (appStoreId ?? "—") : "—"
        let trimmedEmail = replyEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let safeProfileId: String = {
            let trimmed = adaptyProfileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "—" : trimmed
        }()

        var body = message
        if !trimmedEmail.isEmpty {
            body += "\n\nReply email: \(trimmedEmail)"
        }

        return """
        \(body)

        —
        App: \(appName)
        Bundle ID: \(bundleId)
        App Store ID: \(appStoreLine)
        Adapty profile ID: \(safeProfileId)
        Locale: \(localeId)
        Version: \(marketing)
        Build: \(build)
        """
    }
}
