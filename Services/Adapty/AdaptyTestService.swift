import Foundation
import Adapty

/// Тестовый сервис для проверки интеграции с Adapty
/// Используется только для разработки и тестирования
class AdaptyTestService {
    static let shared = AdaptyTestService()
    
    private init() {}
    
    /// Тестирует получение профиля пользователя
    func testProfileFetch(completion: @escaping (Bool) -> Void) {
        print("🧪 [AdaptyTestService] Тестируем получение профиля...")
        
        Task {
            do {
                let profile = try await Adapty.getProfile()
                    print("✅ [AdaptyTestService] Профиль получен успешно:")
                    print("   - Profile ID: \(profile.profileId)")
                    print("   - Access Levels: \(profile.accessLevels)")
                    print("   - Subscriptions: \(profile.subscriptions)")
                    completion(true)
            } catch {
                    print("🚨 [AdaptyTestService] Ошибка получения профиля: \(error)")
                    completion(false)
            }
        }
    }
    
    /// Тестирует получение продуктов
    func testProductsFetch(completion: @escaping (Bool) -> Void) {
        print("🧪 [AdaptyTestService] Тестируем получение продуктов...")
        
        Task {
            do {
                let tier = PaywallCacheManager.shared.currentPlacementTier
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                let paywall = try await Adapty.getPaywall(placementId: placementId)
                print("✅ [AdaptyTestService] Paywall получен успешно:")
                print("   - Revision: \(paywall.placement.revision)")
                print("   - Tier: \(tier.rawValue)")
                
                // Получаем продукты через другой метод
                let products = try await Adapty.getPaywallProducts(paywall: paywall)
                print("   - Products count: \(products.count)")
                
                    for (index, product) in products.enumerated() {
                        print("   \(index + 1). \(product.vendorProductId)")
                        print("      - Price: \(product.localizedPrice ?? "N/A")")
                        print("      - Currency: \(product.currencyCode ?? "N/A")")
                    if let period = product.subscriptionPeriod {
                        print("      - Period: \(period.unit)")
                    } else {
                        print("      - Period: N/A")
                    }
                    }
                    completion(true)
            } catch {
                    print("🚨 [AdaptyTestService] Ошибка получения продуктов: \(error)")
                    completion(false)
            }
        }
    }
    
    /// Тестирует получение paywall
    func testPaywallFetch(completion: @escaping (Bool) -> Void) {
        print("🧪 [AdaptyTestService] Тестируем получение paywall...")
        
        Task {
            do {
                let tier = PaywallCacheManager.shared.currentPlacementTier
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                let paywall = try await Adapty.getPaywall(placementId: placementId)
                    print("✅ [AdaptyTestService] Paywall получен успешно:")
                print("   - Revision: \(paywall.placement.revision)")
                print("   - Tier: \(tier.rawValue)")
                
                // Получаем продукты через другой метод
                let products = try await Adapty.getPaywallProducts(paywall: paywall)
                print("   - Products count: \(products.count)")
                    completion(true)
            } catch {
                    print("🚨 [AdaptyTestService] Ошибка получения paywall: \(error)")
                    completion(false)
            }
        }
    }
    
    /// Запускает все тесты
    func runAllTests(completion: @escaping ([String: Bool]) -> Void) {
        print("🧪 [AdaptyTestService] Запускаем все тесты Adapty...")
        
        var results: [String: Bool] = [:]
        let group = DispatchGroup()
        
        // Тест профиля
        group.enter()
        testProfileFetch { success in
            results["profile"] = success
            group.leave()
        }
        
        // Тест продуктов
        group.enter()
        testProductsFetch { success in
            results["products"] = success
            group.leave()
        }
        
        // Тест paywall
        group.enter()
        testPaywallFetch { success in
            results["paywall"] = success
            group.leave()
        }
        
        group.notify(queue: .main) {
            print("🧪 [AdaptyTestService] Результаты тестов:")
            for (test, success) in results {
                let status = success ? "✅" : "❌"
                print("   \(status) \(test)")
            }
            completion(results)
        }
    }
} 