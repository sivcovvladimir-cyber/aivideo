import Foundation

/// A singleton class responsible for managing and providing secure access to API keys and configuration values
final class ConfigurationManager {
    /// Shared instance of the ConfigurationManager
    static let shared = ConfigurationManager()
    
    /// Dictionary to store configuration values
    private var configuration: [String: String] = [:]
    
    /// Private initializer to enforce singleton pattern
    private init() {
        loadConfiguration()
    }
    
    /// Configuration keys enum
    enum ConfigKey: String {
        // Replicate API
        case replicateAPIKey = "REPLICATE_API_KEY"

        // useapi.net / PixVerse
        case useAPIToken = "USEAPI_TOKEN"
        case pixVerseAccountEmail = "PIXVERSE_ACCOUNT_EMAIL"

        // OpenAI (для «Улучшить текст»)
        case openAIAPIKey = "OPENAI_API_KEY"

        // Adapty
        case adaptyPublicKey = "ADAPTY_PUBLIC_KEY"

        // Firebase
        case firebaseAPIKey = "FIREBASE_API_KEY"

        // AppsFlyer
        case appsFlyerDevKey = "APPSFLYER_DEV_KEY"

        // App Store
        case appStoreID = "APP_STORE_ID"

        // Support
        case telegramBotToken = "TELEGRAM_BOT_TOKEN"
        case telegramChatId = "TELEGRAM_CHAT_ID"

        // Debug
        case debugPasswordHash = "DEBUG_PASSWORD_HASH"

        // Legal
        case termsOfServiceURL = "TERMS_OF_SERVICE_URL"
        case privacyPolicyURL = "PRIVACY_POLICY_URL"

        // Устаревшие ключи (файлы оставлены, не используются)
        case supabaseURL = "SUPABASE_URL"
        case supabaseAnonKey = "SUPABASE_ANON_KEY"
        case faceSwapAPIKey = "FACE_SWAP_API_KEY"
        case faceSwapAPIURL = "FACE_SWAP_API_URL"
        case stylesArchiveURL = "STYLES_ARCHIVE_URL"
    }
    
    /// Load configuration from plist file
    private func loadConfiguration() {
        guard let path = Bundle.main.path(forResource: "APIKeys", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            fatalError("Unable to load APIKeys.plist. Please ensure the file exists and is properly configured.")
        }
        
        self.configuration = dict
        
        // Validate required keys
        validateConfiguration()
    }
    
    /// Validate that all required keys are present and not empty
    private func validateConfiguration() {
        // Как в storecards: ключи APIKeys не обязательны глобально.
        // Каждый SDK включаетcя отдельно, когда конкретный ключ реально задан.
        #if DEBUG
        if configuration.isEmpty {
            print("⚠️ Warning: APIKeys.plist is empty")
        }
        #endif
    }
    
    /// Get a configuration value for a given key
    /// - Parameter key: The configuration key to retrieve
    /// - Returns: The configuration value if found, nil otherwise
    func getValue(for key: ConfigKey) -> String? {
        return configuration[key.rawValue]
    }

    /// Get a configuration value for a given key, throwing an error if not found
    /// - Parameter key: The configuration key to retrieve
    /// - Returns: The configuration value
    /// - Throws: An error if the value is not found
    func getRequiredValue(for key: ConfigKey) throws -> String {
        guard let value = getValue(for: key) else {
            throw ConfigurationError.missingValue(key: key.rawValue)
        }
        return value
    }

    /// Поддержка через Telegram включается только когда заданы оба ключа без плейсхолдеров.
    var isTelegramSupportConfigured: Bool {
        isKeyConfigured(for: .telegramBotToken) && isKeyConfigured(for: .telegramChatId)
    }

    /// Adapty включаем только при валидном публичном ключе без плейсхолдера.
    var isAdaptyConfigured: Bool {
        isKeyConfigured(for: .adaptyPublicKey)
    }

    /// AppsFlyer только при dev key и App Store ID; иначе не вызываем `start` / `logEvent` / deep link hooks (SDK без ключей шумит в логах).
    var isAppsFlyerConfigured: Bool {
        isKeyConfigured(for: .appsFlyerDevKey) && isKeyConfigured(for: .appStoreID)
    }

    /// Нормализованные креды Telegram поддержки для единого канала отправки.
    var telegramSupportCredentials: (botToken: String, chatId: String)? {
        guard isTelegramSupportConfigured,
              let botToken = getValue(for: .telegramBotToken)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let chatId = getValue(for: .telegramChatId)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !botToken.isEmpty, !chatId.isEmpty else {
            return nil
        }
        return (botToken, chatId)
    }

    func isKeyConfigured(for key: ConfigKey) -> Bool {
        guard let value = getValue(for: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return false
        }

        let uppercased = value.uppercased()
        return !uppercased.contains("YOUR_")
            && !uppercased.contains("TODO")
            && !uppercased.contains("<")
            && !uppercased.contains(">")
    }
}

/// Configuration related errors
enum ConfigurationError: Error {
    case missingValue(key: String)
    
    var localizedDescription: String {
        switch self {
        case .missingValue(let key):
            return "Missing required configuration value for key: \(key)"
        }
    }
} 