import Foundation
import Adapty

/// Быстрый тест интеграции с Adapty
/// Можно запустить в Playground или отдельно для проверки
class AdaptyQuickTest {
    
    static func testConfiguration() {
        print("🧪 [AdaptyQuickTest] Начинаем тест конфигурации...")
        
        // Проверяем, что ключ загружается
        do {
            let adaptyKey = try ConfigurationManager.shared.getRequiredValue(for: .adaptyPublicKey)
            print("✅ [AdaptyQuickTest] Ключ Adapty загружен: \(adaptyKey.prefix(20))...")
            
            // Проверяем формат ключа
            if adaptyKey.hasPrefix("public_live_") {
                print("✅ [AdaptyQuickTest] Формат ключа корректный (live)")
            } else if adaptyKey.hasPrefix("public_sandbox_") {
                print("✅ [AdaptyQuickTest] Формат ключа корректный (sandbox)")
            } else {
                print("⚠️ [AdaptyQuickTest] Неизвестный формат ключа")
            }
            
        } catch {
            print("🚨 [AdaptyQuickTest] Ошибка загрузки ключа: \(error)")
        }
        
        // Проверяем другие ключи
        let keysToCheck = [
            ConfigurationManager.ConfigKey.supabaseURL,
            ConfigurationManager.ConfigKey.supabaseAnonKey,
            ConfigurationManager.ConfigKey.faceSwapAPIKey,
            ConfigurationManager.ConfigKey.faceSwapAPIURL,
            ConfigurationManager.ConfigKey.firebaseAPIKey
        ]
        
        for key in keysToCheck {
            do {
                let value = try ConfigurationManager.shared.getRequiredValue(for: key)
                print("✅ [AdaptyQuickTest] \(key.rawValue): \(value.prefix(20))...")
            } catch {
                print("🚨 [AdaptyQuickTest] Ошибка загрузки \(key.rawValue): \(error)")
            }
        }
    }
    
    static func testAdaptyInitialization() {
        print("🧪 [AdaptyQuickTest] Тестируем инициализацию Adapty...")
        
        do {
            let adaptyKey = try ConfigurationManager.shared.getRequiredValue(for: .adaptyPublicKey)
            
            // Инициализируем Adapty
            Adapty.activate(adaptyKey)
            print("✅ [AdaptyQuickTest] Adapty успешно инициализирован")
            
            // Пробуем получить профиль
            Adapty.getProfile { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let profile):
                        print("✅ [AdaptyQuickTest] Профиль получен:")
                        print("   - Profile ID: \(profile.profileId)")
                        print("   - Access Levels: \(profile.accessLevels)")
                        print("   - Subscriptions count: \(profile.subscriptions.count)")
                        
                    case .failure(let error):
                        print("🚨 [AdaptyQuickTest] Ошибка получения профиля: \(error)")
                    }
                }
            }
            
        } catch {
            print("🚨 [AdaptyQuickTest] Ошибка инициализации: \(error)")
        }
    }
    
    static func runAllTests() {
        print("🧪 [AdaptyQuickTest] Запускаем все тесты...")
        print(String(repeating: "=", count: 50))
        
        testConfiguration()
        print(String(repeating: "-", count: 30))
        testAdaptyInitialization()
        
        print(String(repeating: "=", count: 50))
        print("🧪 [AdaptyQuickTest] Тесты завершены")
    }
}

 