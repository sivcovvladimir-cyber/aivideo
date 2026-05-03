import Combine
import Foundation

final class TokenWalletService: ObservableObject {
    static let shared = TokenWalletService()

    @Published private(set) var balance: Int = 0
    @Published private(set) var lastRefreshDay: String = ""

    private let keychain = KeychainService.shared
    private let calendar = Calendar.current

    private init() {
        syncWithCurrentConfig()
    }

    var dailyAllowance: Int {
        GenerationCostCalculator().dailyTokenAllowance
    }

    var startingBalance: Int {
        GenerationCostCalculator().startingTokenBalance
    }

    /// Синхронизирует wallet с календарным днём: первый запуск — стартовый баланс; новый день — рефил до дневного порога: если баланс ниже `dailyTokenAllowance`, поднимаем до него; если уже не ниже — не меняем (`max`, не +=).
    func syncWithCurrentConfig(config: PaywallConfig? = PaywallCacheManager.shared.paywallConfig, now: Date = Date()) {
        let calculator = GenerationCostCalculator(config: config)
        let today = Self.dayString(from: now, calendar: calendar)

        if !keychain.isTokenWalletInitialized() {
            persist(balance: calculator.startingTokenBalance, refreshDay: today, initialized: true)
            return
        }

        let storedDay = keychain.getTokenLastRefreshDay()
        let storedBalance = keychain.getTokenBalance()

        if storedDay != today {
            let previous = max(0, storedBalance ?? 0)
            let dailyFloor = max(0, calculator.dailyTokenAllowance)
            let newBalance = max(previous, dailyFloor)
            persist(balance: newBalance, refreshDay: today, initialized: true)
            return
        }

        let normalizedBalance = max(0, storedBalance ?? calculator.startingTokenBalance)
        // Уже совпадает с памятью — не трогаем @Published (иначе SwiftUI ругается при чтении из body).
        if lastRefreshDay == today, balance == normalizedBalance {
            return
        }
        persist(balance: normalizedBalance, refreshDay: today, initialized: true)
    }

    /// Только сравнение с текущим опубликованным балансом; без sync — его вызывают debit/init/фоновые хуки.
    func canSpend(_ amount: Int) -> Bool {
        balance >= max(0, amount)
    }

    @discardableResult
    func debit(_ amount: Int) -> Bool {
        syncWithCurrentConfig()
        let normalizedAmount = max(0, amount)
        guard balance >= normalizedAmount else { return false }
        persist(balance: balance - normalizedAmount, refreshDay: lastRefreshDay, initialized: true)
        return true
    }

    func refund(_ amount: Int) {
        addTokens(amount)
    }

    func addTokens(_ amount: Int) {
        syncWithCurrentConfig()
        persist(balance: balance + max(0, amount), refreshDay: lastRefreshDay, initialized: true)
    }

    func resetForDebug() {
        keychain.resetTokenWallet()
        syncWithCurrentConfig()
    }

    private func persist(balance: Int, refreshDay: String, initialized: Bool) {
        let normalizedBalance = max(0, balance)
        keychain.setTokenWalletInitialized(initialized)
        keychain.setTokenBalance(normalizedBalance)
        keychain.setTokenLastRefreshDay(refreshDay)

        if self.balance != normalizedBalance {
            self.balance = normalizedBalance
        }
        if self.lastRefreshDay != refreshDay {
            self.lastRefreshDay = refreshDay
        }
    }

    private static func dayString(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
