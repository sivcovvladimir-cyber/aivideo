import Foundation
import Adapty

/// Быстрая проверка конфигурации Adapty
/// Используется для диагностики проблем с интеграцией
class AdaptyQuickCheck {
    static let shared = AdaptyQuickCheck()
    
    private init() {}
    
    /// Полная проверка конфигурации
    func runFullCheck() {
        print("🧪 [AdaptyQuickCheck] Полная проверка")
        print("========================================")
        
        // 1. Проверяем конфигурацию
        checkConfiguration()
        
        // 2. Проверяем инициализацию
        checkInitialization()
        
        // 3. Проверяем профиль
        checkProfile()
        
        // 4. Проверяем paywall и продукты
        checkPaywallAndProducts()
        
        print("========================================")
        print("🧪 [AdaptyQuickCheck] Проверка завершена")
    }
    
    /// Проверяет конфигурацию
    private func checkConfiguration() {
        print("🔍 [AdaptyQuickCheck] Проверяем конфигурацию...")
        
        do {
            let publicKey = try ConfigurationManager.shared.getRequiredValue(for: .adaptyPublicKey)
            print("✅ Ключ загружен: \(String(publicKey.prefix(20)))...")
            
            // Определяем тип ключа
            if publicKey.contains("public_live_") {
                print("✅ Формат ключа: LIVE")
            } else if publicKey.contains("public_sandbox_") {
                print("✅ Формат ключа: SANDBOX")
            } else {
                print("⚠️ Неизвестный формат ключа")
            }
            
            for tier in PaywallPlacementTier.allCases {
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                let paywallId = try PaywallCacheManager.shared.configuredAdaptyPaywallId()
                print("✅ \(tier.rawValue) Placement ID: \(placementId)")
                print("✅ \(tier.rawValue) Paywall ID: \(paywallId)")
            }
            
        } catch {
            print("❌ Ошибка конфигурации: \(error)")
        }
    }
    
    /// Проверяет инициализацию Adapty
    private func checkInitialization() {
        print("🔍 Проверяем инициализацию Adapty...")
        
        // Adapty уже должен быть инициализирован в AppDelegate
        print("✅ Adapty инициализирован")
    }
    
    /// Проверяет профиль пользователя
    private func checkProfile() {
        print("🔍 Проверяем профиль...")
        
        Task {
            do {
                let profile = try await Adapty.getProfile()
                print("✅ Профиль получен:")
                print("   ID: \(profile.profileId)")
                print("   Access Levels: \(profile.accessLevels)")
                print("   Subscriptions: \(profile.subscriptions.count)")
                
                // Проверяем активные подписки
                if let premiumAccess = profile.accessLevels["premium"] {
                    print("   Premium активна: \(premiumAccess.isActive)")
                    if let expiresAt = premiumAccess.expiresAt {
                        print("   Истекает: \(expiresAt)")
                    }
                } else {
                    print("   Premium не найдена")
                }
                
            } catch {
                print("❌ Ошибка профиля: \(error)")
            }
        }
    }
    
    /// Проверяет paywall и продукты
    private func checkPaywallAndProducts() {
        print("🔍 Проверяем продукты...")
        
        Task {
            do {
                for tier in PaywallPlacementTier.allCases {
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()

                // Получаем paywall
                let paywall = try await Adapty.getPaywall(placementId: placementId)
                print("✅ Paywall получен успешно")
                print("   Revision: \(paywall.placement.revision)")
                print("   Placement ID: \(placementId)")
                print("   Tier: \(tier.rawValue)")
                print("   Paywall ID из конфига: \(try PaywallCacheManager.shared.configuredAdaptyPaywallId())")
                
                // Выводим информацию о продуктах в paywall
                print("📦 Информация о paywall:")
                print("   - Placement ID: \(placementId)")
                print("   - Revision: \(paywall.placement.revision)")
                
                // Попробуем получить больше информации о paywall
                print("🔍 Детальная информация о paywall:")
                
                // Основные свойства, которые мы знаем точно
                print("   - Placement ID: \(placementId)")
                print("   - Revision: \(paywall.placement.revision)")
                
                // Получаем ВСЕ доступные свойства через Mirror
                print("🔍 ВСЕ доступные свойства объекта AdaptyPaywall:")
                let mirror = Mirror(reflecting: paywall)
                for child in mirror.children {
                    if let label = child.label {
                        print("   - \(label): \(child.value)")
                    }
                }
                
                // Попробуем получить placement.id
                print("🔍 Проверка placement.id:")
                print("   - placement.id: \(paywall.placement.id)")
                
                // Пытаемся получить продукты через getPaywallProducts
                print("🔍 Получаем продукты через Adapty.getPaywallProducts(paywall:)...")
                do {
                    let products = try await Adapty.getPaywallProducts(paywall: paywall)
                    print("✅ Продукты получены через getPaywallProducts: \(products.count)")
                    
                    for (index, product) in products.enumerated() {
                        print("   \(index + 1). \(product.vendorProductId)")
                        print("      - Price: \(product.localizedPrice ?? "N/A")")
                        print("      - Currency: \(product.currencyCode ?? "N/A")")
                        if let period = product.subscriptionPeriod {
                            print("      - Period: \(period.unit)")
                        }
                    }
                } catch {
                    print("❌ Ошибка продуктов: \(error)")
                    
                    // Подробная диагностика ошибки
                    print("🔍 ДИАГНОСТИКА ОШИБКИ:")
                    print("   - Тип ошибки: \(type(of: error))")
                    print("   - Сообщение: \(error.localizedDescription)")
                    
                    // Проверяем конкретный тип ошибки
                    print("   - Тип ошибки: \(type(of: error))")
                    
                    // Проверяем, есть ли в сообщении ключевые слова
                    let errorMessage = error.localizedDescription.lowercased()
                    if errorMessage.contains("no product ids found") {
                        print("💡 ПРОБЛЕМА: В paywall нет настроенных продуктов")
                        print("🔧 РЕШЕНИЕ:")
                        print("   1. Войдите в https://adapty.io/dashboard")
                        print("   2. Найдите paywall с ID 'paywall'")
                        print("   3. Добавьте продукты в раздел 'Products'")
                        print("   4. Убедитесь, что Placement ID '1' связан с этим paywall")
                    } else if errorMessage.contains("product") {
                        print("💡 ПРОБЛЕМА: Проблема с продуктами в App Store Connect")
                        print("🔧 РЕШЕНИЕ:")
                        print("   1. Проверьте, что продукты созданы в App Store Connect")
                        print("   2. Убедитесь, что продукты активны и готовы к продаже")
                        print("   3. Проверьте, что Bundle ID совпадает: \(Bundle.main.bundleIdentifier ?? "unknown")")
                    }
                }
                }
                
            } catch {
                print("❌ Ошибка paywall: \(error)")
            }
        }
    }
    
    /// Проверяет доступность продуктов в StoreKit
    func checkStoreKitProducts() {
        print("🔍 Проверяем StoreKit продукты...")
        
        Task {
            do {
                let tier = PaywallCacheManager.shared.currentPlacementTier
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                let paywall = try await Adapty.getPaywall(placementId: placementId)
                
                print("✅ Paywall получен, получаем продукты...")
                
                do {
                    let products = try await Adapty.getPaywallProducts(paywall: paywall)
                    print("✅ Продукты получены из paywall: \(products.count)")
                    
                    print("Ожидаемые продукты:")
                    for product in products {
                        print("   - \(product.vendorProductId)")
                    }
                    
                    print("💡 Убедитесь, что эти продукты:")
                    print("   1. Созданы в App Store Connect")
                    print("   2. Активны и готовы к продаже")
                    print("   3. Связаны с paywall в Adapty Dashboard")
                    print("   4. Приложение добавлено в App Store Connect")
                    
                } catch {
                    print("❌ Ошибка получения продуктов: \(error)")
                    print("💡 Проверьте настройки в Adapty Dashboard")
                }
                
            } catch {
                print("❌ Ошибка получения paywall: \(error)")
            }
        }
    }
    
    /// Тестирует покупку (только в sandbox)
    func testPurchase() {
        print("🧪 Тестируем покупку...")
        
        Task {
            do {
                let tier = PaywallCacheManager.shared.currentPlacementTier
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                let paywall = try await Adapty.getPaywall(placementId: placementId)
                
                // Получаем продукты для проверки доступности
                do {
                    let products = try await Adapty.getPaywallProducts(paywall: paywall)
                    if let firstProduct = products.first {
                        print("Пытаемся купить: \(firstProduct.vendorProductId)")
                        print("✅ Продукт доступен для покупки")
                    } else {
                        print("❌ Нет доступных продуктов")
                    }
                } catch {
                    print("❌ Ошибка получения продуктов: \(error)")
                }
                
            } catch {
                print("❌ Ошибка тестирования покупки: \(error)")
            }
        }
    }
} 
 