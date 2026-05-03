import SwiftUI
import StoreKit

class RateService: ObservableObject {
    
    /// Открывает страницу приложения в App Store для рейтинга
    func rateApp() {
        // Получаем App Store ID из конфигурации
        guard let appStoreID = ConfigurationManager.shared.getValue(for: .appStoreID) else {
            print("❌ [RateService] App Store ID not configured")
            return
        }
        
        // Формируем URL для App Store с рейтингом
        let appStoreURL = "https://apps.apple.com/app/id\(appStoreID)?action=write-review"
        
        // Пытаемся открыть URL
        if let url = URL(string: appStoreURL) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url) { success in
                    if success {
                        print("✅ [RateService] Successfully opened App Store rating page")
                    } else {
                        print("❌ [RateService] Failed to open App Store rating page")
                    }
                }
            } else {
                print("❌ [RateService] Cannot open URL: \(appStoreURL)")
            }
        } else {
            print("❌ [RateService] Invalid URL: \(appStoreURL)")
        }
    }
    
    /// Показывает диалог рейтинга (iOS 14.0+)
    @available(iOS 14.0, *)
    func requestReview() {
        // Проверяем, доступен ли StoreKit
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
            print("✅ [RateService] Requested in-app review")
        } else {
            print("❌ [RateService] Could not get window scene for in-app review")
            // Fallback к обычному рейтингу
            rateApp()
        }
    }
} 