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
        case supportEmail = "SUPPORT_EMAIL"
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
        let requiredKeys = [
            ConfigKey.replicateAPIKey,
            ConfigKey.adaptyPublicKey,
            ConfigKey.firebaseAPIKey,
            ConfigKey.appsFlyerDevKey
        ]
        
        for key in requiredKeys {
            guard let value = configuration[key.rawValue], !value.isEmpty else {
                #if DEBUG
                print("⚠️ Warning: Missing or empty configuration value for key: \(key.rawValue)")
                #else
                fatalError("Missing required configuration value for key: \(key.rawValue)")
                #endif
                continue
            }
            
            // In DEBUG, warn if using placeholder values
            #if DEBUG
            if value.hasPrefix("YOUR_") {
                print("⚠️ Warning: Using placeholder value for key: \(key.rawValue)")
            }
            #endif
        }
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