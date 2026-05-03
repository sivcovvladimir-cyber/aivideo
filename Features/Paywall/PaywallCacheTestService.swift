import Foundation

/// Тестовый сервис для демонстрации работы с кэшем paywall
class PaywallCacheTestService {
    static let shared = PaywallCacheTestService()
    
    private init() {}
    
    /// Тестировать загрузку и кэширование данных
    func testCacheLoading() {
        print("🧪 [PaywallCacheTestService] Тестируем загрузку кэша...")
        
        let cacheManager = PaywallCacheManager.shared
        
        // Проверяем текущий статус кэша
        print("📊 Статус кэша:")
        print("   - Есть данные: \(cacheManager.hasCachedData())")
        print("   - Последнее обновление: \(cacheManager.getLastCacheUpdate()?.description ?? "Нет")")
        
        // Загружаем данные
        cacheManager.loadAndCachePaywallData { success in
            print("✅ Результат загрузки: \(success)")
            
            if success {
                self.printCacheInfo()
            }
        }
    }
    
    /// Вывести информацию о кэше
    func printCacheInfo() {
        let cacheManager = PaywallCacheManager.shared
        
        print("📦 Информация о кэше:")
        
        if let config = cacheManager.paywallConfig {
            print("   Конфигурация:")
            print("     - Заголовок: \(config.title)")
            print("     - Подзаголовок: \(config.subtitle)")
            print("     - Планы: \(config.planIds)")
            print("     - Фичи: \(config.features.count)")
            print("     - Дефолтный план: \(config.logic.defaultSelectedPlanIndex)")
        } else {
            print("   Конфигурация: Нет данных")
        }
        
        print("   Продукты: \(cacheManager.productsCache.count)")
        for (id, product) in cacheManager.productsCache {
            print("     - \(id): \(product.localizedTitle) (\(product.localizedPrice))")
        }
        
        let paywallProducts = cacheManager.getPaywallProducts()
        print("   Продукты для paywall: \(paywallProducts.count)")
        for product in paywallProducts {
            print("     - \(product.vendorProductId): \(product.localizedTitle)")
        }
    }
    
    /// Создать тестовую конфигурацию
    func createTestConfig() -> PaywallConfig {
        return PaywallConfig(
            title: "Test Paywall",
            subtitle: "Test subtitle",
            features: [
                "Test feature 1",
                "Test feature 2",
                "Test feature 3"
            ],
            planIds: ["test_annual", "test_weekly"],
            purchasePlanIds: nil,
            trialsPlanIds: nil,
            generationLimits: nil,
            adapty: nil,
            ui: PaywallConfig.UIConfig(
                backgroundColor: "#000000",
                primaryColor: "#FFFFFF",
                accentColor: "#FF0000",
                showMostPopularBadge: true,
                carouselAutoScroll: false,
                carouselInterval: 3.0,
                showSkipButton: true,
                skipButtonText: "Skip"
            ),
            logic: PaywallConfig.LogicConfig(
                defaultSelectedPlanIndex: 1,
                showTrialFirst: true,
                highlightAnnual: false,
                showSavingsPercentage: false,
                showPrivacyLinks: false,
                showcaseEnabled: false,
                freeGenerationsLimit: nil,
                showRatingAfterGenerations: nil,
                showPaywallAfterOnboarding: nil,
                startingTokenBalance: 30,
                dailyTokenAllowance: 10,
                tokensPerEffectGeneration: 25,
                promptVideoTokensPerSecond: 5,
                promptVideoAudioAddonTokens: 2,
                promptPhotoGenerationTokens: 1
            )
        )
    }
    
    /// Создать тестовые продукты
    func createTestProducts() -> [String: ProductInfo] {
        return [
            "test_annual": ProductInfo(
                vendorProductId: "test_annual",
                localizedTitle: "Annual Test",
                localizedDescription: "Annual subscription for testing",
                localizedPrice: "$29.99",
                currencyCode: "USD",
                subscriptionPeriod: "year",
                trialPeriod: nil,
                isTrial: false
            ),
            "test_weekly": ProductInfo(
                vendorProductId: "test_weekly",
                localizedTitle: "Weekly Test",
                localizedDescription: "Weekly subscription for testing",
                localizedPrice: "$4.99",
                currencyCode: "USD",
                subscriptionPeriod: "week",
                trialPeriod: "3 days",
                isTrial: true
            )
        ]
    }
    
    /// Симулировать загрузку данных
    func simulateDataLoading() {
        print("🔄 [PaywallCacheTestService] Симулируем загрузку данных...")
        
        let cacheManager = PaywallCacheManager.shared
        
        // Симулируем загрузку конфигурации
        let testConfig = createTestConfig()
        cacheManager.paywallConfig = testConfig
        
        // Симулируем загрузку продуктов
        let testProducts = createTestProducts()
        cacheManager.productsCache = testProducts
        
        print("✅ Тестовые данные загружены")
        printCacheInfo()
    }
    
    /// Очистить кэш
    func clearCache() {
        print("🗑️ [PaywallCacheTestService] Очищаем кэш...")
        PaywallCacheManager.shared.clearCache()
        print("✅ Кэш очищен")
    }
    
    /// Тестировать различные сценарии
    func runAllTests() {
        print("🧪 [PaywallCacheTestService] Запускаем все тесты...")
        
        // Тест 1: Очистка кэша
        clearCache()
        
        // Тест 2: Симуляция загрузки
        simulateDataLoading()
        
        // Тест 3: Проверка данных
        printCacheInfo()
        
        // Тест 4: Очистка
        clearCache()
        
        print("✅ Все тесты завершены")
    }
} 