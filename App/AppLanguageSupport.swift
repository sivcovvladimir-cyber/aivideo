import Foundation

/// Языки, для которых есть `*.lproj` в бандле.
enum AppLanguageSupport {
    static let bundledLanguageCodes: Set<String> = ["en", "ru", "de", "es", "pt", "fr", "it"]

    /// Первый язык из настроек телефона (`Locale.preferredLanguages`). Не смешивать с языком UI приложения (`app_language`).
    static func phoneLanguageCode() -> String? {
        guard let first = Locale.preferredLanguages.first, !first.isEmpty else { return nil }
        let normalized = first.replacingOccurrences(of: "_", with: "-")
        if let range = normalized.range(of: "-") {
            return String(normalized[..<range.lowerBound]).lowercased()
        }
        if normalized.count >= 2 { return String(normalized.prefix(2)).lowercased() }
        return normalized.lowercased()
    }

    /// Локаль для `NumberFormatter` / `ByteCountFormatter` под `app_language`, чтобы «KB», «Mo», «МБ» и т.д. совпадали с выбранным языком, а не только с системной локалью телефона.
    static func locale(forAppLanguageCode code: String) -> Locale {
        switch code.lowercased() {
        case "de": return Locale(identifier: "de_DE")
        case "es": return Locale(identifier: "es_ES")
        case "pt": return Locale(identifier: "pt_BR")
        case "fr": return Locale(identifier: "fr_FR")
        case "it": return Locale(identifier: "it_IT")
        case "ru": return Locale(identifier: "ru_RU")
        default: return Locale(identifier: "en_US")
        }
    }

    /// Название языка на нём самом (как в системных списках языков): не зависит от локали UI приложения.
    static func nativeEndonym(for code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "de": return "Deutsch"
        case "ru": return "Русский"
        case "es": return "Español"
        case "pt": return "Português"
        case "fr": return "Français"
        case "it": return "Italiano"
        default: return code
        }
    }
}
