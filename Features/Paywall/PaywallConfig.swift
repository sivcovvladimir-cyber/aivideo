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

/// Один placement в Adapty (без разбиения по tier). Поддерживаем `placementId` и legacy-формат с `placements`.
struct PaywallAdaptyCatalog: Equatable {
    let placementId: String?
    init(placementId: String?) { self.placementId = placementId }

    /// Remote поверх bundled: непустые поля remote перекрывают base.
    static func mergedOverlay(remote: PaywallAdaptyCatalog?, base: PaywallAdaptyCatalog?) -> PaywallAdaptyCatalog? {
        switch (remote, base) {
        case (nil, nil): return nil
        case (let r?, nil): return r
        case (nil, let b?): return b
        case (let r?, let b?):
            return PaywallAdaptyCatalog(
                placementId: coalesceNonEmpty(r.placementId, b.placementId)
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
        case placement_id
        case placements
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(placementId, forKey: .placementId)
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
    /// Порядок отображения подписок (vendorProductId). Как в конфиге — так и показываем.
    let planIds: [String]?
    /// Порядок отображения разовых пакетов (vendorProductId). Как в конфиге — так и показываем.
    let purchasePlanIds: [String]?
    /// ID планов с триалом (для совместимости со старыми payload).
    let trialsPlanIds: [String]?
    /// Единственный `placementId` в Adapty.
    let adapty: PaywallAdaptyCatalog?
    /// Локальный первоисточник логики + overlay из Adapty.
    let logic: LogicConfig

    struct LogicConfig: Codable {
        /// После каких по счёту успешных генераций показывать запрос оценки.
        let showRatingAfterGenerations: [Int]?
        /// Показывать ли paywall после завершения онбординга.
        let showPaywallAfterOnboarding: Bool?
        /// Лимиты генераций по продуктам (ключ — `vendorProductId`).
        let generationLimits: [String: Int]?
        /// Рельсы главной и «View all»: включать motion-превью карточек.
        let effectsCatalogAllowsMotionPreview: Bool?
        /// Постер каталога до motion: `true` — jpeg может быть виден, пока грузится превью; `false` — для WebP/GIF до готового motion не показываем ни jpeg, ни лоадер, а для mp4 при «холодном» старте постер всё же держим до готовности плеера (см. `PreviewMediaView`).
        let effectsCatalogShowPosterBeforeMotion: Bool?
        /// Стартовый баланс токенов для token wallet.
        let startingTokenBalance: Int?
        /// Дневной минимум токенов при новом дне.
        let dailyTokenAllowance: Int?
        /// Цена generation по эффекту, когда token_cost отсутствует в БД.
        let tokensPerEffectGeneration: Int?
        /// Цена prompt-video за секунду.
        let promptVideoTokensPerSecond: Int?
        /// Доплата за аудио за каждую секунду prompt-video.
        let promptVideoAudioAddonTokens: Int?
        /// Цена prompt-photo generation.
        let promptPhotoGenerationTokens: Int?

        init(
            showRatingAfterGenerations: [Int]? = nil,
            showPaywallAfterOnboarding: Bool? = nil,
            generationLimits: [String: Int]? = nil,
            effectsCatalogAllowsMotionPreview: Bool? = nil,
            effectsCatalogShowPosterBeforeMotion: Bool? = nil,
            startingTokenBalance: Int? = nil,
            dailyTokenAllowance: Int? = nil,
            tokensPerEffectGeneration: Int? = nil,
            promptVideoTokensPerSecond: Int? = nil,
            promptVideoAudioAddonTokens: Int? = nil,
            promptPhotoGenerationTokens: Int? = nil
        ) {
            self.showRatingAfterGenerations = showRatingAfterGenerations
            self.showPaywallAfterOnboarding = showPaywallAfterOnboarding
            self.generationLimits = generationLimits
            self.effectsCatalogAllowsMotionPreview = effectsCatalogAllowsMotionPreview
            self.effectsCatalogShowPosterBeforeMotion = effectsCatalogShowPosterBeforeMotion
            self.startingTokenBalance = startingTokenBalance
            self.dailyTokenAllowance = dailyTokenAllowance
            self.tokensPerEffectGeneration = tokensPerEffectGeneration
            self.promptVideoTokensPerSecond = promptVideoTokensPerSecond
            self.promptVideoAudioAddonTokens = promptVideoAudioAddonTokens
            self.promptPhotoGenerationTokens = promptPhotoGenerationTokens
        }

        enum CodingKeys: String, CodingKey {
            case showRatingAfterGenerations, showPaywallAfterOnboarding, generationLimits
            case effectsCatalogAllowsMotionPreview, effects_catalog_allows_motion_preview
            case effectsCatalogShowPosterBeforeMotion, effects_catalog_show_poster_before_motion
            case startingTokenBalance, dailyTokenAllowance, tokensPerEffectGeneration
            case promptVideoTokensPerSecond, promptVideoAudioAddonTokens, promptPhotoGenerationTokens
            case starting_token_balance, daily_token_allowance, tokens_per_effect_generation
            case prompt_video_tokens_per_second, prompt_video_audio_addon_tokens, prompt_photo_generation_tokens
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showRatingAfterGenerations = try c.decodeIfPresent([Int].self, forKey: .showRatingAfterGenerations)
            showPaywallAfterOnboarding = try c.decodeIfPresent(Bool.self, forKey: .showPaywallAfterOnboarding)
            generationLimits = try c.decodeIfPresent([String: Int].self, forKey: .generationLimits)
            effectsCatalogAllowsMotionPreview =
                try c.decodeIfPresent(Bool.self, forKey: .effectsCatalogAllowsMotionPreview)
                ?? c.decodeIfPresent(Bool.self, forKey: .effects_catalog_allows_motion_preview)
            effectsCatalogShowPosterBeforeMotion =
                try c.decodeIfPresent(Bool.self, forKey: .effectsCatalogShowPosterBeforeMotion)
                ?? c.decodeIfPresent(Bool.self, forKey: .effects_catalog_show_poster_before_motion)
            startingTokenBalance =
                try c.decodeIfPresent(Int.self, forKey: .startingTokenBalance)
                ?? c.decodeIfPresent(Int.self, forKey: .starting_token_balance)
            dailyTokenAllowance =
                try c.decodeIfPresent(Int.self, forKey: .dailyTokenAllowance)
                ?? c.decodeIfPresent(Int.self, forKey: .daily_token_allowance)
            tokensPerEffectGeneration =
                try c.decodeIfPresent(Int.self, forKey: .tokensPerEffectGeneration)
                ?? c.decodeIfPresent(Int.self, forKey: .tokens_per_effect_generation)
            promptVideoTokensPerSecond =
                try c.decodeIfPresent(Int.self, forKey: .promptVideoTokensPerSecond)
                ?? c.decodeIfPresent(Int.self, forKey: .prompt_video_tokens_per_second)
            promptVideoAudioAddonTokens =
                try c.decodeIfPresent(Int.self, forKey: .promptVideoAudioAddonTokens)
                ?? c.decodeIfPresent(Int.self, forKey: .prompt_video_audio_addon_tokens)
            promptPhotoGenerationTokens =
                try c.decodeIfPresent(Int.self, forKey: .promptPhotoGenerationTokens)
                ?? c.decodeIfPresent(Int.self, forKey: .prompt_photo_generation_tokens)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(showRatingAfterGenerations, forKey: .showRatingAfterGenerations)
            try c.encodeIfPresent(showPaywallAfterOnboarding, forKey: .showPaywallAfterOnboarding)
            try c.encodeIfPresent(generationLimits, forKey: .generationLimits)
            try c.encodeIfPresent(effectsCatalogAllowsMotionPreview, forKey: .effectsCatalogAllowsMotionPreview)
            try c.encodeIfPresent(effectsCatalogShowPosterBeforeMotion, forKey: .effectsCatalogShowPosterBeforeMotion)
            try c.encodeIfPresent(startingTokenBalance, forKey: .startingTokenBalance)
            try c.encodeIfPresent(dailyTokenAllowance, forKey: .dailyTokenAllowance)
            try c.encodeIfPresent(tokensPerEffectGeneration, forKey: .tokensPerEffectGeneration)
            try c.encodeIfPresent(promptVideoTokensPerSecond, forKey: .promptVideoTokensPerSecond)
            try c.encodeIfPresent(promptVideoAudioAddonTokens, forKey: .promptVideoAudioAddonTokens)
            try c.encodeIfPresent(promptPhotoGenerationTokens, forKey: .promptPhotoGenerationTokens)
        }
    }

    /// Явный инициализатор нужен для создания merged-конфига (base + Adapty overlay).
    init(
        planIds: [String]?,
        purchasePlanIds: [String]?,
        trialsPlanIds: [String]?,
        adapty: PaywallAdaptyCatalog?,
        logic: LogicConfig
    ) {
        self.planIds = planIds
        self.purchasePlanIds = purchasePlanIds
        self.trialsPlanIds = trialsPlanIds
        self.adapty = adapty
        self.logic = logic
    }
}

extension PaywallConfig {
    enum CodingKeys: String, CodingKey {
        case planIds, purchasePlanIds, trialsPlanIds, generationLimits, adapty, logic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planIds = try c.decodeIfPresent([String].self, forKey: .planIds)
        purchasePlanIds = try c.decodeIfPresent([String].self, forKey: .purchasePlanIds)
        trialsPlanIds = try c.decodeIfPresent([String].self, forKey: .trialsPlanIds)
        adapty = try c.decodeIfPresent(PaywallAdaptyCatalog.self, forKey: .adapty)
        // Legacy: корневой `generationLimits` (до переноса в `logic`) объединяем с вложенным `logic.generationLimits`.
        let legacyRootLimits = try c.decodeIfPresent([String: Int].self, forKey: .generationLimits)
        var decodedLogic = try c.decodeIfPresent(LogicConfig.self, forKey: .logic) ?? LogicConfig()
        if let legacyRootLimits, !legacyRootLimits.isEmpty {
            decodedLogic = decodedLogic.mergingRootLegacyGenerationLimits(legacyRootLimits)
        }
        logic = decodedLogic
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(planIds, forKey: .planIds)
        try c.encodeIfPresent(purchasePlanIds, forKey: .purchasePlanIds)
        try c.encodeIfPresent(trialsPlanIds, forKey: .trialsPlanIds)
        try c.encodeIfPresent(adapty, forKey: .adapty)
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
    /// Единица периода (`month`, `year`, …) для UI; из StoreKit/Adapty.
    let subscriptionPeriod: String?
    /// Число единиц периода (например 3 при `month`); nil в старых снимках кэша.
    let subscriptionPeriodUnitCount: Int?
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
        // Как в storecards: до сети показываем последний merged `logic` из UD, а контракт продуктов/placement — из свежего бандла (не затираем placementId старым кэшем).
        paywallConfig = Self.rebasedPaywallConfigFromDiskCache(bundle: loadProjectConfig())

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
    
    /// Загрузить и кэшировать конфигурацию paywall и продукты (async).
    /// Зачем: первый проход даёт быстрый cache-first, второй (forceRefresh) подтягивает свежие данные из сети.
    @discardableResult
    func loadAndCachePaywallDataAsync(forceRefresh: Bool = false, updatesLoadingIndicator: Bool = true) async -> Bool {
        if updatesLoadingIndicator {
            await MainActor.run { isLoading = true; error = nil }
        }
        print("🔄 [PaywallCacheManager] Начинаем загрузку данных paywall...")
        print("[paywall] loadAndCachePaywallDataAsync: старт tier=\(currentPlacementTier.rawValue) productsCache.count=\(productsCache.count) forceRefresh=\(forceRefresh) updatesLoadingIndicator=\(updatesLoadingIndicator)")

        // Сначала remote merge, потом продукты: один согласованный getPaywall (как в storecards), меньше гонок между config и products.
        let configLoaded = await loadPaywallConfigAsync(forceRefresh: forceRefresh)
        let productsLoaded = await loadProductsAsync(forceRefresh: forceRefresh)

        if updatesLoadingIndicator {
            await MainActor.run { self.isLoading = false }
        }

        if configLoaded && productsLoaded {
            print("✅ [PaywallCacheManager] Все данные успешно загружены и кэшированы")
            print("[paywall] loadAndCachePaywallDataAsync: успех config+products productsCache.count=\(productsCache.count) planIds=\(String(describing: paywallConfig?.planIds)) purchasePlanIds=\(String(describing: paywallConfig?.purchasePlanIds))")
            await MainActor.run { self.updateLastCacheTime() }
        } else {
            print("⚠️ [PaywallCacheManager] Частичная загрузка: config=\(configLoaded), products=\(productsLoaded)")
            print("[paywall] loadAndCachePaywallDataAsync: частично config=\(configLoaded) products=\(productsLoaded) productsCache.count=\(productsCache.count)")
        }
        return configLoaded && productsLoaded
    }

    /// Обёртка для обратной совместимости
    func loadAndCachePaywallData(
        forceRefresh: Bool = false,
        updatesLoadingIndicator: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            let result = await loadAndCachePaywallDataAsync(
                forceRefresh: forceRefresh,
                updatesLoadingIndicator: updatesLoadingIndicator
            )
            completion(result)
        }
    }

    /// Строковый ключ единицы периода для кэша и PaywallView (не `rawValue` enum unit — у Adapty это не String).
    private static func adaptySubscriptionPeriodUnitKey(_ unit: AdaptySubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        case .unknown: return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    /// Восстанавливаем последний merged `logic` из UserDefaults поверх актуального бандла (planIds / adapty — только из bundle).
    private static func rebasedPaywallConfigFromDiskCache(bundle: PaywallConfig) -> PaywallConfig {
        let ud = UserDefaults.standard
        let key = "cached_paywall_config"
        guard let data = ud.data(forKey: key),
              let cached = try? JSONDecoder().decode(PaywallConfig.self, from: data)
        else {
            print("[paywall] rebasedPaywallConfigFromDiskCache: нет \"cached_paywall_config\" — только bundle")
            return bundle
        }
        let logic = PaywallConfig.LogicConfig.mergedRemote(cached.logic, over: bundle.logic)
        print("[paywall] rebasedPaywallConfigFromDiskCache: logic из UD rebased на bundle placement/planIds")
        return PaywallConfig(
            planIds: bundle.planIds,
            purchasePlanIds: bundle.purchasePlanIds,
            trialsPlanIds: bundle.trialsPlanIds,
            adapty: bundle.adapty,
            logic: logic
        )
    }

    /// Загрузить конфигурацию paywall из Adapty (чистая async-функция)
    private func loadPaywallConfigAsync(forceRefresh: Bool = false) async -> Bool {
        await MainActor.run {
            self.hasAttemptedRemoteConfigLoad = true
            self.isRemotePaywallConfigLoadFinished = false
            self.isRemotePaywallConfigLoadSucceeded = false
        }

        let baseConfig = loadProjectConfig()
        print("📁 [PaywallCacheManager] Базовая конфигурация из проекта загружена")
        let pl = (try? configuredAdaptyPlacementId()) ?? "(ошибка placement)"
        print("[paywall] loadPaywallConfigAsync: bundled placementId=\(pl) planIds=\(String(describing: baseConfig.planIds)) purchasePlanIds=\(String(describing: baseConfig.purchasePlanIds))")

        if let adaptyOverlay = await AdaptyService.shared.fetchPaywallConfigOverlayAsync(forceRefresh: forceRefresh) {
            let mergedConfig = mergeConfigs(base: baseConfig, adapty: adaptyOverlay)
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
        }

        await MainActor.run {
            print("⚠️ [PaywallCacheManager] Remote overlay не получен — не перезаписываем cached_paywall_config; in-memory оставляем текущий конфиг")
            if self.paywallConfig == nil {
                self.paywallConfig = Self.rebasedPaywallConfigFromDiskCache(bundle: baseConfig)
            }
            self.isRemotePaywallConfigLoadFinished = true
            self.isRemotePaywallConfigLoadSucceeded = false
        }
        return true
    }
    
    /// Загрузить информацию о продуктах из Adapty, с локальным StoreKit fallback для разработки.
    private func loadProductsAsync(forceRefresh: Bool = false) async -> Bool {
        #if targetEnvironment(simulator)
        // Тот же StoreKit 2 под капотом Adapty.getPaywallProducts; на симуляторе с .storekit в схеме первый запрос в первые миллисекунды после launch часто даёт noProductIDsFound.
        if !forceRefresh {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        #endif
        print("[paywall] loadProductsAsync: запрос продуктов через Adapty.getPaywallProducts…")
        do {
            let products = try await AdaptyService.shared.fetchProductsAsync(forceRefresh: forceRefresh)
            var productsInfo: [String: ProductInfo] = [:]
            var order: [String] = []
            var cache: [String: AdaptyPaywallProduct] = [:]

            for product in products {
                let skPeriod = product.subscriptionPeriod
                productsInfo[product.vendorProductId] = ProductInfo(
                    vendorProductId: product.vendorProductId,
                    localizedTitle: product.localizedTitle,
                    localizedDescription: product.localizedDescription,
                    localizedPrice: product.localizedPrice ?? "",
                    currencyCode: product.currencyCode,
                    subscriptionPeriod: skPeriod.map { Self.adaptySubscriptionPeriodUnitKey($0.unit) },
                    subscriptionPeriodUnitCount: skPeriod?.numberOfUnits,
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
                    subscriptionPeriodUnitCount: subscriptionPeriodUnitCount(for: product),
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

        /// P1W / P3M / P1Y из локального `.storekit` → число единиц периода для `ProductInfo`.
        private static func unitCount(fromISO8601Duration s: String?) -> Int? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("P"), s.count >= 3 else { return nil }
            let rest = s.dropFirst()
            let digits = rest.prefix(while: { $0.isNumber })
            return Int(digits).flatMap { $0 >= 1 ? $0 : nil }
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
                subscriptionPeriodUnitCount: Self.unitCount(fromISO8601Duration: recurringSubscriptionPeriod),
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

    private func subscriptionPeriodUnitCount(for product: StoreKit.Product) -> Int? {
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
        let n = period.value
        return n >= 1 ? n : nil
    }
    
    // MARK: - Project Configuration
    
    /// Загрузить базовую конфигурацию из JSON файла проекта.
    /// Результат кешируется в памяти — файл из Bundle не меняется в рантайме, читаем один раз.
    private func loadProjectConfig() -> PaywallConfig {
        if let cached = bundleConfigCache { return cached }

        print("🔍 [PaywallCacheManager] Ищем paywall_config.json в Bundle...")

        guard let url = Bundle.main.url(forResource: "paywall_config", withExtension: "json") else {
            print("🚨 [PaywallCacheManager] Файл paywall_config.json не найден в Bundle")
            fatalError("paywall_config.json must exist in bundle")
        }

        print("✅ [PaywallCacheManager] Файл найден: \(url)")

        guard let data = try? Data(contentsOf: url) else {
            print("🚨 [PaywallCacheManager] Не удалось прочитать данные из файла")
            fatalError("Unable to read paywall_config.json from bundle")
        }

        print("✅ [PaywallCacheManager] Данные прочитаны, размер: \(data.count) байт")

        guard let config = try? JSONDecoder().decode(PaywallConfig.self, from: data) else {
            print("🚨 [PaywallCacheManager] Не удалось декодировать JSON")
            fatalError("Invalid paywall_config.json format")
        }

        print("📁 [PaywallCacheManager] Базовая конфигурация загружена из paywall_config.json")
        bundleConfigCache = config
        return config
    }
    
    /// Объединить базовую конфигурацию с настройками из Adapty
    private func mergeConfigs(base: PaywallConfig, adapty: PaywallConfig) -> PaywallConfig {
        // С Adapty подмешиваем только `logic` (включая `generationLimits` внутри него). Остальное — из бандла.
        let mergedLogic = PaywallConfig.LogicConfig.mergedRemote(adapty.logic, over: base.logic)
        print("[paywall] mergeConfigs: logic merged generationLimits.keys=\(mergedLogic.generationLimits?.keys.sorted() ?? []) motion=\(String(describing: mergedLogic.effectsCatalogAllowsMotionPreview)) poster=\(String(describing: mergedLogic.effectsCatalogShowPosterBeforeMotion))")

        return PaywallConfig(
            planIds: base.planIds,
            purchasePlanIds: base.purchasePlanIds,
            trialsPlanIds: base.trialsPlanIds,
            adapty: base.adapty,
            logic: mergedLogic
        )
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
        return 0
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
        if let limits = paywallConfig?.logic.generationLimits {
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
    /// Иерархия: `logic.generationLimits` (бандл + Adapty) → парсинг из vendorProductId → из localizedTitle.
    func generationLimit(for vendorProductId: String, title: String? = nil) -> Int? {
        // 1. Из `logic.generationLimits`
        if let limits = paywallConfig?.logic.generationLimits, !limits.isEmpty {
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

extension PaywallConfig.LogicConfig {
    /// Слой Adapty поверх bundled `logic`: сливаем только поля, пришедшие из remote; `generationLimits` мёржим по ключам.
    static func mergedRemote(_ remote: PaywallConfig.LogicConfig, over base: PaywallConfig.LogicConfig) -> PaywallConfig.LogicConfig {
        let mergedLimits: [String: Int]? = {
            switch (base.generationLimits, remote.generationLimits) {
            case (nil, let r): return r
            case (let b, nil): return b
            case (let b?, let r?): return b.merging(r) { _, adaptyValue in adaptyValue }
            }
        }()
        return PaywallConfig.LogicConfig(
            showRatingAfterGenerations: remote.showRatingAfterGenerations ?? base.showRatingAfterGenerations,
            showPaywallAfterOnboarding: remote.showPaywallAfterOnboarding ?? base.showPaywallAfterOnboarding,
            generationLimits: mergedLimits,
            effectsCatalogAllowsMotionPreview: remote.effectsCatalogAllowsMotionPreview ?? base.effectsCatalogAllowsMotionPreview,
            effectsCatalogShowPosterBeforeMotion: remote.effectsCatalogShowPosterBeforeMotion ?? base.effectsCatalogShowPosterBeforeMotion,
            startingTokenBalance: remote.startingTokenBalance ?? base.startingTokenBalance,
            dailyTokenAllowance: remote.dailyTokenAllowance ?? base.dailyTokenAllowance,
            tokensPerEffectGeneration: remote.tokensPerEffectGeneration ?? base.tokensPerEffectGeneration,
            promptVideoTokensPerSecond: remote.promptVideoTokensPerSecond ?? base.promptVideoTokensPerSecond,
            promptVideoAudioAddonTokens: remote.promptVideoAudioAddonTokens ?? base.promptVideoAudioAddonTokens,
            promptPhotoGenerationTokens: remote.promptPhotoGenerationTokens ?? base.promptPhotoGenerationTokens
        )
    }

    /// Legacy: корневой `generationLimits` в JSON до переноса в `logic` — при конфликте ключей побеждает вложенный `logic`.
    fileprivate func mergingRootLegacyGenerationLimits(_ legacy: [String: Int]) -> PaywallConfig.LogicConfig {
        let merged = legacy.merging(generationLimits ?? [:]) { _, fromLogic in fromLogic }
        return PaywallConfig.LogicConfig(
            showRatingAfterGenerations: showRatingAfterGenerations,
            showPaywallAfterOnboarding: showPaywallAfterOnboarding,
            generationLimits: merged.isEmpty ? nil : merged,
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

    /// Подмешивает лимиты из raw remote JSON (ключи overlay перекрывают текущие). Нужен `AdaptyService` при разборе сырого JSON.
    func mergingGenerationLimitsOverlay(_ overlay: [String: Int]) -> PaywallConfig.LogicConfig {
        let merged = (generationLimits ?? [:]).merging(overlay) { _, remote in remote }
        return PaywallConfig.LogicConfig(
            showRatingAfterGenerations: showRatingAfterGenerations,
            showPaywallAfterOnboarding: showPaywallAfterOnboarding,
            generationLimits: merged.isEmpty ? nil : merged,
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
}