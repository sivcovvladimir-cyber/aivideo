import Foundation
import Security

/// Дублирует счётчик бесплатных (не PRO) генераций в Keychain, чтобы лимит не сбрасывался после переустановки приложения. UserDefaults при удалении очищается, Keychain — нет; при запуске берём максимум из обоих.
final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    private let freeGenerationsKey = "aivideo_free_generations_used"
    private let tokenWalletInitializedKey = "aivideo_token_wallet_initialized"
    private let tokenBalanceKey = "aivideo_token_balance"
    private let tokenLastRefreshDayKey = "aivideo_token_last_refresh_day"

    // MARK: - Public API

    /// Возвращает количество использованных бесплатных генераций из Keychain.
    /// Возвращает 0 если запись ещё не создавалась (первый запуск).
    func getFreeGenerationsUsed() -> Int {
        guard let str = get(key: freeGenerationsKey), let n = Int(str) else { return 0 }
        return max(0, n)
    }

    /// Записывает актуальное количество бесплатных генераций в Keychain.
    /// Вызывается после каждой успешной бесплатной генерации.
    func setFreeGenerationsUsed(_ count: Int) {
        set(key: freeGenerationsKey, value: String(count))
    }

    /// Сбрасывает счётчик в 0. Используется только в Debug-режиме (если отдельная кнопка снова понадобится).
    func resetFreeGenerations() {
        set(key: freeGenerationsKey, value: "0")
    }

    // MARK: - Token Wallet

    /// Token wallet хранится в Keychain, чтобы стартовый баланс и дневная квота не сбрасывались после переустановки.
    func isTokenWalletInitialized() -> Bool {
        get(key: tokenWalletInitializedKey) == "1"
    }

    func setTokenWalletInitialized(_ value: Bool) {
        set(key: tokenWalletInitializedKey, value: value ? "1" : "0")
    }

    func getTokenBalance() -> Int? {
        guard let str = get(key: tokenBalanceKey), let value = Int(str) else { return nil }
        return max(0, value)
    }

    func setTokenBalance(_ value: Int) {
        set(key: tokenBalanceKey, value: String(max(0, value)))
    }

    func getTokenLastRefreshDay() -> String? {
        get(key: tokenLastRefreshDayKey)
    }

    func setTokenLastRefreshDay(_ value: String) {
        set(key: tokenLastRefreshDayKey, value: value)
    }

    func resetTokenWallet() {
        setTokenWalletInitialized(false)
        setTokenBalance(0)
        setTokenLastRefreshDay("")
    }

    // MARK: - Keychain primitives

    private func set(key: String, value: String) {
        let data = Data(value.utf8)
        // delete + add надёжнее чем SecItemUpdate (работает при первой записи и при обновлении)
        SecItemDelete(query(key: key) as CFDictionary)
        var item = query(key: key)
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            print("🔑 [Keychain] set '\(key)' failed: \(status)")
        }
    }

    private func get(key: String) -> String? {
        var q = query(key: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func query(key: String) -> [String: Any] {
        // kSecAttrService изолирует ключи этого приложения от других приложений с тем же Team ID
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.company.aivideo",
            kSecAttrAccount as String: key
        ]
    }
}
