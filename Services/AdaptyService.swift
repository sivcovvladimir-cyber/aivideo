import Foundation
import Adapty
import Combine
import StoreKit

// Развёрнутые логи только по цепочке Adapty (getPaywall → getPaywallProducts), чтобы быстрее разбирать noProductIDs/network/proxy кейсы.
enum AdaptyVerboseLog {
    static func printError(tag: String, error: Error) {
        #if DEBUG
        print("🧾 [AdaptyVerbose][\(tag)] \(error)")
        let ns = error as NSError
        print("   NSError domain=\(ns.domain) code=\(ns.code)")
        if !ns.userInfo.isEmpty {
            let pairs = ns.userInfo
                .map { (String(describing: $0.key), $0.value) }
                .sorted { $0.0 < $1.0 }
            print("   userInfo (\(pairs.count) ключей):")
            for (k, v) in pairs {
                print("   • \(k) = \(v)")
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("   underlying: \(underlying.domain) \(underlying.code) — \(underlying.localizedDescription)")
        }
        #endif
    }

    static func printFetchProductsHint(error: Error) {
        #if DEBUG
        let text = String(describing: error)
        if text.contains("noProductIDsFound") {
            let bundleId = Bundle.main.bundleIdentifier ?? "?"
            print("[paywall] Подсказка: paywall из Adapty есть, но StoreKit не сопоставил product id с каталогом. Симулятор: Edit Scheme → Run → Options → StoreKit = AIVideo.storekit в корне репозитория (рядом с .xcodeproj; в .xcscheme от xcschemes: ../../AIVideo.storekit). Устройство: IAP в App Store Connect для bundle \(bundleId) + sandbox; в Adapty колонка App Store status заполнится после связки с ASC.")
            return
        }
        if let urlErr = firstUnderlyingURLError(in: error) {
            switch urlErr.code {
            case NSURLErrorBadURL:
                print("💡 [AdaptyService] Подсказка (сеть): NSURLErrorBadURL (-1000) к fallback.adapty.io часто связан с системным прокси/VPN на Mac. Отключи VPN/прокси и проверь доступность fallback.adapty.io.")
            case NSURLErrorTimedOut:
                print("💡 [AdaptyService] Подсказка (сеть): таймаут до Adapty — проверь интернет, файрвол или блокировки доменов.")
            default:
                print("💡 [AdaptyService] Подсказка (сеть): URLSession к Adapty (NSURLError \(urlErr.code)) — проверь интернет и доступность api.adapty.io / fallback.adapty.io.")
            }
            return
        }
        if text.contains("HTTPError") || (error as NSError).domain == "AdaptyErrorDomain" {
            print("💡 [AdaptyService] Подсказка (Adapty API): это сетевой/API сбой, а не проблема локального StoreKit-конфига.")
        }
        #endif
    }

    private static func firstUnderlyingURLError(in error: Error) -> NSError? {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 10 {
            if ns.domain == NSURLErrorDomain { return ns }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}

@MainActor
class AdaptyService: ObservableObject {
    static let shared = AdaptyService()
    
    @Published var isProUser: Bool = false
    @Published var profile: AdaptyProfile?
    @Published var isLoading: Bool = false
    @Published var error: String?
    
    private var cancellables = Set<AnyCancellable>()

    // Кэш AdaptyPaywall — исключаем дублирование getPaywall между fetchPaywallConfig и fetchProducts.
    // pendingPaywallTask дедуплицирует параллельные вызовы: второй ждёт результата первого.
    // latestPaywallFetchId: устаревший ответ не перезаписывает свежий paywall-кэш.
    private var cachedAdaptyPaywall: AdaptyPaywall?
    private var cachedAdaptyPaywallAt: Date?
    private var pendingPaywallTask: Task<AdaptyPaywall, Error>?
    private var latestPaywallFetchId: UUID?
    private let adaptyPaywallCacheTTL: TimeInterval = 300
    private var currentPlacementTier: PaywallPlacementTier = .standard
    private static let restoreProStickyUntilAdaptySyncKey = "restoreProStickyUntilAdaptySync"
    
    private init() {
        // При включённом Debug PRO восстанавливаем статус из UserDefaults, иначе — из isProUser
        if UserDefaults.standard.bool(forKey: "debug_mode_enabled") && UserDefaults.standard.bool(forKey: "debug_pro_override") {
            isProUser = true
        } else {
            isProUser = UserDefaults.standard.bool(forKey: "isProUser")
        }
        print("🔐 [AdaptyService] Initialized with PRO status: \(isProUser)")
        setupProfileObserver()
        fetchProfile()
    }

    // Единый контракт ошибки, чтобы UI получал понятное сообщение при выключенном Adapty.
    private func adaptyNotConfiguredError() -> NSError {
        NSError(
            domain: "AdaptyService",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Adapty is not configured"]
        )
    }
    
    // MARK: - Profile Management
    
    /// Получить профиль пользователя и обновить статус подписки
    func fetchProfile() {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            isLoading = false
            #if DEBUG
            print("ℹ️ [AdaptyService] fetchProfile skipped: ADAPTY_PUBLIC_KEY not configured")
            #endif
            return
        }
        isLoading = true
        error = nil
        
        Adapty.getProfile { [weak self] result in
            Task { @MainActor in
                self?.isLoading = false
                
                switch result {
                case .success(let profile):
                    self?.profile = profile
                    self?.updateProStatus(from: profile)

                    
                case .failure(let error):
                    self?.error = error.localizedDescription
                    print("🚨 [AdaptyService] Ошибка получения профиля: \(error)")
                }
            }
        }
    }
    
    /// Единая проверка PRO по профилю Adapty: активный `premium` access level, активная подписка или non-consumable покупка.
    private func profileIndicatesProAccess(_ profile: AdaptyProfile) -> Bool {
        if profile.accessLevels["premium"]?.isActive == true { return true }
        if profile.subscriptions.values.contains(where: { $0.isActive && !$0.isRefund }) { return true }
        return profile.nonSubscriptions.values.flatMap { $0 }.contains { !$0.isRefund && !$0.isConsumable }
    }

    /// Проверяет, что именно купленный `vendorProductId` уже отражён в профиле.
    private func purchaseReflectsInProfile(_ profile: AdaptyProfile, vendorProductId: String) -> Bool {
        if profile.accessLevels["premium"]?.isActive == true { return true }
        if let sub = profile.subscriptions[vendorProductId], sub.isActive, !sub.isRefund { return true }
        if let nonSubs = profile.nonSubscriptions[vendorProductId], nonSubs.contains(where: { !$0.isRefund }) { return true }
        for (_, level) in profile.accessLevels where level.isActive && !level.isRefund && level.vendorProductId == vendorProductId {
            return true
        }
        return false
    }

    /// Обновить статус PRO пользователя на основе профиля. В Debug-режиме при включённом «PRO» перезапись не делаем.
    private func updateProStatus(from profile: AdaptyProfile) {
        if UserDefaults.standard.bool(forKey: "debug_mode_enabled") && UserDefaults.standard.bool(forKey: "debug_pro_override") {
            self.isProUser = true
            UserDefaults.standard.set(true, forKey: "isProUser")
            return
        }
        if profileIndicatesProAccess(profile) {
            UserDefaults.standard.removeObject(forKey: Self.restoreProStickyUntilAdaptySyncKey)
        } else if UserDefaults.standard.bool(forKey: Self.restoreProStickyUntilAdaptySyncKey), self.isProUser {
            // После restore можем временно держать локальный PRO, пока серверный профиль Adapty догоняет транзакцию.
            return
        }
        let unlocked = profileIndicatesProAccess(profile)
        self.isProUser = unlocked
        UserDefaults.standard.set(unlocked, forKey: "isProUser")
        print("🔐 [AdaptyService] PRO status updated: \(unlocked)")
    }
    
    /// Настроить наблюдатель за изменениями профиля
    private func setupProfileObserver() {
        // Adapty автоматически уведомляет о изменениях профиля
        // Мы можем подписаться на эти изменения
    }
    
    // MARK: - Products & Purchases

    /// Получить доступные продукты.
    /// `forceRefresh=true` принудительно запрашивает paywall из сети (revalidate), чтобы обновить stale кэш Adapty.
    func fetchProducts(forceRefresh: Bool = false, completion: @escaping (Result<[AdaptyPaywallProduct], Error>) -> Void) {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            completion(.failure(adaptyNotConfiguredError()))
            return
        }
        Task { @MainActor in
            do {
                let placementForLog = (try? PaywallCacheManager.shared.configuredAdaptyPlacementId()) ?? "?"
                print("[paywall] AdaptyService.fetchProducts: placementId=\(placementForLog) tier=\(currentPlacementTier.rawValue) forceRefresh=\(forceRefresh)")
                let paywall = try await fetchAdaptyPaywallAsync(forceRefresh: forceRefresh)
                print("[paywall] AdaptyService.fetchProducts: paywall placement.id=\(paywall.placement.id) revision=\(paywall.placement.revision) name=\(paywall.name)")
                // Как в storecards: на paywall в дашборде висят эти id; StoreKit отдаёт только те, что есть в каталоге (ASC или локальный .storekit в схеме Run).
                print("[paywall] AdaptyService.fetchProducts: paywall.vendorProductIds=\(paywall.vendorProductIds) → getPaywallProducts…")
                let products = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[AdaptyPaywallProduct], Error>) in
                    Adapty.getPaywallProducts(paywall: paywall) { cont.resume(with: $0) }
                }
                let ids = products.map(\.vendorProductId)
                print("[paywall] AdaptyService.fetchProducts: OK count=\(products.count) resolvedIds=\(ids)")
                if paywall.vendorProductIds.count != products.count {
                    let resolved = Set(products.map(\.vendorProductId))
                    let missing = paywall.vendorProductIds.filter { !resolved.contains($0) }
                    print("[paywall] AdaptyService.fetchProducts: на paywall \(paywall.vendorProductIds.count) id, StoreKit вернул \(products.count) — не загрузились: \(missing)")
                }
                completion(.success(products))
            } catch {
                print("🚨 [AdaptyService] Ошибка получения продуктов: \(error)")
                print("[paywall] AdaptyService.fetchProducts: ошибка \(error)")
                AdaptyVerboseLog.printError(tag: "fetchProducts", error: error)
                AdaptyVerboseLog.printFetchProductsHint(error: error)
                completion(.failure(error))
            }
        }
    }
    
    /// Получить доступные продукты (async версия)
    func fetchProductsAsync(forceRefresh: Bool = false) async throws -> [AdaptyPaywallProduct] {
        return try await withCheckedThrowingContinuation { continuation in
            fetchProducts(forceRefresh: forceRefresh) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Несколько попыток getProfile после покупки: серверный профиль Adapty может отставать сразу после успешной транзакции.
    private func refreshProfileAfterPurchase(
        product: AdaptyPaywallProduct,
        attemptIndex: Int,
        completion: @escaping (Result<AdaptyProfile, Error>) -> Void
    ) {
        let maxAttempts = 3
        Adapty.getProfile { [weak self] profileResult in
            Task { @MainActor in
                guard let self = self else { return }
                switch profileResult {
                case .success(let profile):
                    self.profile = profile
                    self.updateProStatus(from: profile)

                    if self.purchaseReflectsInProfile(profile, vendorProductId: product.vendorProductId) {
                        Task {
                            await AppAnalyticsService.shared.reportSubscriptionStarted(
                                productId: product.vendorProductId,
                                productName: product.localizedTitle,
                                price: Double(truncating: product.price as NSNumber),
                                currency: product.currencyCode ?? "USD"
                            )
                        }
                        completion(.success(profile))
                        return
                    }

                    if attemptIndex + 1 < maxAttempts {
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            await MainActor.run {
                                self.refreshProfileAfterPurchase(product: product, attemptIndex: attemptIndex + 1, completion: completion)
                            }
                        }
                        return
                    }

                    let isNonRenewingStoreProduct = product.subscriptionPeriod == nil
                    if isNonRenewingStoreProduct {
                        print("⚠️ [AdaptyService] Транзакция прошла, профиль не показал premium по \(maxAttempts) попыткам — локально подтверждаем PRO для \(product.vendorProductId)")
                        self.isProUser = true
                        UserDefaults.standard.set(true, forKey: "isProUser")
                        Task {
                            await AppAnalyticsService.shared.reportSubscriptionStarted(
                                productId: product.vendorProductId,
                                productName: product.localizedTitle,
                                price: Double(truncating: product.price as NSNumber),
                                currency: product.currencyCode ?? "USD"
                            )
                        }
                        completion(.success(profile))
                        return
                    }

                    let syncError = NSError(
                        domain: "AdaptyService",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "Purchase completed but premium access is not yet confirmed in profile."]
                    )
                    completion(.failure(syncError))

                case .failure(let error):
                    self.error = error.localizedDescription
                    print("🚨 [AdaptyService] Ошибка получения профиля после покупки: \(error)")
                    completion(.failure(error))
                }
            }
        }
    }

    /// Совершить покупку
    func makePurchase(product: AdaptyPaywallProduct, completion: @escaping (Result<AdaptyProfile, Error>) -> Void) {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            completion(.failure(adaptyNotConfiguredError()))
            return
        }
        isLoading = true
        error = nil
        print("[paywall] AdaptyService.makePurchase: vendorProductId=\(product.vendorProductId) title=\(product.localizedTitle)")

        // Отмена платежного листа приходит как success.userCancelled, а не как failure.
        Adapty.makePurchase(product: product) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false

                switch result {
                case .success(let purchaseResult):
                    switch purchaseResult {
                    case .userCancelled:
                        let cancelError = NSError(
                            domain: "AdaptyService",
                            code: 1001,
                            userInfo: [NSLocalizedDescriptionKey: "Purchase was cancelled by user"]
                        )
                        completion(.failure(cancelError))
                        return
                    case .pending:
                        let pendingError = NSError(
                            domain: "AdaptyService",
                            code: 1004,
                            userInfo: [NSLocalizedDescriptionKey: "Purchase is pending confirmation"]
                        )
                        completion(.failure(pendingError))
                        return
                    case .success(let profile, _):
                        self.invalidatePaywallCache()
                        self.profile = profile
                        self.updateProStatus(from: profile)

                        if self.purchaseReflectsInProfile(profile, vendorProductId: product.vendorProductId) {
                            Task {
                                await AppAnalyticsService.shared.reportSubscriptionStarted(
                                    productId: product.vendorProductId,
                                    productName: product.localizedTitle,
                                    price: Double(truncating: product.price as NSNumber),
                                    currency: product.currencyCode ?? "USD"
                                )
                            }
                            completion(.success(profile))
                        } else {
                            self.refreshProfileAfterPurchase(product: product, attemptIndex: 0, completion: completion)
                        }
                    }
                case .failure(let error):
                    self.error = error.localizedDescription
                    print("🚨 [AdaptyService] Ошибка покупки: \(error)")
                    print("[paywall] AdaptyService.makePurchase: failure \(error)")
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Восстановить покупки. expectedProductIds нужен как fallback-подтверждение через StoreKit entitlements, если профиль Adapty отстаёт.
    func restorePurchases(expectedProductIds: Set<String>? = nil, completion: @escaping (Result<AdaptyProfile, Error>) -> Void) {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            completion(.failure(adaptyNotConfiguredError()))
            return
        }
        isLoading = true
        error = nil
        print("[paywall] AdaptyService.restorePurchases: старт")

        Adapty.restorePurchases { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                // После восстановления сбрасываем кэш — данные о подписке изменились
                self.invalidatePaywallCache()
                
                switch result {
                case .success(let profile):
                    self.profile = profile
                    self.updateProStatus(from: profile)
                    if self.profileIndicatesProAccess(profile) {
                        print("[paywall] AdaptyService.restorePurchases: success premiumActive=true")
                        completion(.success(profile))
                    } else {
                        self.refreshProfileAfterRestore(
                            attemptIndex: 0,
                            expectedProductIds: expectedProductIds,
                            completion: completion
                        )
                    }
                    
                case .failure(let error):
                    self.error = error.localizedDescription
                    print("🚨 [AdaptyService] Ошибка восстановления: \(error)")
                    print("[paywall] AdaptyService.restorePurchases: failure \(error)")
                    completion(.failure(error))
                }
            }
        }
    }

    private func refreshProfileAfterRestore(
        attemptIndex: Int,
        expectedProductIds: Set<String>?,
        completion: @escaping (Result<AdaptyProfile, Error>) -> Void
    ) {
        let maxAttempts = 3
        Adapty.getProfile { [weak self] profileResult in
            Task { @MainActor in
                guard let self = self else { return }
                switch profileResult {
                case .success(let profile):
                    self.profile = profile
                    self.updateProStatus(from: profile)
                    if self.profileIndicatesProAccess(profile) {
                        completion(.success(profile))
                        return
                    }
                    if attemptIndex + 1 < maxAttempts {
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            await MainActor.run {
                                self.refreshProfileAfterRestore(
                                    attemptIndex: attemptIndex + 1,
                                    expectedProductIds: expectedProductIds,
                                    completion: completion
                                )
                            }
                        }
                    } else {
                        Task { @MainActor in
                            let granted = await self.grantProIfStoreKitOwnsLifetime(
                                expectedProductIds: expectedProductIds,
                                fallbackProfile: profile
                            )
                            if granted {
                                completion(.success(self.profile ?? profile))
                            } else {
                                let err = NSError(
                                    domain: "AdaptyService",
                                    code: 1005,
                                    userInfo: [NSLocalizedDescriptionKey: "Could not confirm restored purchase in profile"]
                                )
                                completion(.failure(err))
                            }
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    @MainActor
    private func grantProIfStoreKitOwnsLifetime(expectedProductIds: Set<String>?, fallbackProfile: AdaptyProfile) async -> Bool {
        guard let ids = expectedProductIds, !ids.isEmpty else { return false }
        let owns = await Self.storeKitOwnsAnyTransaction(of: ids)
        if owns {
            UserDefaults.standard.set(true, forKey: Self.restoreProStickyUntilAdaptySyncKey)
            self.isProUser = true
            UserDefaults.standard.set(true, forKey: "isProUser")
            self.profile = fallbackProfile
            print("ℹ️ [AdaptyService] Restore: StoreKit entitlements подтверждают покупку, удерживаем локальный PRO до синхронизации Adapty.")
            return true
        }
        return false
    }

    private static func storeKitOwnsAnyTransaction(of productIds: Set<String>) async -> Bool {
        guard !productIds.isEmpty else { return false }
        if #available(iOS 15.0, *) {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, productIds.contains(transaction.productID) {
                    return true
                }
            }
        }
        return false
    }
    
    // MARK: - Paywall Management

    func setPaywallPlacementTier(_ tier: PaywallPlacementTier) {
        guard currentPlacementTier != tier else { return }
        let placementId = try? paywallPlacementId()
        currentPlacementTier = tier
        // Один placement в конфиге: смена tier только меняет UI пейволла, кэш Adapty по placement не инвалидируем.
        print("[paywall] AdaptyService.setPaywallPlacementTier: \(tier.rawValue) placementId=\(String(describing: placementId)) (единый)")
    }
    
    /// Получить paywall с продуктами
    func fetchPaywall(forceRefresh: Bool = false, completion: @escaping (Result<AdaptyPaywall, Error>) -> Void) {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            completion(.failure(adaptyNotConfiguredError()))
            return
        }
        Task { @MainActor in
            do {
                let paywall = try await fetchAdaptyPaywallAsync(forceRefresh: forceRefresh)
                print("✅ [AdaptyService] Paywall получен успешно")
                completion(.success(paywall))
            } catch {
                print("🚨 [AdaptyService] Ошибка получения paywall: \(error)")
                completion(.failure(error))
            }
        }
    }
    

    
    // MARK: - Utility Methods
    
    /// Проверить, есть ли активная подписка
    func hasActiveSubscription() -> Bool {
        guard let profile else { return false }
        return profileIndicatesProAccess(profile)
    }

    /// vendorProductId активной подписки (например "premium_weekly", "premium_annual")
    nonisolated var currentSubscriptionProductId: String? {
        // profile — @Published, его нужно читать на главном акторе,
        // поэтому берём значение синхронно из хранилища через MainActor.assumeIsolated
        // если вызов уже на главном потоке; иначе возвращаем nil.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { profile?.accessLevels["premium"]?.vendorProductId }
        }
        return nil
    }
    
    /// Получить информацию о подписке
    func getSubscriptionInfo() -> (isActive: Bool, expiresAt: Date?, productId: String?) {
        // isActive считаем единообразно (premium/subscriptions/nonSubscriptions), даже если premium access level отсутствует.
        let isActiveByProfile = profile.map(profileIndicatesProAccess) ?? false
        guard let premiumAccess = profile?.accessLevels["premium"] else {
            return (isActiveByProfile, nil, nil)
        }
        
        return (
            isActive: isActiveByProfile,
            expiresAt: premiumAccess.expiresAt,
            productId: premiumAccess.vendorProductId
        )
    }
    
    /// Очистить ошибку
    func clearError() {
        error = nil
    }
    
    // MARK: - Paywall Configuration
    
    /// Получить конфигурацию paywall из Adapty.
    /// `forceRefresh=true` полезен вторым этапом, когда нужно подтянуть свежий remoteConfig после мгновенного cache-first UI.
    func fetchPaywallConfig(forceRefresh: Bool = false, completion: @escaping (Result<PaywallConfig, Error>) -> Void) {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            completion(.failure(adaptyNotConfiguredError()))
            return
        }
        Task { @MainActor in
            do {
                let paywall = try await fetchAdaptyPaywallAsync(forceRefresh: forceRefresh)
                if let remoteConfig = paywall.remoteConfig,
                   let jsonData = remoteConfig.jsonString.data(using: .utf8) {
                    print("[paywall] fetchPaywallConfig: remoteConfig присутствует bytes=\(jsonData.count)")
                    // После decode подмешиваем `logic.generationLimits` из сырого JSON (корень и/или вложенный `logic`): смешанные типы в панелях Adapty.
                    let decoded: PaywallConfig
                    do {
                        decoded = try JSONDecoder().decode(PaywallConfig.self, from: jsonData)
                        print("✅ [AdaptyService] Полная paywall конфигурация загружена")
                        print("[paywall] fetchPaywallConfig: полный JSON decode OK")
                    } catch {
                        print("⚠️ [AdaptyService] Ошибка парсинга полной конфигурации: \(error)")
                        print("[paywall] fetchPaywallConfig: полный decode fail, пробуем partial: \(error)")
                        do {
                            decoded = try self.parsePartialConfig(from: jsonData)
                            print("✅ [AdaptyService] Частичная paywall конфигурация загружена")
                            print("[paywall] fetchPaywallConfig: partial OK")
                        } catch {
                            print("🚨 [AdaptyService] Ошибка парсинга частичной конфигурации: \(error)")
                            print("[paywall] fetchPaywallConfig: partial fail → empty remote overlay")
                            decoded = PaywallConfig(
                                planIds: nil,
                                purchasePlanIds: nil,
                                trialsPlanIds: nil,
                                adapty: nil,
                                logic: .init()
                            )
                        }
                    }
                    let withLimits = self.mergingGenerationLimitsFromRawJSON(decoded, jsonData: jsonData)
                    completion(.success(withLimits))
                } else {
                    print("⚠️ [AdaptyService] Remote config не найден, используем дефолт")
                    print("[paywall] fetchPaywallConfig: remoteConfig пуст → empty remote overlay")
                    completion(.success(PaywallConfig(
                        planIds: nil,
                        purchasePlanIds: nil,
                        trialsPlanIds: nil,
                        adapty: nil,
                        logic: .init()
                    )))
                }
            } catch {
                print("🚨 [AdaptyService] Ошибка получения paywall для конфигурации: \(error)")
                print("[paywall] fetchPaywallConfig: getPaywall ошибка → empty remote overlay: \(error)")
                completion(.success(PaywallConfig(
                    planIds: nil,
                    purchasePlanIds: nil,
                    trialsPlanIds: nil,
                    adapty: nil,
                    logic: .init()
                )))
            }
        }
    }
    
    /// Получить конфигурацию paywall из Adapty (async версия)
    func fetchPaywallConfigAsync(forceRefresh: Bool = false) async throws -> PaywallConfig {
        return try await withCheckedThrowingContinuation { continuation in
            fetchPaywallConfig(forceRefresh: forceRefresh) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    // MARK: - Adapty Paywall Fetching

    /// Единая точка получения AdaptyPaywall.
    /// Зачем: на первом шаге нужен мгновенный cache-first ответ, но затем важно дожать свежие данные из сети.
    /// Что делает: при `forceRefresh=false` использует локальный кэш/дедупликацию, при `true` — revalidate policy и отдельный запрос.
    private func fetchAdaptyPaywallAsync(forceRefresh: Bool = false) async throws -> AdaptyPaywall {
        guard ConfigurationManager.shared.isAdaptyConfigured else {
            throw adaptyNotConfiguredError()
        }
        if !forceRefresh, let cached = cachedAdaptyPaywall, let at = cachedAdaptyPaywallAt,
           Date().timeIntervalSince(at) < adaptyPaywallCacheTTL {
            let pid = (try? paywallPlacementId()) ?? "?"
            print("[paywall] fetchAdaptyPaywallAsync: cache hit TTL placementId=\(pid) paywall.placement.id=\(cached.placement.id) revision=\(cached.placement.revision)")
            return cached
        }
        if !forceRefresh, let existing = pendingPaywallTask {
            print("[paywall] fetchAdaptyPaywallAsync: await pending shared task")
            return try await existing.value
        }
        let placementId = try paywallPlacementId()
        let fetchId = UUID()
        latestPaywallFetchId = fetchId
        print("[paywall] fetchAdaptyPaywallAsync: Adapty.getPaywall placementId=\(placementId) tier=\(currentPlacementTier.rawValue) forceRefresh=\(forceRefresh) fetchId=\(fetchId.uuidString.prefix(8))")
        let loadTimeout: TimeInterval = forceRefresh ? 5 : 3
        let task = Task<AdaptyPaywall, Error> {
            try await withCheckedThrowingContinuation { cont in
                Adapty.getPaywall(
                    placementId: placementId,
                    fetchPolicy: forceRefresh ? .reloadRevalidatingCacheData : .returnCacheDataElseLoad,
                    loadTimeout: loadTimeout
                ) { cont.resume(with: $0) }
            }
        }
        pendingPaywallTask = task
        do {
            let paywall = try await task.value
            if latestPaywallFetchId == fetchId {
                pendingPaywallTask = nil
                cachedAdaptyPaywall = paywall
                cachedAdaptyPaywallAt = Date()
            }
            if latestPaywallFetchId != fetchId {
                print("[paywall] fetchAdaptyPaywallAsync: stale response fetchId=\(fetchId.uuidString.prefix(8)) — cache not updated")
            }
            print("[paywall] fetchAdaptyPaywallAsync: OK placement.id=\(paywall.placement.id) revision=\(paywall.placement.revision) hasRemoteConfig=\(paywall.remoteConfig != nil)")
            return paywall
        } catch {
            if latestPaywallFetchId == fetchId {
                pendingPaywallTask = nil
            }
            print("[paywall] fetchAdaptyPaywallAsync: error \(error)")
            AdaptyVerboseLog.printError(tag: "getPaywall placement=\(placementId)", error: error)
            throw error
        }
    }

    /// Сбросить кэш paywall-объекта (вызывается после покупки или восстановления).
    func invalidatePaywallCache() {
        print("[paywall] AdaptyService.invalidatePaywallCache")
        latestPaywallFetchId = UUID()
        cachedAdaptyPaywall = nil
        cachedAdaptyPaywallAt = nil
        pendingPaywallTask?.cancel()
        pendingPaywallTask = nil
    }

    private func paywallPlacementId() throws -> String {
        try PaywallCacheManager.shared.configuredAdaptyPlacementId()
    }

    // MARK: - Partial Configuration Parsing
    
    /// Парсит generationLimits из JSON: Int/Double/NSNumber и строки с целым числом (часто так сериализует Adapty/панели).
    private func parseGenerationLimits(from value: Any?) -> [String: Int]? {
        guard let dict = value as? [String: Any], !dict.isEmpty else { return nil }
        var result: [String: Int] = [:]
        for (key, val) in dict {
            if let n = val as? Int { result[key] = n }
            else if let n = val as? Double { result[key] = Int(n) }
            else if let n = val as? NSNumber { result[key] = n.intValue }
            else if let s = val as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let n = Int(t) { result[key] = n }
            }
            else { continue }
        }
        return result.isEmpty ? nil : result
    }

    /// Накладывает `generationLimits` из сырого JSON (ключи `generationLimits` в корне и/или внутри `logic`) поверх decode.
    private func mergingGenerationLimitsFromRawJSON(_ config: PaywallConfig, jsonData: Data) -> PaywallConfig {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return config }

        let fromRoot = parseGenerationLimits(from: root["generationLimits"])
        let logicObj = root["logic"] as? [String: Any]
        let fromNestedLogic = parseGenerationLimits(from: logicObj?["generationLimits"])

        let parsed: [String: Int]? = {
            switch (fromRoot, fromNestedLogic) {
            case (nil, nil): return nil
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (let a?, let b?): return a.merging(b) { _, nested in nested }
            }
        }()
        guard let parsed, !parsed.isEmpty else { return config }

        let newLogic = config.logic.mergingGenerationLimitsOverlay(parsed)
        if newLogic.generationLimits != config.logic.generationLimits {
            print("[paywall] fetchPaywallConfig: logic.generationLimits overlay из raw JSON keys=\(parsed.keys.sorted())")
        }
        return PaywallConfig(
            planIds: config.planIds,
            purchasePlanIds: config.purchasePlanIds,
            trialsPlanIds: config.trialsPlanIds,
            adapty: config.adapty,
            logic: newLogic
        )
    }
    
    /// Парсить частичную конфигурацию и объединить с дефолтной
    private func parsePartialConfig(from jsonData: Data) throws -> PaywallConfig {
        // Парсим JSON как словарь
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "AdaptyService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format"])
        }
        
        // Извлекаем только поддерживаемые поля локального конфига.
        let planIds = json["planIds"] as? [String]
        let purchasePlanIds = json["purchasePlanIds"] as? [String]
        let adaptyCatalog: PaywallAdaptyCatalog? = {
            guard let obj = json["adapty"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj)
            else { return nil }
            return try? JSONDecoder().decode(PaywallAdaptyCatalog.self, from: data)
        }()
        
        print("🔍 [AdaptyService] parsePartialConfig:")
        print("  - planIds: \(String(describing: planIds))")

        // Парсим Logic конфигурацию; лимиты по продуктам — только в `logic` (корневой `generationLimits` при необходимости подмешиваем).
        var logicConfig = parseLogicConfig(from: json["logic"] as? [String: Any])
        if let rootGL = parseGenerationLimits(from: json["generationLimits"]), !rootGL.isEmpty {
            logicConfig = logicConfig.mergingGenerationLimitsOverlay(rootGL)
        }
        
        print("🔍 [AdaptyService] parsePartialConfig - logicConfig: \(String(describing: logicConfig))")
        
        return PaywallConfig(
            planIds: planIds,
            purchasePlanIds: purchasePlanIds,
            trialsPlanIds: nil,
            adapty: adaptyCatalog,
            logic: logicConfig
        )
    }
    
    /// Универсальная функция для парсинга Boolean значений из JSON
    private func parseBooleanValue(from json: [String: Any], key: String) -> Bool? {
        let value = json[key]
        
        if let boolValue = value as? Bool { return boolValue }
        if let intValue = value as? Int { return intValue != 0 }
        if let numberValue = value as? NSNumber { return numberValue.intValue != 0 }
        if let doubleValue = value as? Double { return doubleValue != 0 }
        if let stringValue = value as? String {
            // Поддержка кейсов "0"/"1"/"true"/"false" на случай нестандартного формата remote config.
            let s = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == "true" || s == "1" { return true }
            if s == "false" || s == "0" { return false }
        }
        
        return nil
    }
    
    /// Парсить Logic конфигурацию из частичного JSON
    private func parseLogicConfig(from json: [String: Any]?) -> PaywallConfig.LogicConfig {
        // Если в remote payload нет `logic`, возвращаем overlay-объект с nil в optional полях:
        // это позволяет merge сохранить локальные bundled-значения вместо перезаписи дефолтами.
        guard let json else {
            return PaywallConfig.LogicConfig()
        }
        
        let startingTokenBalance = parseIntValue(from: json, keys: ["startingTokenBalance", "starting_token_balance"])
        let dailyTokenAllowance = parseIntValue(from: json, keys: ["dailyTokenAllowance", "daily_token_allowance"])
        let tokensPerEffectGeneration = parseIntValue(from: json, keys: ["tokensPerEffectGeneration", "tokens_per_effect_generation"])
        let promptVideoTokensPerSecond = parseIntValue(from: json, keys: ["promptVideoTokensPerSecond", "prompt_video_tokens_per_second"])
        let promptVideoAudioAddonTokens = parseIntValue(from: json, keys: ["promptVideoAudioAddonTokens", "prompt_video_audio_addon_tokens"])
        let promptPhotoGenerationTokens = parseIntValue(from: json, keys: ["promptPhotoGenerationTokens", "prompt_photo_generation_tokens"])
        let showRatingAfterGenerations: [Int]? = {
            guard let raw = json["showRatingAfterGenerations"] as? [Any], !raw.isEmpty else { return nil }
            let arr = raw.compactMap { $0 as? Int }
            return arr.isEmpty ? nil : arr
        }()

        // Парсим Boolean параметры - могут прийти как Bool или как Int (0/1)
        let showPaywallAfterOnboarding = parseBooleanValue(from: json, key: "showPaywallAfterOnboarding")
        let effectsCatalogAllowsMotionPreview =
            parseBooleanValue(from: json, key: "effectsCatalogAllowsMotionPreview")
            ?? parseBooleanValue(from: json, key: "effects_catalog_allows_motion_preview")
        let effectsCatalogShowPosterBeforeMotion =
            parseBooleanValue(from: json, key: "effectsCatalogShowPosterBeforeMotion")
            ?? parseBooleanValue(from: json, key: "effects_catalog_show_poster_before_motion")
        let generationLimits = parseGenerationLimits(from: json["generationLimits"])
        
        print("🔍 [AdaptyService] parseLogicConfig:")
        print("  - showPaywallAfterOnboarding: \(String(describing: showPaywallAfterOnboarding))")
        print("  - effectsCatalogAllowsMotionPreview: \(String(describing: effectsCatalogAllowsMotionPreview))")
        print("  - effectsCatalogShowPosterBeforeMotion: \(String(describing: effectsCatalogShowPosterBeforeMotion))")
        print("  - token defaults: start=\(String(describing: startingTokenBalance)), daily=\(String(describing: dailyTokenAllowance)), effect=\(String(describing: tokensPerEffectGeneration)), videoSec=\(String(describing: promptVideoTokensPerSecond)), audio=\(String(describing: promptVideoAudioAddonTokens)), photo=\(String(describing: promptPhotoGenerationTokens))")
        print("  - весь JSON logic: \(String(describing: json))")
        
        return PaywallConfig.LogicConfig(
            showRatingAfterGenerations: showRatingAfterGenerations,
            showPaywallAfterOnboarding: showPaywallAfterOnboarding,
            generationLimits: generationLimits,
            effectsCatalogAllowsMotionPreview: effectsCatalogAllowsMotionPreview,
            effectsCatalogShowPosterBeforeMotion: effectsCatalogShowPosterBeforeMotion,
            startingTokenBalance: startingTokenBalance,
            dailyTokenAllowance: dailyTokenAllowance,
            tokensPerEffectGeneration: tokensPerEffectGeneration,
            promptVideoTokensPerSecond: promptVideoTokensPerSecond,
            promptVideoAudioAddonTokens: promptVideoAudioAddonTokens,
            promptPhotoGenerationTokens: promptPhotoGenerationTokens
        )
    }

    private func parseIntValue(from json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            let value = json[key]
            if let intValue = value as? Int { return intValue }
            if let numberValue = value as? NSNumber { return numberValue.intValue }
            if let doubleValue = value as? Double { return Int(doubleValue) }
            if let stringValue = value as? String, let parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

 