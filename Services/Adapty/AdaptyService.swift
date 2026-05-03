import Foundation
import Adapty
import Combine

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
    private var cachedAdaptyPaywall: AdaptyPaywall?
    private var cachedAdaptyPaywallAt: Date?
    private var pendingPaywallTask: Task<AdaptyPaywall, Error>?
    private let adaptyPaywallCacheTTL: TimeInterval = 300
    private var currentPlacementTier: PaywallPlacementTier = .standard
    
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
    
    // MARK: - Profile Management
    
    /// Получить профиль пользователя и обновить статус подписки
    func fetchProfile() {
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
    
    /// Обновить статус PRO пользователя на основе профиля. В Debug-режиме при включённом «PRO» перезапись не делаем.
    private func updateProStatus(from profile: AdaptyProfile) {
        if UserDefaults.standard.bool(forKey: "debug_mode_enabled") && UserDefaults.standard.bool(forKey: "debug_pro_override") {
            self.isProUser = true
            UserDefaults.standard.set(true, forKey: "isProUser")
            return
        }
        let hasActiveSubscription = profile.accessLevels["premium"]?.isActive == true
        self.isProUser = hasActiveSubscription
        UserDefaults.standard.set(hasActiveSubscription, forKey: "isProUser")
        print("🔐 [AdaptyService] PRO status updated: \(hasActiveSubscription)")
    }
    
    /// Настроить наблюдатель за изменениями профиля
    private func setupProfileObserver() {
        // Adapty автоматически уведомляет о изменениях профиля
        // Мы можем подписаться на эти изменения
    }
    
    // MARK: - Products & Purchases

    /// Подсказки по ошибке getPaywallProducts (аналог `AdaptyVerboseLog.printFetchProductsHint` в storecards).
    private static func printFetchProductsHint(for error: Error) {
        #if DEBUG
        let text = String(describing: error)
        if text.contains("noProductIDsFound") {
            let bundleId = Bundle.main.bundleIdentifier ?? "?"
            print("[paywall] Подсказка: paywall из Adapty есть, но StoreKit не сопоставил product id с каталогом. Симулятор: Edit Scheme → Run → Options → StoreKit = AIVideo.storekit в корне репозитория (рядом с .xcodeproj; в .xcscheme от xcschemes: ../../AIVideo.storekit). Устройство: IAP в App Store Connect для bundle \(bundleId) + sandbox; в Adapty колонка App Store status заполнится после связки с ASC.")
            return
        }
        if (error as NSError).domain == NSURLErrorDomain {
            print("[paywall] Подсказка: NSURLError при запросе к Adapty/сети — не то же самое, что пустой .storekit; проверь интернет и VPN/прокси.")
        }
        #endif
    }
    
    /// Получить доступные продукты
    func fetchProducts(completion: @escaping (Result<[AdaptyPaywallProduct], Error>) -> Void) {
        Task { @MainActor in
            do {
                let placementForLog = (try? PaywallCacheManager.shared.configuredAdaptyPlacementId()) ?? "?"
                print("[paywall] AdaptyService.fetchProducts: placementId=\(placementForLog) tier=\(currentPlacementTier.rawValue)")
                let paywall = try await fetchAdaptyPaywallAsync()
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
                Self.printFetchProductsHint(for: error)
                completion(.failure(error))
            }
        }
    }
    
    /// Получить доступные продукты (async версия)
    func fetchProductsAsync() async throws -> [AdaptyPaywallProduct] {
        return try await withCheckedThrowingContinuation { continuation in
            fetchProducts { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Совершить покупку
    func makePurchase(product: AdaptyPaywallProduct, completion: @escaping (Result<AdaptyProfile, Error>) -> Void) {
        isLoading = true
        error = nil
        print("[paywall] AdaptyService.makePurchase: vendorProductId=\(product.vendorProductId) title=\(product.localizedTitle)")

        Adapty.makePurchase(product: product) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                // После покупки сбрасываем кэш paywall — нужно обновить список продуктов и конфиг
                self.invalidatePaywallCache()
                
                switch result {
                case .success(_):
                    // После покупки получаем обновленный профиль
                    Adapty.getProfile { [weak self] profileResult in
                        Task { @MainActor in
                            guard let self = self else { return }
                            switch profileResult {
                case .success(let profile):
                                self.profile = profile
                                self.updateProStatus(from: profile)
                                
                                // Проверяем, действительно ли пользователь стал PRO
                                let hasActiveSubscription = profile.accessLevels["premium"]?.isActive == true
                                if hasActiveSubscription {
                                    print("[paywall] AdaptyService.makePurchase: успех, premium активен")
                                    // Report subscription started event
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
                                    print("⚠️ [AdaptyService] Покупка отменена пользователем: \(product.vendorProductId)")
                                    print("[paywall] AdaptyService.makePurchase: профиль без активного premium (считаем отменой)")
                                    // Создаем кастомную ошибку для отмены
                                    let cancelError = NSError(domain: "AdaptyService", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Purchase was cancelled by user"])
                                    completion(.failure(cancelError))
                                }
                                
                            case .failure(let error):
                                self.error = error.localizedDescription
                                print("🚨 [AdaptyService] Ошибка получения профиля: \(error)")
                                completion(.failure(error))
                            }
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
    
    /// Восстановить покупки
    func restorePurchases(completion: @escaping (Result<AdaptyProfile, Error>) -> Void) {
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
                    
                    // Проверяем, есть ли активная подписка после восстановления
                    let active = profile.accessLevels["premium"]?.isActive == true
                    print("[paywall] AdaptyService.restorePurchases: success premiumActive=\(active)")
                    completion(.success(profile))
                    
                case .failure(let error):
                    self.error = error.localizedDescription
                    print("🚨 [AdaptyService] Ошибка восстановления: \(error)")
                    print("[paywall] AdaptyService.restorePurchases: failure \(error)")
                    completion(.failure(error))
                }
            }
        }
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
    func fetchPaywall(paywallId: String? = nil, completion: @escaping (Result<AdaptyPaywall, Error>) -> Void) {
        Task { @MainActor in
            do {
                let paywall = try await fetchAdaptyPaywallAsync()
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
        return profile?.accessLevels["premium"]?.isActive == true
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
        guard let premiumAccess = profile?.accessLevels["premium"] else {
            return (false, nil, nil)
        }
        
        return (
            isActive: premiumAccess.isActive,
            expiresAt: premiumAccess.expiresAt,
            productId: premiumAccess.vendorProductId
        )
    }
    
    /// Очистить ошибку
    func clearError() {
        error = nil
    }
    
    // MARK: - Paywall Configuration
    
    /// Получить конфигурацию paywall из Adapty
    func fetchPaywallConfig(completion: @escaping (Result<PaywallConfig, Error>) -> Void) {
        Task { @MainActor in
            do {
                let paywall = try await fetchAdaptyPaywallAsync()
                if let remoteConfig = paywall.remoteConfig,
                   let jsonData = remoteConfig.jsonString.data(using: .utf8) {
                    print("[paywall] fetchPaywallConfig: remoteConfig присутствует bytes=\(jsonData.count)")
                    // Сначала decode (полный или partial), затем всегда подмешиваем `generationLimits` из сырого JSON:
                    // Adapty/редакторы иногда отдают числа как строки или смешанные типы — строгий Codable тогда роняет весь decode
                    // или даёт пустой словарь; без этого remote не перекрывает bundled `generationLimits` в mergeConfigs.
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
                            print("✅ [AdaptyService] Частичная paywall конфигурация загружена и объединена с дефолтной")
                            print("[paywall] fetchPaywallConfig: partial OK")
                        } catch {
                            print("🚨 [AdaptyService] Ошибка парсинга частичной конфигурации: \(error)")
                            print("[paywall] fetchPaywallConfig: partial fail → PaywallConfig.getDefault()")
                            decoded = PaywallConfig.getDefault()
                        }
                    }
                    let withLimits = self.mergingGenerationLimitsFromRawJSON(decoded, jsonData: jsonData)
                    completion(.success(withLimits))
                } else {
                    print("⚠️ [AdaptyService] Remote config не найден, используем дефолт")
                    print("[paywall] fetchPaywallConfig: remoteConfig пуст → getDefault() (merged с bundled в PaywallCacheManager)")
                    completion(.success(PaywallConfig.getDefault()))
                }
            } catch {
                print("🚨 [AdaptyService] Ошибка получения paywall для конфигурации: \(error)")
                print("[paywall] fetchPaywallConfig: getPaywall ошибка → getDefault(): \(error)")
                completion(.success(PaywallConfig.getDefault()))
            }
        }
    }
    
    /// Получить конфигурацию paywall из Adapty (async версия)
    func fetchPaywallConfigAsync() async throws -> PaywallConfig {
        return try await withCheckedThrowingContinuation { continuation in
            fetchPaywallConfig { result in
                continuation.resume(with: result)
            }
        }
    }
    
    // MARK: - Adapty Paywall Fetching

    /// Единственная точка получения AdaptyPaywall.
    /// fetchPolicy .returnCacheDataElseLoad — при повторных запусках отдаёт данные из диска Adapty мгновенно,
    /// не делая сетевых запросов. loadTimeout 3с ограничивает ожидание при cold start (нет кэша Adapty).
    /// pendingPaywallTask дедуплицирует параллельные вызовы: второй ждёт результата первого без дополнительного сетевого запроса.
    private func fetchAdaptyPaywallAsync() async throws -> AdaptyPaywall {
        if let cached = cachedAdaptyPaywall, let at = cachedAdaptyPaywallAt,
           Date().timeIntervalSince(at) < adaptyPaywallCacheTTL {
            let pid = (try? paywallPlacementId()) ?? "?"
            print("[paywall] fetchAdaptyPaywallAsync: cache hit TTL placementId=\(pid) paywall.placement.id=\(cached.placement.id) revision=\(cached.placement.revision)")
            return cached
        }
        if let existing = pendingPaywallTask {
            print("[paywall] fetchAdaptyPaywallAsync: await pending shared task")
            return try await existing.value
        }
        let placementId = try paywallPlacementId()
        print("[paywall] fetchAdaptyPaywallAsync: Adapty.getPaywall placementId=\(placementId) tier=\(currentPlacementTier.rawValue)")
        let task = Task<AdaptyPaywall, Error> {
            try await withCheckedThrowingContinuation { cont in
                Adapty.getPaywall(
                    placementId: placementId,
                    fetchPolicy: .returnCacheDataElseLoad,
                    loadTimeout: 3
                ) { cont.resume(with: $0) }
            }
        }
        pendingPaywallTask = task
        do {
            let paywall = try await task.value
            pendingPaywallTask = nil
            cachedAdaptyPaywall = paywall
            cachedAdaptyPaywallAt = Date()
            print("[paywall] fetchAdaptyPaywallAsync: OK placement.id=\(paywall.placement.id) revision=\(paywall.placement.revision) hasRemoteConfig=\(paywall.remoteConfig != nil)")
            return paywall
        } catch {
            pendingPaywallTask = nil
            print("[paywall] fetchAdaptyPaywallAsync: error \(error)")
            throw error
        }
    }

    /// Сбросить кэш paywall-объекта (вызывается после покупки или восстановления).
    func invalidatePaywallCache() {
        print("[paywall] AdaptyService.invalidatePaywallCache")
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

    /// Накладывает корневой `generationLimits` из сырого remote JSON поверх уже декодированного конфига (ключи remote перекрывают decode).
    private func mergingGenerationLimitsFromRawJSON(_ config: PaywallConfig, jsonData: Data) -> PaywallConfig {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let parsed = parseGenerationLimits(from: root["generationLimits"]),
              !parsed.isEmpty
        else { return config }

        let merged = (config.generationLimits ?? [:]).merging(parsed) { _, remote in remote }
        if merged != config.generationLimits {
            print("[paywall] fetchPaywallConfig: generationLimits overlay из raw JSON keys=\(parsed.keys.sorted())")
        }
        return PaywallConfig(
            title: config.title,
            subtitle: config.subtitle,
            features: config.features,
            planIds: config.planIds,
            purchasePlanIds: config.purchasePlanIds,
            trialsPlanIds: config.trialsPlanIds,
            generationLimits: merged,
            adapty: config.adapty,
            ui: config.ui,
            logic: config.logic
        )
    }
    
    /// Парсить частичную конфигурацию и объединить с дефолтной
    private func parsePartialConfig(from jsonData: Data) throws -> PaywallConfig {
        _ = PaywallConfig.getDefault()
        
        // Парсим JSON как словарь
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "AdaptyService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format"])
        }
        
        // Извлекаем поля из JSON
        let title = json["title"] as? String
        let subtitle = json["subtitle"] as? String
        let features = json["features"] as? [String]
        let planIds = json["planIds"] as? [String]
        let purchasePlanIds = json["purchasePlanIds"] as? [String]
        let generationLimits = parseGenerationLimits(from: json["generationLimits"])
        let adaptyCatalog: PaywallAdaptyCatalog? = {
            guard let obj = json["adapty"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj)
            else { return nil }
            return try? JSONDecoder().decode(PaywallAdaptyCatalog.self, from: data)
        }()
        
        print("🔍 [AdaptyService] parsePartialConfig:")
        print("  - title: \(String(describing: title))")
        print("  - subtitle: \(String(describing: subtitle))")
        print("  - features: \(String(describing: features))")
        print("  - planIds: \(String(describing: planIds))")
        print("  - generationLimits: \(String(describing: generationLimits))")
        
        // Парсим UI конфигурацию
        let uiConfig = parseUIConfig(from: json["ui"] as? [String: Any])
        
        // Парсим freeGenerationsLimit прямо из корня JSON (глобальный параметр)
        let freeGenerationsLimit = json["freeGenerationsLimit"] as? Int

        // Парсим Logic конфигурацию
        var logicConfig = parseLogicConfig(from: json["logic"] as? [String: Any])
        // Если freeGenerationsLimit указан в корне, проставляем в logicConfig
        if let fgl = freeGenerationsLimit, logicConfig?.freeGenerationsLimit == nil {
            // Подтягиваем глобальный `freeGenerationsLimit` из корня и не теряем прочие override из `logic`.
            logicConfig = PaywallConfig.LogicConfig.createWithDefaults(
                defaultSelectedPlanIndex: logicConfig?.defaultSelectedPlanIndex,
                showTrialFirst: logicConfig?.showTrialFirst,
                highlightAnnual: logicConfig?.highlightAnnual,
                showSavingsPercentage: logicConfig?.showSavingsPercentage,
                showPrivacyLinks: logicConfig?.showPrivacyLinks,
                showcaseEnabled: logicConfig?.showcaseEnabled,
                freeGenerationsLimit: fgl,
                showRatingAfterGenerations: logicConfig?.showRatingAfterGenerations,
                showPaywallAfterOnboarding: logicConfig?.showPaywallAfterOnboarding,
                startingTokenBalance: logicConfig?.startingTokenBalance,
                dailyTokenAllowance: logicConfig?.dailyTokenAllowance,
                tokensPerEffectGeneration: logicConfig?.tokensPerEffectGeneration,
                promptVideoTokensPerSecond: logicConfig?.promptVideoTokensPerSecond,
                promptVideoAudioAddonTokens: logicConfig?.promptVideoAudioAddonTokens,
                promptPhotoGenerationTokens: logicConfig?.promptPhotoGenerationTokens
            )
        }
        
        print("🔍 [AdaptyService] parsePartialConfig - logicConfig: \(String(describing: logicConfig))")
        
        // Создаем конфигурацию с дефолтными значениями
        return PaywallConfig.createWithDefaults(
            title: title,
            subtitle: subtitle,
            features: features,
            planIds: planIds,
            purchasePlanIds: purchasePlanIds,
            generationLimits: generationLimits,
            adapty: adaptyCatalog,
            ui: uiConfig,
            logic: logicConfig
        )
    }
    
    /// Парсить UI конфигурацию из частичного JSON
    private func parseUIConfig(from json: [String: Any]?) -> PaywallConfig.UIConfig? {
        guard let json = json else { return nil }
        
        let backgroundColor = json["backgroundColor"] as? String
        let primaryColor = json["primaryColor"] as? String
        let accentColor = json["accentColor"] as? String
        let showMostPopularBadge = parseBooleanValue(from: json, key: "showMostPopularBadge")
        let carouselAutoScroll = parseBooleanValue(from: json, key: "carouselAutoScroll")
        let carouselInterval = json["carouselInterval"] as? Double
        let showSkipButton = parseBooleanValue(from: json, key: "showSkipButton")
        let skipButtonText = json["skipButtonText"] as? String
        
        print("🔍 [AdaptyService] parseUIConfig:")
        print("  - backgroundColor: \(String(describing: backgroundColor))")
        print("  - primaryColor: \(String(describing: primaryColor))")
        print("  - accentColor: \(String(describing: accentColor))")
        print("  - showMostPopularBadge: \(String(describing: showMostPopularBadge))")
        print("  - carouselAutoScroll: \(String(describing: carouselAutoScroll))")
        print("  - carouselInterval: \(String(describing: carouselInterval))")
        print("  - showSkipButton: \(String(describing: showSkipButton))")
        print("  - skipButtonText: \(String(describing: skipButtonText))")
        
        return PaywallConfig.UIConfig.createWithDefaults(
            backgroundColor: backgroundColor,
            primaryColor: primaryColor,
            accentColor: accentColor,
            showMostPopularBadge: showMostPopularBadge,
            carouselAutoScroll: carouselAutoScroll,
            carouselInterval: carouselInterval,
            showSkipButton: showSkipButton,
            skipButtonText: skipButtonText
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
    private func parseLogicConfig(from json: [String: Any]?) -> PaywallConfig.LogicConfig? {
        guard let json = json else { return nil }
        
        let defaultSelectedPlanIndex = json["defaultSelectedPlanIndex"] as? Int
        let freeGenerationsLimit = json["freeGenerationsLimit"] as? Int
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
        let showTrialFirst = parseBooleanValue(from: json, key: "showTrialFirst")
        let highlightAnnual = parseBooleanValue(from: json, key: "highlightAnnual")
        let showSavingsPercentage = parseBooleanValue(from: json, key: "showSavingsPercentage")
        let showPrivacyLinks = parseBooleanValue(from: json, key: "showPrivacyLinks")
        let showcaseEnabled = parseBooleanValue(from: json, key: "showcaseEnabled")
        let showPaywallAfterOnboarding = parseBooleanValue(from: json, key: "showPaywallAfterOnboarding")
        
        print("🔍 [AdaptyService] parseLogicConfig:")
        print("  - defaultSelectedPlanIndex: \(String(describing: defaultSelectedPlanIndex))")
        print("  - showTrialFirst: \(String(describing: showTrialFirst))")
        print("  - highlightAnnual: \(String(describing: highlightAnnual))")
        print("  - showSavingsPercentage: \(String(describing: showSavingsPercentage))")
        print("  - showPrivacyLinks: \(String(describing: showPrivacyLinks))")
        print("  - showcaseEnabled: \(String(describing: showcaseEnabled))")
        print("  - showPaywallAfterOnboarding: \(String(describing: showPaywallAfterOnboarding))")
        print("  - token defaults: start=\(String(describing: startingTokenBalance)), daily=\(String(describing: dailyTokenAllowance)), effect=\(String(describing: tokensPerEffectGeneration)), videoSec=\(String(describing: promptVideoTokensPerSecond)), audio=\(String(describing: promptVideoAudioAddonTokens)), photo=\(String(describing: promptPhotoGenerationTokens))")
        print("  - весь JSON logic: \(String(describing: json))")
        
        return PaywallConfig.LogicConfig.createWithDefaults(
            defaultSelectedPlanIndex: defaultSelectedPlanIndex,
            showTrialFirst: showTrialFirst,
            highlightAnnual: highlightAnnual,
            showSavingsPercentage: showSavingsPercentage,
            showPrivacyLinks: showPrivacyLinks,
            showcaseEnabled: showcaseEnabled,
            freeGenerationsLimit: freeGenerationsLimit,
            showRatingAfterGenerations: showRatingAfterGenerations,
            showPaywallAfterOnboarding: showPaywallAfterOnboarding,
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

 