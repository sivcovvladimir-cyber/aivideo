import Foundation
import Adapty
import StoreKit

// MARK: - StoreKit (симулятор)

/// Сериализация `Product.products`: параллельный preload и пейволл не дергают StoreKit одновременно.
private actor StoreKitSimulatorProductFetchGate {
    static let shared = StoreKitSimulatorProductFetchGate()

    func fetchProductsOnce(productIds: [String]) async throws -> [StoreKit.Product] {
        let products = try await Task { @MainActor in
            try await StoreKit.Product.products(for: productIds)
        }.value
        print("[paywall] loadLocalStoreKitProductsAsync: Product.products count=\(products.count)")
        return products
    }
}

// MARK: - Adapty catalog (локальный JSON + override из remote)

/// Один placement и один paywall в Adapty (без разбиения по tier). В JSON — `placementId` / `paywallId`; старый формат с `placements` / `paywalls` ещё декодируется.
struct PaywallAdaptyCatalog: Equatable {
    let placementId: String?
    let paywallId: String?

    init(placementId: String?, paywallId: String?) {
        self.placementId = placementId
        self.paywallId = paywallId
    }

    /// Remote поверх bundled: непустые поля remote перекрывают base.
    static func mergedOverlay(remote: PaywallAdaptyCatalog?, base: PaywallAdaptyCatalog?) -> PaywallAdaptyCatalog? {
        switch (remote, base) {
        case (nil, nil): return nil
        case (let r?, nil): return r
        case (nil, let b?): return b
        case (let r?, let b?):
            return PaywallAdaptyCatalog(
                placementId: coalesceNonEmpty(r.placementId, b.placementId),
                paywallId: coalesceNonEmpty(r.paywallId, b.paywallId)
            )
        }
    }

    private static func coalesceNonEmpty(_ primary: String?, _ fallback: String?) -> String? {
        let p = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p, !p.isEmpty { return p }
        if let f, !f.isEmpty { return f }
        return nil
    }
}

extension PaywallAdaptyCatalog: Codable {
    private enum CodingKeys: String, CodingKey {
        case placementId
        case paywallId
        case placement_id
        case paywall_id
        case placements
        case paywalls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try Self.decodeTrimmedString(container: c, keys: [.placementId, .placement_id]) {
            placementId = s
        } else if let map = try c.decodeIfPresent([String: String].self, forKey: .placements) {
            placementId = Self.firstValue(from: map, preferredTierKeys: ["standard", "proUpsell"])
        } else {
            placementId = nil
        }
        if let s = try Self.decodeTrimmedString(container: c, keys: [.paywallId, .paywall_id]) {
            paywallId = s
        } else if let map = try c.decodeIfPresent([String: String].self, forKey: .paywalls) {
            paywallId = Self.firstValue(from: map, preferredTierKeys: ["standard", "proUpsell"])
        } else {
            paywallId = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(placementId, forKey: .placementId)
        try c.encodeIfPresent(paywallId, forKey: .paywallId)
    }

    private static func decodeTrimmedString(container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) throws -> String? {
        for key in keys {
            if let s = try container.decodeIfPresent(String.self, forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
        }
        return nil
    }

    private static func firstValue(from map: [String: String], preferredTierKeys: [String]) -> String? {
        for k in preferredTierKeys {
            if let s = map[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return map.values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

// MARK: - Paywall Configuration Models

struct PaywallConfig: Codable {
    let title: String
    let subtitle: String
    let features: [String] // Могут быть ключами локализации или обычными строками
    
    /// Порядок отображения подписок (vendorProductId). Как в конфиге — так и показываем.
    let planIds: [String]?
    /// Порядок отображения разовых пакетов (vendorProductId). Как в конфиге — так и показываем.
    let purchasePlanIds: [String]?
    /// ID планов с триалом (из конфига; для совместимости с JSON).
    let trialsPlanIds: [String]?
    
    /// Лимиты генераций для всех продуктов (подписки и пакеты).
    /// Ключ — `vendorProductId` (например, "premium_weekly", "purchases_10_generations").
    /// Значение — количество генераций за период (для подписки) или размер пакета (для разовой покупки).
    let generationLimits: [String: Int]?

    /// Единственные `placementId` / `paywallId` в Adapty (см. `PaywallCacheManager.configuredAdaptyPlacementId()`).
    let adapty: PaywallAdaptyCatalog?
    
    let ui: UIConfig
    let logic: LogicConfig
    
    struct UIConfig: Codable {
        let backgroundColor: String? // hex color
        let primaryColor: String?
        let accentColor: String?
        let showMostPopularBadge: Bool
        let carouselAutoScroll: Bool
        let carouselInterval: Double
        let showSkipButton: Bool
        let skipButtonText: String?
    }
    
    struct LogicConfig: Codable {
        let defaultSelectedPlanIndex: Int
        let showTrialFirst: Bool?
        let highlightAnnual: Bool?
        let showSavingsPercentage: Bool?
        let showPrivacyLinks: Bool
        /// Показывать ли витрину (Showcase) в основном UI; дефолт в `LogicConfig.getDefault()`, remote может переопределить.
        let showcaseEnabled: Bool?
        /// Кол-во бесплатных генераций (remote override). Nil → используем хардкод в AppState
        let freeGenerationsLimit: Int?
        /// После каких по счёту успешных генераций показывать запрос оценки ([2, 10, 50]). Nil → дефолт [2].
        let showRatingAfterGenerations: [Int]?
        /// Показывать ли paywall после завершения онбординга. Nil → true (показывать).
        let showPaywallAfterOnboarding: Bool?

        /// Стартовый баланс токенов для AI Video token wallet.
        let startingTokenBalance: Int?
        /// Дневной порог бесплатного рефила: при новом календарном дне баланс = `max(текущий, daily)` — ниже не опускаем, выше не режем.
        let dailyTokenAllowance: Int?
        /// Единая цена generation по эффекту, когда `effect_presets.token_cost == nil`.
        let tokensPerEffectGeneration: Int?
        /// Цена prompt-video за секунду.
        let promptVideoTokensPerSecond: Int?
        /// При audio=on: столько токенов добавляется за каждую секунду длительности видео (умножается на duration).
        let promptVideoAudioAddonTokens: Int?
        /// Цена prompt-photo generation.
        let promptPhotoGenerationTokens: Int?

        init(
            defaultSelectedPlanIndex: Int,
            showTrialFirst: Bool?,
            highlightAnnual: Bool?,
            showSavingsPercentage: Bool?,
            showPrivacyLinks: Bool,
            showcaseEnabled: Bool?,
            freeGenerationsLimit: Int?,
            showRatingAfterGenerations: [Int]?,
            showPaywallAfterOnboarding: Bool?,
            startingTokenBalance: Int? = nil,
            dailyTokenAllowance: Int? = nil,
            tokensPerEffectGeneration: Int? = nil,
            promptVideoTokensPerSecond: Int? = nil,
            promptVideoAudioAddonTokens: Int? = nil,
            promptPhotoGenerationTokens: Int? = nil
        ) {
            self.defaultSelectedPlanIndex = defaultSelectedPlanIndex
            self.showTrialFirst = showTrialFirst
            self.highlightAnnual = highlightAnnual
            self.showSavingsPercentage = showSavingsPercentage
            self.showPrivacyLinks = showPrivacyLinks
            self.showcaseEnabled = showcaseEnabled
            self.freeGenerationsLimit = freeGenerationsLimit
            self.showRatingAfterGenerations = showRatingAfterGenerations
            self.showPaywallAfterOnboarding = showPaywallAfterOnboarding
            self.startingTokenBalance = startingTokenBalance
            self.dailyTokenAllowance = dailyTokenAllowance
            self.tokensPerEffectGeneration = tokensPerEffectGeneration
            self.promptVideoTokensPerSecond = promptVideoTokensPerSecond
            self.promptVideoAudioAddonTokens = promptVideoAudioAddonTokens
            self.promptPhotoGenerationTokens = promptPhotoGenerationTokens
        }

        enum CodingKeys: String, CodingKey {
            case defaultSelectedPlanIndex, showTrialFirst, highlightAnnual, showSavingsPercentage
            case showPrivacyLinks, showcaseEnabled
            case freeGenerationsLimit, showRatingAfterGenerations, showPaywallAfterOnboarding
            case startingTokenBalance, dailyTokenAllowance, tokensPerEffectGeneration
            case promptVideoTokensPerSecond, promptVideoAudioAddonTokens, promptPhotoGenerationTokens
            case starting_token_balance, daily_token_allowance, tokens_per_effect_generation
            case prompt_video_tokens_per_second, prompt_video_audio_addon_tokens, prompt_photo_generation_tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = PaywallConfig.LogicConfig.getDefault()
            defaultSelectedPlanIndex = try container.decodeIfPresent(Int.self, forKey: .defaultSelectedPlanIndex) ?? defaults.defaultSelectedPlanIndex
            showTrialFirst = try container.decodeIfPresent(Bool.self, forKey: .showTrialFirst) ?? defaults.showTrialFirst
            highlightAnnual = try container.decodeIfPresent(Bool.self, forKey: .highlightAnnual) ?? defaults.highlightAnnual
            showSavingsPercentage = try container.decodeIfPresent(Bool.self, forKey: .showSavingsPercentage) ?? defaults.showSavingsPercentage
            showPrivacyLinks = try container.decodeIfPresent(Bool.self, forKey: .showPrivacyLinks) ?? defaults.showPrivacyLinks
            showcaseEnabled = try container.decodeIfPresent(Bool.self, forKey: .showcaseEnabled) ?? defaults.showcaseEnabled
            freeGenerationsLimit = try container.decodeIfPresent(Int.self, forKey: .freeGenerationsLimit) ?? defaults.freeGenerationsLimit
            showRatingAfterGenerations = try container.decodeIfPresent([Int].self, forKey: .showRatingAfterGenerations) ?? defaults.showRatingAfterGenerations
            showPaywallAfterOnboarding = try container.decodeIfPresent(Bool.self, forKey: .showPaywallAfterOnboarding) ?? defaults.showPaywallAfterOnboarding
            startingTokenBalance = try container.decodeIfPresent(Int.self, forKey: .startingTokenBalance) ?? container.decodeIfPresent(Int.self, forKey: .starting_token_balance) ?? defaults.startingTokenBalance
            dailyTokenAllowance = try container.decodeIfPresent(Int.self, forKey: .dailyTokenAllowance) ?? container.decodeIfPresent(Int.self, forKey: .daily_token_allowance) ?? defaults.dailyTokenAllowance
            tokensPerEffectGeneration = try container.decodeIfPresent(Int.self, forKey: .tokensPerEffectGeneration) ?? container.decodeIfPresent(Int.self, forKey: .tokens_per_effect_generation) ?? defaults.tokensPerEffectGeneration
            promptVideoTokensPerSecond = try container.decodeIfPresent(Int.self, forKey: .promptVideoTokensPerSecond) ?? container.decodeIfPresent(Int.self, forKey: .prompt_video_tokens_per_second) ?? defaults.promptVideoTokensPerSecond
            promptVideoAudioAddonTokens = try container.decodeIfPresent(Int.self, forKey: .promptVideoAudioAddonTokens) ?? container.decodeIfPresent(Int.self, forKey: .prompt_video_audio_addon_tokens) ?? defaults.promptVideoAudioAddonTokens
            promptPhotoGenerationTokens = try container.decodeIfPresent(Int.self, forKey: .promptPhotoGenerationTokens) ?? container.decodeIfPresent(Int.self, forKey: .prompt_photo_generation_tokens) ?? defaults.promptPhotoGenerationTokens
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(defaultSelectedPlanIndex, forKey: .defaultSelectedPlanIndex)
            try container.encodeIfPresent(showTrialFirst, forKey: .showTrialFirst)
            try container.encodeIfPresent(highlightAnnual, forKey: .highlightAnnual)
            try container.encodeIfPresent(showSavingsPercentage, forKey: .showSavingsPercentage)
            try container.encode(showPrivacyLinks, forKey: .showPrivacyLinks)
            try container.encodeIfPresent(showcaseEnabled, forKey: .showcaseEnabled)
            try container.encodeIfPresent(freeGenerationsLimit, forKey: .freeGenerationsLimit)
            try container.encodeIfPresent(showRatingAfterGenerations, forKey: .showRatingAfterGenerations)
            try container.encodeIfPresent(showPaywallAfterOnboarding, forKey: .showPaywallAfterOnboarding)
            try container.encodeIfPresent(startingTokenBalance, forKey: .startingTokenBalance)
            try container.encodeIfPresent(dailyTokenAllowance, forKey: .dailyTokenAllowance)
            try container.encodeIfPresent(tokensPerEffectGeneration, forKey: .tokensPerEffectGeneration)
            try container.encodeIfPresent(promptVideoTokensPerSecond, forKey: .promptVideoTokensPerSecond)
            try container.encodeIfPresent(promptVideoAudioAddonTokens, forKey: .promptVideoAudioAddonTokens)
            try container.encodeIfPresent(promptPhotoGenerationTokens, forKey: .promptPhotoGenerationTokens)
        }
    }
    
    // MARK: - Localization Support
    
    /// Получить локализованные фичи
    func getLocalizedFeatures() -> [String] {
        return features.map { feature in
            // Если строка начинается с "feature_", считаем её ключом локализации
            if feature.hasPrefix("feature_") {
                return feature.localized
            } else {
                // Иначе возвращаем как есть (для кастомных строк)
                return feature
            }
        }
    }
    
    /// Получить локализованный заголовок
    func getLocalizedTitle() -> String {
        if title.hasPrefix("paywall_") {
            return title.localized
        }
        return title
    }
    
    /// Получить локализованный подзаголовок
    func getLocalizedSubtitle() -> String {
        if subtitle.hasPrefix("paywall_") {
            return subtitle.localized
        }
        return subtitle
    }

    /// Явный инициализатор: после кастомного `Decodable` у структуры нет синтезируемого memberwise init.
    init(
        title: String,
        subtitle: String,
        features: [String],
        planIds: [String]?,
        purchasePlanIds: [String]?,
        trialsPlanIds: [String]?,
        generationLimits: [String: Int]?,
        adapty: PaywallAdaptyCatalog?,
        ui: UIConfig,
        logic: LogicConfig
    ) {
        self.title = title
        self.subtitle = subtitle
        self.features = features
        self.planIds = planIds
        self.purchasePlanIds = purchasePlanIds
        self.trialsPlanIds = trialsPlanIds
        self.generationLimits = generationLimits
        self.adapty = adapty
        self.ui = ui
        self.logic = logic
    }
}

// MARK: - PaywallConfig decoding (частичный bundled JSON дополняется дефолтами из `getDefault()`)

extension PaywallConfig {
    enum CodingKeys: String, CodingKey {
        case title, subtitle, features, planIds, purchasePlanIds, trialsPlanIds, generationLimits, adapty, ui, logic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundledDefaults = PaywallConfig.getDefault()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? bundledDefaults.title
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? bundledDefaults.subtitle
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? bundledDefaults.features
        planIds = try c.decodeIfPresent([String].self, forKey: .planIds)
        purchasePlanIds = try c.decodeIfPresent([String].self, forKey: .purchasePlanIds)
        trialsPlanIds = try c.decodeIfPresent([String].self, forKey: .trialsPlanIds)
        generationLimits = try c.decodeIfPresent([String: Int].self, forKey: .generationLimits)
        adapty = try c.decodeIfPresent(PaywallAdaptyCatalog.self, forKey: .adapty)
        ui = try c.decodeIfPresent(UIConfig.self, forKey: .ui) ?? UIConfig.getDefault()
        logic = try c.decodeIfPresent(LogicConfig.self, forKey: .logic) ?? LogicConfig.getDefault()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(subtitle, forKey: .subtitle)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(planIds, forKey: .planIds)
        try c.encodeIfPresent(purchasePlanIds, forKey: .purchasePlanIds)
        try c.encodeIfPresent(trialsPlanIds, forKey: .trialsPlanIds)
        try c.encodeIfPresent(generationLimits, forKey: .generationLimits)
        try c.encodeIfPresent(adapty, forKey: .adapty)
        try c.encode(ui, forKey: .ui)
        try c.encode(logic, forKey: .logic)
    }
}

// MARK: - Product Information Cache

struct ProductInfo: Codable {
    let vendorProductId: String
    let localizedTitle: String
    let localizedDescription: String
    let localizedPrice: String
    let currencyCode: String?
    let subscriptionPeriod: String?
    let trialPeriod: String?
    let isTrial: Bool
}

// MARK: - Paywall Cache Manager

class PaywallCacheManager: ObservableObject {
    static let shared = PaywallCacheManager()
    
    @Published var paywallConfig: PaywallConfig?
    @Published var productsCache: [String: ProductInfo] = [:]
    /// Порядок product ID, как вернул Adapty (для сортировки, если в конфиге не задан planIds/purchasePlanIds).
    @Published var productIdsOrder: [String] = []
    /// Режим отображения одного общего paywall: продукты грузим все, а UI фильтрует подписки/пакеты программно.
    @Published private(set) var currentPlacementTier: PaywallPlacementTier = .standard
    
    @Published var isLoading: Bool = false
    @Published var error: String?

    /// Нужно, чтобы на критических переходах (например, окончание онбординга) мы могли
    /// дождаться remote override из Adapty и не принимать решение по локальному дефолту.
    private var hasAttemptedRemoteConfigLoad: Bool = false
    
    // Чтобы убрать гонки: принимаем решение только после того, как Adapty-ветка
    // реально закончила попытку загрузки конфигурации (даже если упала по сети).
    private var isRemotePaywallConfigLoadFinished: Bool = false
    private var isRemotePaywallConfigLoadSucceeded: Bool = false
    
    // Кэш полных Adapty продуктов для покупки
    private var adaptyProductsCache: [String: AdaptyPaywallProduct] = [:]
    // Локальный StoreKit fallback нужен до появления продуктов в App Store Connect:
    // симулятор берёт продукты из `AIVideo.storekit` в корне репозитория, даже если Adapty paywall ещё без product IDs.
    private var storeKitProductsCache: [String: StoreKit.Product] = [:]

    // Кэш paywall_config.json из Bundle — файл не меняется в процессе работы, читаем один раз.
    private var bundleConfigCache: PaywallConfig?
    
    private let userDefaults = UserDefaults.standard
    private let configKey = "cached_paywall_config"
    private let productsKey = "cached_products"
    private let productOrderKey = "cached_paywall_product_order"
    private let lastUpdateKey = "last_cache_update"
    
    private init() {
        // Базовый product/adapty-контракт всегда берём из bundled JSON: старый UserDefaults-кэш не должен
        // подменять свежие placement/product IDs до фонового merge с Adapty.
        paywallConfig = loadProjectConfig()

        if let cachedProducts = loadProductsFromCache() {
            productsCache = cachedProducts
            productIdsOrder = loadProductOrderFromCache() ?? Array(cachedProducts.keys)
            print("[paywall] init: восстановлен кэш продуктов из UserDefaults count=\(cachedProducts.count) ids=\(productIdsOrder)")
        } else {
            print("[paywall] init: кэша продуктов в UserDefaults нет")
        }
        
        // На старте считаем, что remote-ветка ещё не отрабатывала, даже если paywallConfig
        // мог быть загружен из bundle/cache.
        isRemotePaywallConfigLoadFinished = false
        isRemotePaywallConfigLoadSucceeded = false
    }

    // MARK: - Remote Load State
    @MainActor
    func remotePaywallConfigLoadState() -> (finished: Bool, succeeded: Bool) {
        (finished: isRemotePaywallConfigLoadFinished, succeeded: isRemotePaywallConfigLoadSucceeded)
    }
    
    // MARK: - Helper Methods
    
    /// Определить, является ли продукт trial
    private func isTrialProduct(_ product: AdaptyPaywallProduct) -> Bool {
        // Проверяем по vendorProductId, содержит ли он "trial"
        return product.vendorProductId.lowercased().contains("trial")
    }
    
    /// Получить AdaptyPaywallProduct для покупки
    func getAdaptyProduct(for vendorProductId: String) -> AdaptyPaywallProduct? {
        return adaptyProductsCache[vendorProductId]
    }

    /// Получить локальный StoreKit product для покупки, если Adapty ещё не отдаёт продукты.
    func getStoreKitProduct(for vendorProductId: String) -> StoreKit.Product? {
        return storeKitProductsCache[vendorProductId]
    }

    /// Переключает только режим отображения: Adapty paywall один, продукты фильтруются в UI.
    func setPlacementTier(_ tier: PaywallPlacementTier) {
        guard currentPlacementTier != tier else { return }
        print("[paywall] setPlacementTier: \(currentPlacementTier.rawValue) → \(tier.rawValue) (режим UI; продукты общие)")
        currentPlacementTier = tier
    }
    
    // MARK: - Cache Management
    
    /// Загрузить и кэшировать конфигурацию paywall и продукты (async)
    @discardableResult
    func loadAndCachePaywallDataAsync() async -> Bool {
        await MainActor.run { isLoading = true; error = nil }
        print("🔄 [PaywallCacheManager] Начинаем загрузку данных paywall...")
        print("[paywall] loadAndCachePaywallDataAsync: старт tier=\(currentPlacementTier.rawValue) productsCache.count=\(productsCache.count)")

        // Сначала конфиг, потом продукты: на симуляторе Xcode 26 параллельный старт давал getPaywallProducts / Product.products до готовности StoreKit Testing из схемы (пустой каталог).
        let c = await loadPaywallConfigAsync()
        let p = await loadProductsAsync()

        await MainActor.run { self.isLoading = false }

        if c && p {
            print("✅ [PaywallCacheManager] Все данные успешно загружены и кэшированы")
            print("[paywall] loadAndCachePaywallDataAsync: успех config+products productsCache.count=\(productsCache.count) planIds=\(String(describing: paywallConfig?.planIds)) purchasePlanIds=\(String(describing: paywallConfig?.purchasePlanIds))")
            await MainActor.run { self.updateLastCacheTime() }
        } else {
            print("⚠️ [PaywallCacheManager] Частичная загрузка: config=\(c), products=\(p)")
            print("[paywall] loadAndCachePaywallDataAsync: частично config=\(c) products=\(p) productsCache.count=\(productsCache.count)")
        }
        return c && p
    }

    /// Обёртка для обратной совместимости
    func loadAndCachePaywallData(completion: @escaping (Bool) -> Void) {
        Task {
            let result = await loadAndCachePaywallDataAsync()
            completion(result)
        }
    }

    /// Загрузить конфигурацию paywall из Adapty (чистая async-функция)
    private func loadPaywallConfigAsync() async -> Bool {
        await MainActor.run {
            self.hasAttemptedRemoteConfigLoad = true
            self.isRemotePaywallConfigLoadFinished = false
            self.isRemotePaywallConfigLoadSucceeded = false
        }

        let baseConfig = loadProjectConfig()
        print("📁 [PaywallCacheManager] Базовая конфигурация из проекта загружена")
        let pl = (try? configuredAdaptyPlacementId()) ?? "(ошибка placement)"
        print("[paywall] loadPaywallConfigAsync: bundled placementId=\(pl) planIds=\(String(describing: baseConfig.planIds)) purchasePlanIds=\(String(describing: baseConfig.purchasePlanIds))")

        do {
            let adaptyConfig = try await AdaptyService.shared.fetchPaywallConfigAsync()
            let mergedConfig = mergeConfigs(base: baseConfig, adapty: adaptyConfig)
            await MainActor.run {
                self.paywallConfig = mergedConfig
                self.saveConfigToCache(mergedConfig)
                self.isRemotePaywallConfigLoadFinished = true
                self.isRemotePaywallConfigLoadSucceeded = true
                print("✅ [PaywallCacheManager] Объединенная конфигурация загружена")
                let mp = (try? self.configuredAdaptyPlacementId()) ?? "?"
                print("[paywall] loadPaywallConfigAsync: merge OK placementId=\(mp) planIds=\(String(describing: mergedConfig.planIds)) purchasePlanIds=\(String(describing: mergedConfig.purchasePlanIds))")
            }
            return true
        } catch {
            await MainActor.run {
                print("⚠️ [PaywallCacheManager] Adapty недоступен, используем базовую конфигурацию: \(error)")
                print("[paywall] loadPaywallConfigAsync: ошибка Adapty, fallback на bundled: \(error)")
                self.paywallConfig = baseConfig
                self.saveConfigToCache(baseConfig)
                self.isRemotePaywallConfigLoadFinished = true
                self.isRemotePaywallConfigLoadSucceeded = false
            }
            return true
        }
    }
    
    /// Загрузить информацию о продуктах из Adapty, с локальным StoreKit fallback для разработки.
    private func loadProductsAsync() async -> Bool {
        #if targetEnvironment(simulator)
        // Тот же StoreKit 2 под капотом Adapty.getPaywallProducts; на симуляторе с .storekit в схеме первый запрос в первые миллисекунды после launch часто даёт noProductIDsFound.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #endif
        print("[paywall] loadProductsAsync: запрос продуктов через Adapty.getPaywallProducts…")
        do {
            let products = try await AdaptyService.shared.fetchProductsAsync()
            var productsInfo: [String: ProductInfo] = [:]
            var order: [String] = []
            var cache: [String: AdaptyPaywallProduct] = [:]

            for product in products {
                productsInfo[product.vendorProductId] = ProductInfo(
                    vendorProductId: product.vendorProductId,
                    localizedTitle: product.localizedTitle,
                    localizedDescription: product.localizedDescription,
                    localizedPrice: product.localizedPrice ?? "",
                    currencyCode: product.currencyCode,
                    subscriptionPeriod: product.subscriptionPeriod?.unit.rawValue as? String,
                    trialPeriod: isTrialProduct(product) ? "3 days" : nil,
                    isTrial: isTrialProduct(product)
                )
                order.append(product.vendorProductId)
                cache[product.vendorProductId] = product
            }

            await MainActor.run {
                self.productsCache = productsInfo
                self.productIdsOrder = order
                self.adaptyProductsCache = cache
                self.storeKitProductsCache = [:]
                self.saveProductsToCache(productsInfo)
                self.saveProductOrderToCache(order)
                print("✅ [PaywallCacheManager] Продукты загружены: \(productsInfo.count), порядок: \(order)")
                print("[paywall] loadProductsAsync: Adapty OK count=\(productsInfo.count) vendorIds=\(order) adaptyPurchasePath=true")
            }
            return true
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка загрузки продуктов: \(error)")
            print("💡 [PaywallCacheManager] Пробуем локальный StoreKit fallback из AIVideo.storekit.")
            print("[paywall] loadProductsAsync: Adapty ошибка → StoreKit fallback: \(error)")
            if await loadLocalStoreKitProductsAsync() {
                print("[paywall] loadProductsAsync: StoreKit fallback успешен")
                return true
            }
            await MainActor.run {
                self.adaptyProductsCache = [:]
                self.storeKitProductsCache = [:]
                self.productsCache = [:]
                self.productIdsOrder = []
                self.saveProductsToCache([:])
                self.saveProductOrderToCache([])
                print("📦 [PaywallCacheManager] Кэш продуктов сброшен: продукты недоступны ни через Adapty, ни через StoreKit")
                print("[paywall] loadProductsAsync: итог пусто — карточек не будет (Adapty+StoreKit)")
            }
            return false
        }
    }

    /// Загружает продукты напрямую из StoreKit по ID из локального paywall config.
    private func loadLocalStoreKitProductsAsync() async -> Bool {
        let productIds = configuredLocalStoreKitProductIds()
        print("[paywall] loadLocalStoreKitProductsAsync: запрошенные productIds=\(productIds)")
        guard !productIds.isEmpty else {
            print("⚠️ [PaywallCacheManager] Нет product IDs для локального StoreKit fallback")
            print("[paywall] loadLocalStoreKitProductsAsync: пустой список id (проверь planIds+purchasePlanIds в конфиге)")
            return false
        }

        do {
            // Один запрос к StoreKit 2; при пустом ответе ниже — bundled `.storekit` для UI (display-only).
            let products = try await fetchStoreKitProductsOnceViaGate(productIds: productIds)
            guard !products.isEmpty else {
                print("⚠️ [PaywallCacheManager] StoreKit вернул 0 продуктов для ids: \(productIds)")
                #if targetEnvironment(simulator)
                let v = ProcessInfo.processInfo.operatingSystemVersion
                print("[paywall] loadLocalStoreKitProductsAsync: Product.products пусто — bundle=\(Bundle.main.bundleIdentifier ?? "?"); симулятор iOS \(v.majorVersion).\(v.minorVersion). Проверь: Edit Scheme → Run → Options → StoreKit = AIVideo.storekit в корне репо (в .xcscheme от xcschemes: ../../AIVideo.storekit; не ../../Config — это внутрь .xcodeproj). На iOS 26 симуляторе Product.products часто остаётся [] — тогда рантайм iOS 18.x или устройство + sandbox; UI спасает loadBundledStoreKitCatalogForDisplay.")
                #else
                print("[paywall] loadLocalStoreKitProductsAsync: Product.products пусто — bundle=\(Bundle.main.bundleIdentifier ?? "?")")
                #endif
                return await loadBundledStoreKitCatalogForDisplay(productIds: productIds)
            }

            var productsInfo: [String: ProductInfo] = [:]
            var cache: [String: StoreKit.Product] = [:]
            for product in products {
                productsInfo[product.id] = ProductInfo(
                    vendorProductId: product.id,
                    localizedTitle: product.displayName,
                    localizedDescription: product.description,
                    localizedPrice: product.displayPrice,
                    currencyCode: product.priceFormatStyle.currencyCode,
                    subscriptionPeriod: subscriptionPeriodString(for: product),
                    trialPeriod: product.subscription?.introductoryOffer == nil ? nil : "3 days",
                    isTrial: product.subscription?.introductoryOffer != nil
                )
                cache[product.id] = product
            }

            let order = productIds.filter { productsInfo[$0] != nil }
            await MainActor.run {
                self.productsCache = productsInfo
                self.productIdsOrder = order
                self.adaptyProductsCache = [:]
                self.storeKitProductsCache = cache
                self.saveProductsToCache(productsInfo)
                self.saveProductOrderToCache(order)
                print("✅ [PaywallCacheManager] Локальные StoreKit продукты загружены: \(productsInfo.count), порядок: \(order)")
                print("[paywall] loadLocalStoreKitProductsAsync: OK count=\(productsInfo.count) ids=\(order) adaptyPurchasePath=false (только отображение/покупка через StoreKit)")
            }
            return true
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка локального StoreKit fallback: \(error)")
            print("[paywall] loadLocalStoreKitProductsAsync: исключение: \(error)")
            return false
        }
    }

    /// Последний fallback для локальной разработки: если StoreKit runtime вернул [], читаем bundled `.storekit` как display-only каталог, чтобы пейволл не был пустым.
    private func loadBundledStoreKitCatalogForDisplay(productIds: [String]) async -> Bool {
        guard let url = Bundle.main.url(forResource: "AIVideo", withExtension: "storekit") else {
            print("[paywall] loadBundledStoreKitCatalogForDisplay: AIVideo.storekit не найден в Bundle")
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(LocalStoreKitCatalog.self, from: data)
            let productsInfo = catalog.productInfos(for: productIds)
            guard !productsInfo.isEmpty else {
                print("[paywall] loadBundledStoreKitCatalogForDisplay: каталог прочитан, но совпадений по productIds нет")
                return false
            }

            let order = productIds.filter { productsInfo[$0] != nil }
            await MainActor.run {
                self.productsCache = productsInfo
                self.productIdsOrder = order
                self.adaptyProductsCache = [:]
                self.storeKitProductsCache = [:]
                self.saveProductsToCache(productsInfo)
                self.saveProductOrderToCache(order)
                print("[paywall] loadBundledStoreKitCatalogForDisplay: OK displayOnly count=\(productsInfo.count) ids=\(order)")
            }
            return true
        } catch {
            print("[paywall] loadBundledStoreKitCatalogForDisplay: ошибка чтения AIVideo.storekit: \(error)")
            return false
        }
    }

    private struct LocalStoreKitCatalog: Decodable {
        let products: [LocalStoreKitProduct]?
        let subscriptionGroups: [LocalStoreKitSubscriptionGroup]?

        func productInfos(for productIds: [String]) -> [String: ProductInfo] {
            var byId: [String: ProductInfo] = [:]
            for product in products ?? [] {
                byId[product.productID] = product.productInfo(subscriptionPeriod: nil)
            }
            for group in subscriptionGroups ?? [] {
                for subscription in group.subscriptions ?? [] {
                    byId[subscription.productID] = subscription.productInfo(
                        subscriptionPeriod: subscription.subscriptionPeriodString
                    )
                }
            }
            let wanted = Set(productIds)
            return byId.filter { wanted.contains($0.key) }
        }
    }

    private struct LocalStoreKitSubscriptionGroup: Decodable {
        let subscriptions: [LocalStoreKitProduct]?
    }

    private struct LocalStoreKitProduct: Decodable {
        let productID: String
        let displayPrice: String
        let localizations: [LocalStoreKitLocalization]?
        let recurringSubscriptionPeriod: String?

        var subscriptionPeriodString: String? {
            switch recurringSubscriptionPeriod {
            case "P1W": return "week"
            case "P1M": return "month"
            case "P1Y": return "year"
            default: return nil
            }
        }

        func productInfo(subscriptionPeriod: String?) -> ProductInfo {
            let localization = localizations?.first { $0.locale == Locale.current.identifier }
                ?? localizations?.first { $0.locale == "en_US" }
                ?? localizations?.first

            return ProductInfo(
                vendorProductId: productID,
                localizedTitle: localization?.displayName ?? productID,
                localizedDescription: localization?.description ?? "",
                localizedPrice: "$\(displayPrice)",
                currencyCode: "USD",
                subscriptionPeriod: subscriptionPeriod,
                trialPeriod: nil,
                isTrial: false
            )
        }
    }

    private struct LocalStoreKitLocalization: Decodable {
        let displayName: String
        let description: String
        let locale: String
    }

    /// Один вызов `Product.products` через общий gate (без ретраев и sleep).
    private func fetchStoreKitProductsOnceViaGate(productIds: [String]) async throws -> [StoreKit.Product] {
        try await StoreKitSimulatorProductFetchGate.shared.fetchProductsOnce(productIds: productIds)
    }

    private func configuredLocalStoreKitProductIds() -> [String] {
        let config = paywallConfig ?? loadProjectConfig()
        let ids = (config.planIds ?? []) + (config.purchasePlanIds ?? [])
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func subscriptionPeriodString(for product: StoreKit.Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
        switch period.unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return nil
        }
    }
    
    // MARK: - Project Configuration
    
    /// Загрузить базовую конфигурацию из JSON файла проекта.
    /// Результат кешируется в памяти — файл из Bundle не меняется в рантайме, читаем один раз.
    private func loadProjectConfig() -> PaywallConfig {
        if let cached = bundleConfigCache { return cached }

        print("🔍 [PaywallCacheManager] Ищем paywall_config.json в Bundle...")

        guard let url = Bundle.main.url(forResource: "paywall_config", withExtension: "json") else {
            print("🚨 [PaywallCacheManager] Файл paywall_config.json не найден в Bundle")
            let fallback = PaywallConfig.getDefault()
            bundleConfigCache = fallback
            return fallback
        }

        print("✅ [PaywallCacheManager] Файл найден: \(url)")

        guard let data = try? Data(contentsOf: url) else {
            print("🚨 [PaywallCacheManager] Не удалось прочитать данные из файла")
            let fallback = PaywallConfig.getDefault()
            bundleConfigCache = fallback
            return fallback
        }

        print("✅ [PaywallCacheManager] Данные прочитаны, размер: \(data.count) байт")

        guard let config = try? JSONDecoder().decode(PaywallConfig.self, from: data) else {
            print("🚨 [PaywallCacheManager] Не удалось декодировать JSON")
            let fallback = PaywallConfig.getDefault()
            bundleConfigCache = fallback
            return fallback
        }

        print("📁 [PaywallCacheManager] Базовая конфигурация загружена из paywall_config.json")
        bundleConfigCache = config
        return config
    }
    
    /// Объединить базовую конфигурацию с настройками из Adapty
    private func mergeConfigs(base: PaywallConfig, adapty: PaywallConfig) -> PaywallConfig {
        print("🔍 [PaywallCacheManager] Объединяем конфигурации:")
        print("  Базовая (проект) и Adapty логика будут слиты")
        
        // Приоритет: Adapty переопределяет локальный конфиг для всех полей, где есть значение.
        // generationLimits мёржим по ключам (Adapty перезаписывает отдельные ключи, не весь словарь),
        // чтобы частичный override из Adapty (например один `vendorProductId` → лимит) не стёр остальные ключи локального JSON.
        let mergedLimits: [String: Int]? = {
            switch (base.generationLimits, adapty.generationLimits) {
            case (nil, let a): return a
            case (let b, nil): return b
            case (let b?, let a?): return b.merging(a) { _, adaptyValue in adaptyValue }
            }
        }()

        let mergedConfig = PaywallConfig.createWithDefaults(
            title: adapty.title != base.title ? adapty.title : base.title,
            subtitle: adapty.subtitle != base.subtitle ? adapty.subtitle : base.subtitle,
            features: adapty.features != base.features ? adapty.features : base.features,
            planIds: adapty.planIds ?? base.planIds,
            purchasePlanIds: adapty.purchasePlanIds ?? base.purchasePlanIds,
            generationLimits: mergedLimits,
            adapty: PaywallAdaptyCatalog.mergedOverlay(remote: adapty.adapty, base: base.adapty),
            // UI: remote целиком. Logic: optional-поля накладываем поверх bundled, чтобы «пустой» remote (`getDefault()`)
            // не затирал токены и флаги из `paywall_config.json`.
            ui: adapty.ui,
            logic: PaywallConfig.LogicConfig.mergedRemote(adapty.logic, over: base.logic)
        )
        print("[paywall] mergeConfigs: итог planIds=\(String(describing: mergedConfig.planIds)) purchasePlanIds=\(String(describing: mergedConfig.purchasePlanIds)) generationLimits.keys=\(mergedConfig.generationLimits?.keys.sorted() ?? [])")
        return mergedConfig
    }
    
    // MARK: - Cache Storage
    
    private func saveConfigToCache(_ config: PaywallConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            userDefaults.set(data, forKey: configKey)
            print("💾 [PaywallCacheManager] Конфигурация сохранена в кэш")
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка сохранения конфигурации: \(error)")
        }
    }
    
    private func loadConfigFromCache() -> PaywallConfig? {
        guard let data = userDefaults.data(forKey: configKey) else { return nil }
        do {
            let config = try JSONDecoder().decode(PaywallConfig.self, from: data)
            print("📦 [PaywallCacheManager] Конфигурация загружена из кэша")
            return config
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка загрузки конфигурации из кэша: \(error)")
            return nil
        }
    }
    
    private func saveProductsToCache(_ products: [String: ProductInfo]) {
        do {
            let data = try JSONEncoder().encode(products)
            userDefaults.set(data, forKey: productsKey)
            print("💾 [PaywallCacheManager] Продукты сохранены в кэш")
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка сохранения продуктов: \(error)")
        }
    }
    
    private func loadProductsFromCache() -> [String: ProductInfo]? {
        guard let data = userDefaults.data(forKey: productsKey) else { return nil }
        do {
            let products = try JSONDecoder().decode([String: ProductInfo].self, from: data)
            print("📦 [PaywallCacheManager] Продукты загружены из кэша")
            return products
        } catch {
            print("🚨 [PaywallCacheManager] Ошибка загрузки продуктов из кэша: \(error)")
            return nil
        }
    }
    
    private func saveProductOrderToCache(_ order: [String]) {
        userDefaults.set(order, forKey: productOrderKey)
    }
    
    private func loadProductOrderFromCache() -> [String]? {
        userDefaults.stringArray(forKey: productOrderKey)
    }
    
    private func updateLastCacheTime() {
        userDefaults.set(Date(), forKey: lastUpdateKey)
    }
    
    // MARK: - Public Methods
    
    /// Получить информацию о продуктах для paywall
    func getPaywallProducts() -> [ProductInfo] {
        return Array(productsCache.values)
    }
    
    /// Получить дефолтный выбранный план
    func getDefaultSelectedPlanIndex() -> Int {
        return paywallConfig?.logic.defaultSelectedPlanIndex ?? 0
    }

    /// Adapty placement из `paywall_config.json` → `adapty.placementId` (один на всё приложение).
    func configuredAdaptyPlacementId() throws -> String {
        guard let id = paywallConfig?.adapty?.placementId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            throw NSError(
                domain: "PaywallConfig",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing adapty.placementId in paywall_config.json"]
            )
        }
        return id
    }

    /// Paywall builder id из конфига — только для логов/диагностики; SDK грузит paywall по placement.
    func configuredAdaptyPaywallId() throws -> String {
        guard let id = paywallConfig?.adapty?.paywallId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            throw NSError(
                domain: "PaywallConfig",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing adapty.paywallId in paywall_config.json"]
            )
        }
        return id
    }
    
    /// Проверить, есть ли кэшированные данные (и они валидны — без аномальных лимитов)
    func hasCachedData() -> Bool {
        if paywallConfig == nil {
            print("[paywall] hasCachedData: false (paywallConfig == nil)")
            return false
        }
        if productsCache.isEmpty {
            print("[paywall] hasCachedData: false (productsCache пустой)")
            return false
        }
        // Проверяем что лимиты не аномальные (оверфлоу/таймстемп и т.п.)
        if let limits = paywallConfig?.generationLimits {
            let hasAbnormal = limits.values.contains { $0 >= 100_000 }
            if hasAbnormal {
                print("⚠️ [PaywallCacheManager] Обнаружены аномальные generationLimits в кэше: \(limits). Сбрасываем кэш.")
                print("[paywall] hasCachedData: false (аномальные generationLimits), clearCache")
                clearCache()
                return false
            }
        }
        return true
    }
    
    /// Очистить кэш
    func clearCache() {
        userDefaults.removeObject(forKey: configKey)
        userDefaults.removeObject(forKey: productsKey)
        userDefaults.removeObject(forKey: productOrderKey)
        // Удаляем ключи от короткого эксперимента с раздельным кэшем placement tier.
        for tier in PaywallPlacementTier.allCases {
            userDefaults.removeObject(forKey: "\(configKey)_\(tier.rawValue)")
            userDefaults.removeObject(forKey: "\(productsKey)_\(tier.rawValue)")
            userDefaults.removeObject(forKey: "\(productOrderKey)_\(tier.rawValue)")
        }
        userDefaults.removeObject(forKey: lastUpdateKey)
        paywallConfig = loadProjectConfig()
        productsCache.removeAll()
        productIdsOrder = []
        adaptyProductsCache = [:]
        storeKitProductsCache = [:]
        print("🗑️ [PaywallCacheManager] Кэш очищен")
        print("[paywall] PaywallCacheManager.clearCache: выполнено")
    }
    
    /// Количество генераций для продукта.
    /// Иерархия: Adapty/local generationLimits → парсинг числа из vendorProductId → парсинг из localizedTitle.
    func generationLimit(for vendorProductId: String, title: String? = nil) -> Int? {
        // 1. Из generationLimits (Adapty или локальный конфиг)
        if let limits = paywallConfig?.generationLimits, !limits.isEmpty {
            if let count = limits[vendorProductId] { return count }
            let idTokens = Set(vendorProductId.components(separatedBy: "_"))
            let candidates = limits.keys.filter { key in
                let keyTokens = Set(key.components(separatedBy: "_"))
                return keyTokens.isSubset(of: idTokens)
            }
            if let best = candidates.max(by: { $0.count < $1.count }), let count = limits[best] {
                return count
            }
        }
        // 2. Парсинг числа из vendorProductId (например purchases_50 → 50)
        if let parsed = PaywallCacheManager.parseGenerationsFromTokens(vendorProductId) {
            return parsed
        }
        // 3. Парсинг числа из localizedTitle (например "Pack 100" → 100)
        if let t = title, let parsed = PaywallCacheManager.parseGenerationsFromTokens(t) {
            return parsed
        }
        return nil
    }

    /// Извлекает число из строки по токенам (разделители: _, пробел, -)
    /// purchases_50 → 50, "Pack 100" → 100; чисто текстовые product id без числового суффикса → nil
    static func parseGenerationsFromTokens(_ s: String) -> Int? {
        let separators = CharacterSet(charactersIn: "_ -")
        let tokens = s.components(separatedBy: separators)
        for token in tokens.reversed() {
            guard !token.isEmpty,
                  token.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                  let n = Int(token), n >= 10, n <= 999_999
            else { continue }
            return n
        }
        return nil
    }

    /// Устаревший метод — оставлен для совместимости, не использует join-all-digits
    static func parseGenerationsFromString(_ s: String) -> Int? {
        return parseGenerationsFromTokens(s)
    }
    
    /// Получить время последнего обновления кэша
    func getLastCacheUpdate() -> Date? {
        return userDefaults.object(forKey: lastUpdateKey) as? Date
    }
}

// MARK: - Default Configuration

extension PaywallConfig {
    // Тексты и список фич paywall по умолчанию — только в коде; product/adapty-контракты задаёт bundled JSON.
    static func getDefault() -> PaywallConfig {
        return PaywallConfig(
            title: "paywall_upgrade_to_pro",
            subtitle: "paywall_enjoy_all_features",
            features: [
                "feature_premium_styles",
                "feature_hd_quality",
                "feature_no_watermarks",
                "feature_priority_processing",
                "feature_advanced_editing"
            ],
            planIds: nil,
            purchasePlanIds: nil,
            trialsPlanIds: nil,
            generationLimits: nil,
            adapty: nil,
            ui: UIConfig.getDefault(),
            logic: LogicConfig.getDefault()
        )
    }
    
    /// Создать конфигурацию с частичными данными, заполнив недостающие поля значениями по умолчанию
    static func createWithDefaults(
        title: String? = nil,
        subtitle: String? = nil,
        features: [String]? = nil,
        planIds: [String]? = nil,
        purchasePlanIds: [String]? = nil,
        generationLimits: [String: Int]? = nil,
        adapty: PaywallAdaptyCatalog? = nil,
        ui: UIConfig? = nil,
        logic: LogicConfig? = nil
    ) -> PaywallConfig {
        let defaultConfig = getDefault()
        return PaywallConfig(
            title: title ?? defaultConfig.title,
            subtitle: subtitle ?? defaultConfig.subtitle,
            features: features ?? defaultConfig.features,
            planIds: planIds ?? defaultConfig.planIds,
            purchasePlanIds: purchasePlanIds ?? defaultConfig.purchasePlanIds,
            trialsPlanIds: defaultConfig.trialsPlanIds,
            generationLimits: generationLimits ?? defaultConfig.generationLimits,
            adapty: adapty ?? defaultConfig.adapty,
            ui: ui ?? defaultConfig.ui,
            logic: logic ?? defaultConfig.logic
        )
    }
}

// MARK: - Default UI Configuration

extension PaywallConfig.UIConfig {
    // Внешний вид paywall не дублируем в `paywall_config.json` — один источник правды здесь (remote по-прежнему может прислать override в `ui`).
    static func getDefault() -> PaywallConfig.UIConfig {
        return PaywallConfig.UIConfig(
                backgroundColor: "#171A21",
                primaryColor: "#FFFFFF",
                accentColor: "#8B5CF6",
                showMostPopularBadge: true,
                carouselAutoScroll: true,
                carouselInterval: 2.0,
                showSkipButton: false,
                skipButtonText: nil
        )
    }
    
    /// Создать UI конфигурацию с частичными данными
    static func createWithDefaults(
        backgroundColor: String? = nil,
        primaryColor: String? = nil,
        accentColor: String? = nil,
        showMostPopularBadge: Bool? = nil,
        carouselAutoScroll: Bool? = nil,
        carouselInterval: Double? = nil,
        showSkipButton: Bool? = nil,
        skipButtonText: String? = nil
    ) -> PaywallConfig.UIConfig {
        let defaultConfig = getDefault()
        
        return PaywallConfig.UIConfig(
            backgroundColor: backgroundColor ?? defaultConfig.backgroundColor,
            primaryColor: primaryColor ?? defaultConfig.primaryColor,
            accentColor: accentColor ?? defaultConfig.accentColor,
            showMostPopularBadge: showMostPopularBadge ?? defaultConfig.showMostPopularBadge,
            carouselAutoScroll: carouselAutoScroll ?? defaultConfig.carouselAutoScroll,
            carouselInterval: carouselInterval ?? defaultConfig.carouselInterval,
            showSkipButton: showSkipButton ?? defaultConfig.showSkipButton,
            skipButtonText: skipButtonText ?? defaultConfig.skipButtonText
        )
    }
}

// MARK: - Default Logic Configuration

extension PaywallConfig.LogicConfig {
    static let defaultStartingTokenBalance = 30
    static let defaultDailyTokenAllowance = 10
    static let defaultTokensPerEffectGeneration = 25
    static let defaultPromptVideoTokensPerSecond = 5
    static let defaultPromptVideoAudioAddonTokens = 2
    static let defaultPromptPhotoGenerationTokens = 1

    // Поведение paywall по умолчанию и fallback для токенов; bundled JSON/remote могут прислать частичный `logic`.
    static func getDefault() -> PaywallConfig.LogicConfig {
        return PaywallConfig.LogicConfig(
            defaultSelectedPlanIndex: 0,
            showTrialFirst: false,
            highlightAnnual: true,
            showSavingsPercentage: true,
            showPrivacyLinks: true,
            showcaseEnabled: true,
            freeGenerationsLimit: 3,
            showRatingAfterGenerations: [2, 10, 50],
            showPaywallAfterOnboarding: false,
            startingTokenBalance: defaultStartingTokenBalance,
            dailyTokenAllowance: defaultDailyTokenAllowance,
            tokensPerEffectGeneration: defaultTokensPerEffectGeneration,
            promptVideoTokensPerSecond: defaultPromptVideoTokensPerSecond,
            promptVideoAudioAddonTokens: defaultPromptVideoAudioAddonTokens,
            promptPhotoGenerationTokens: defaultPromptPhotoGenerationTokens
        )
    }
    
    /// Создать Logic конфигурацию с частичными данными
    static func createWithDefaults(
        defaultSelectedPlanIndex: Int? = nil,
        showTrialFirst: Bool? = nil,
        highlightAnnual: Bool? = nil,
        showSavingsPercentage: Bool? = nil,
        showPrivacyLinks: Bool? = nil,
        showcaseEnabled: Bool? = nil,
        freeGenerationsLimit: Int? = nil,
        showRatingAfterGenerations: [Int]? = nil,
        showPaywallAfterOnboarding: Bool? = nil,
        startingTokenBalance: Int? = nil,
        dailyTokenAllowance: Int? = nil,
        tokensPerEffectGeneration: Int? = nil,
        promptVideoTokensPerSecond: Int? = nil,
        promptVideoAudioAddonTokens: Int? = nil,
        promptPhotoGenerationTokens: Int? = nil
    ) -> PaywallConfig.LogicConfig {
        let defaultConfig = getDefault()
        return PaywallConfig.LogicConfig(
            defaultSelectedPlanIndex: defaultSelectedPlanIndex ?? defaultConfig.defaultSelectedPlanIndex,
            showTrialFirst: showTrialFirst ?? defaultConfig.showTrialFirst,
            highlightAnnual: highlightAnnual ?? defaultConfig.highlightAnnual,
            showSavingsPercentage: showSavingsPercentage ?? defaultConfig.showSavingsPercentage,
            showPrivacyLinks: showPrivacyLinks ?? defaultConfig.showPrivacyLinks,
            showcaseEnabled: showcaseEnabled ?? defaultConfig.showcaseEnabled,
            freeGenerationsLimit: freeGenerationsLimit ?? defaultConfig.freeGenerationsLimit,
            showRatingAfterGenerations: showRatingAfterGenerations ?? defaultConfig.showRatingAfterGenerations,
            showPaywallAfterOnboarding: showPaywallAfterOnboarding ?? defaultConfig.showPaywallAfterOnboarding,
            startingTokenBalance: startingTokenBalance ?? defaultConfig.startingTokenBalance,
            dailyTokenAllowance: dailyTokenAllowance ?? defaultConfig.dailyTokenAllowance,
            tokensPerEffectGeneration: tokensPerEffectGeneration ?? defaultConfig.tokensPerEffectGeneration,
            promptVideoTokensPerSecond: promptVideoTokensPerSecond ?? defaultConfig.promptVideoTokensPerSecond,
            promptVideoAudioAddonTokens: promptVideoAudioAddonTokens ?? defaultConfig.promptVideoAudioAddonTokens,
            promptPhotoGenerationTokens: promptPhotoGenerationTokens ?? defaultConfig.promptPhotoGenerationTokens
        )
    }

    /// Слой Adapty поверх bundled `logic`: optional-поля не затираем nil из «пустого» remote.
    static func mergedRemote(_ remote: PaywallConfig.LogicConfig, over base: PaywallConfig.LogicConfig) -> PaywallConfig.LogicConfig {
        PaywallConfig.LogicConfig(
            defaultSelectedPlanIndex: remote.defaultSelectedPlanIndex,
            showTrialFirst: remote.showTrialFirst ?? base.showTrialFirst,
            highlightAnnual: remote.highlightAnnual ?? base.highlightAnnual,
            showSavingsPercentage: remote.showSavingsPercentage ?? base.showSavingsPercentage,
            showPrivacyLinks: remote.showPrivacyLinks,
            showcaseEnabled: remote.showcaseEnabled ?? base.showcaseEnabled,
            freeGenerationsLimit: remote.freeGenerationsLimit ?? base.freeGenerationsLimit,
            showRatingAfterGenerations: remote.showRatingAfterGenerations ?? base.showRatingAfterGenerations,
            showPaywallAfterOnboarding: remote.showPaywallAfterOnboarding ?? base.showPaywallAfterOnboarding,
            startingTokenBalance: remote.startingTokenBalance ?? base.startingTokenBalance,
            dailyTokenAllowance: remote.dailyTokenAllowance ?? base.dailyTokenAllowance,
            tokensPerEffectGeneration: remote.tokensPerEffectGeneration ?? base.tokensPerEffectGeneration,
            promptVideoTokensPerSecond: remote.promptVideoTokensPerSecond ?? base.promptVideoTokensPerSecond,
            promptVideoAudioAddonTokens: remote.promptVideoAudioAddonTokens ?? base.promptVideoAudioAddonTokens,
            promptPhotoGenerationTokens: remote.promptPhotoGenerationTokens ?? base.promptPhotoGenerationTokens
        )
    }
}