import Foundation
import YandexMobileMetrica
import FirebaseAnalytics
import AppsFlyerLib

class AppMetricaService {
    static let shared = AppMetricaService()
    
    private init() {}
    
    // MARK: - Initialization
    
    func initialize() {
        guard let apiKey = getAPIKey() else {
            print("❌ [AppMetrica] API key not found")
            return
        }
        
        let configuration = YMMYandexMetricaConfiguration(apiKey: apiKey)
        configuration.logs = true // Включаем логи для отладки
        
        YMMYandexMetrica.activate(with: configuration)
        print("✅ [AppMetrica] Initialized with API key: \(apiKey)")
    }
    
    // MARK: - API Key
    
    private func getAPIKey() -> String? {
        guard let path = Bundle.main.path(forResource: "APIKeys", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let apiKey = plist["YANDEX_APPMETRICA_API_KEY"] as? String,
              apiKey != "YOUR_YANDEX_APPMETRICA_API_KEY" else {
            return nil
        }
        return apiKey
    }
    
    // MARK: - Events
    
    func reportEvent(_ event: String, parameters: [String: Any]? = nil) {
        // Report to AppMetrica
        YMMYandexMetrica.reportEvent(event, parameters: parameters) { error in
            if let error = error {
                print("❌ [AppMetrica] Failed to report event '\(event)': \(error)")
            } else {
                print("✅ [AppMetrica] Event reported: \(event)")
            }
        }
        
        // Report to Firebase Analytics
        Analytics.logEvent(event, parameters: parameters)
        print("✅ [Firebase] Event reported: \(event)")
        
        // Report to Adapty
        AdaptyService.shared.logEvent(event, parameters: parameters)
        
        // Report to AppsFlyer
        AppsFlyerLib.shared().logEvent(event, withValues: parameters)
        // AppsFlyer event reported
    }
    
    // MARK: - User Properties
    
    func setUserProperty(_ property: String, value: String) {
        YMMYandexMetrica.setUserProfileValue(YMMProfileAttribute.customString(property), for: value)
        print("✅ [AppMetrica] User property set: \(property) = \(value)")
        
        // Set user property in Firebase Analytics
        Analytics.setUserProperty(value, forName: property)
        print("✅ [Firebase] User property set: \(property) = \(value)")
        
        // Set user property in AppsFlyer
        AppsFlyerLib.shared().setAdditionalData([property: value])
        // AppsFlyer user property set
    }
    
    func setUserID(_ userID: String) {
        YMMYandexMetrica.setUserProfileID(userID)
        print("✅ [AppMetrica] User ID set: \(userID)")
        
        // Set user ID in Firebase Analytics
        Analytics.setUserID(userID)
        print("✅ [Firebase] User ID set: \(userID)")
        
        // Set user ID in AppsFlyer
        AppsFlyerLib.shared().setCustomerUserID(userID)
        // AppsFlyer User ID set
    }
    
    // MARK: - Revenue Tracking
    
    func reportRevenue(price: Double, currency: String, productID: String) {
        let revenue = YMMRevenueInfo(priceDecimal: NSDecimalNumber(value: price), currency: currency)
        revenue.productID = productID
        
        YMMYandexMetrica.reportRevenue(revenue) { error in
            if let error = error {
                print("❌ [AppMetrica] Failed to report revenue: \(error)")
            } else {
                print("✅ [AppMetrica] Revenue reported: \(price) \(currency) for \(productID)")
            }
        }
        
        // Report revenue to Firebase Analytics
        Analytics.logEvent(AnalyticsEventPurchase, parameters: [
            AnalyticsParameterValue: price,
            AnalyticsParameterCurrency: currency,
            AnalyticsParameterItemID: productID
        ])
        print("✅ [Firebase] Revenue reported: \(price) \(currency) for \(productID)")
        
        // Report revenue to AppsFlyer
        AppsFlyerLib.shared().logEvent(AFEventPurchase, withValues: [
            AFEventParamRevenue: price,
            AFEventParamCurrency: currency,
            AFEventParamContentID: productID
        ])
        // AppsFlyer Revenue reported
    }
}

// MARK: - Event Constants

extension AppMetricaService {
    enum Events {
        static let appLaunch = "app_launch"
        static let generationStarted = "generation_started"
        static let generationCompleted = "generation_completed"
        static let generationFailed = "generation_failed"
        static let photoUploaded = "photo_uploaded"
        static let styleSelected = "style_selected"
        static let paywallShown = "paywall_shown"
        static let subscriptionStarted = "subscription_started"
        static let photoDeleted = "photo_deleted"
        static let settingsOpened = "settings_opened"
        static let galleryOpened = "gallery_opened"
        static let onboardingCompleted = "onboarding_completed"
    }
    
    enum Parameters {
        static let styleName = "style_name"
        static let styleCategory = "style_category"
        static let generationCount = "generation_count"
        static let errorMessage = "error_message"
        static let subscriptionType = "subscription_type"
        static let photoCount = "photo_count"
        static let isProUser = "is_pro_user"
    }
    
    // Firebase Analytics specific events
    enum FirebaseEvents {
        static let appOpen = AnalyticsEventAppOpen
        static let login = AnalyticsEventLogin
        static let signUp = AnalyticsEventSignUp
        static let purchase = AnalyticsEventPurchase
        static let beginCheckout = AnalyticsEventBeginCheckout
        static let addToCart = AnalyticsEventAddToCart
        static let viewItem = AnalyticsEventViewItem
        static let search = AnalyticsEventSearch
        static let share = AnalyticsEventShare
        static let tutorialBegin = AnalyticsEventTutorialBegin
        static let tutorialComplete = AnalyticsEventTutorialComplete
    }
    
    // Firebase Analytics specific parameters
    enum FirebaseParameters {
        static let itemID = AnalyticsParameterItemID
        static let itemName = AnalyticsParameterItemName
        static let itemCategory = AnalyticsParameterItemCategory
        static let value = AnalyticsParameterValue
        static let currency = AnalyticsParameterCurrency
        static let contentType = AnalyticsParameterContentType
        static let method = AnalyticsParameterMethod
        static let success = AnalyticsParameterSuccess
    }
} 