import Foundation
import YandexMobileMetrica
#if canImport(YandexMobileMetricaCrashes)
// Бинарный модуль крашей обязателен, если в `YMMYandexMetricaConfiguration` включён crashReporting (по умолчанию YES); иначе SDK шлёт «framework not found».
import YandexMobileMetricaCrashes
#endif
import FirebaseCore
import FirebaseAnalytics
import FirebaseCrashlytics
#if canImport(AppsFlyerLib)
import AppsFlyerLib
#endif
import Adapty

#if !canImport(AppsFlyerLib)
// Локальные no-op заглушки, чтобы проект собирался без SPM-пакета AppsFlyer.
protocol AppsFlyerLibDelegate: AnyObject {}

final class AppsFlyerLib {
    private static let sharedInstance = AppsFlyerLib()

    class func shared() -> AppsFlyerLib {
        sharedInstance
    }

    var appsFlyerDevKey: String?
    var appleAppID: String?
    var isDebug: Bool = false
    weak var delegate: AppsFlyerLibDelegate?
    var customerUserID: String?

    func waitForATTUserAuthorization(timeoutInterval: TimeInterval) {}
    func start() {}
    func logEvent(_ eventName: String, withValues values: [AnyHashable: Any]?) {}
    func handleOpen(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {}
    func `continue`(_ userActivity: NSUserActivity, restorationHandler: (([Any]?) -> Void)?) {}
}

let AFEventPurchase = "af_purchase"
let AFEventAddToCart = "af_add_to_cart"
let AFEventContentView = "af_content_view"
let AFEventInitiatedCheckout = "af_initiated_checkout"

let AFEventParamRevenue = "af_revenue"
let AFEventParamCurrency = "af_currency"
let AFEventParamContent = "af_content"
let AFEventParamContentType = "af_content_type"
#endif

// Для рабочего (Release) бандла не выводим диагностические print-логи аналитики в консоль.
#if !DEBUG
@inline(__always)
private func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif

class AppAnalyticsService {
    static let shared = AppAnalyticsService()
    
    private init() {}
    
    // MARK: - Initialization
    
    func initialize() {
        // Firebase требует конфигурации на главном потоке (читает GoogleService-Info.plist синхронно).
        // Вызывается из AppDelegate.didFinishLaunchingWithOptions, который уже на main thread.
        initializeFirebaseAnalytics()

        // AppsFlyer: ключи и delegate должны быть заданы ДО первого applicationDidBecomeActive → start().
        // Раньше инициализация шла в фоне и гонялась со start() — сессии уходили без dev key / appleAppID.
        initializeAppsFlyer()

        // Остальные SDK не имеют требований к потоку — инициализируем в фоне, чтобы не нагружать main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            self.initializeAppMetrica()

            DispatchQueue.main.async {
                print("✅ [AppAnalytics] All analytics services initialized")
            }
        }
    }
    
    private func initializeFirebaseAnalytics() {
        // Configure Firebase Analytics
        FirebaseApp.configure()
        print("✅ [AppAnalytics] Firebase Analytics initialized")
        
        // Configure Firebase Crashlytics
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        print("✅ [AppAnalytics] Firebase Crashlytics initialized")
    }
    
    private func initializeAppMetrica() {
        guard let apiKey = getAppMetricaAPIKey() else {
            print("❌ [AppAnalytics] AppMetrica API key not found")
            return
        }
        
        let configuration = YMMYandexMetricaConfiguration(apiKey: apiKey)
        #if DEBUG
        configuration?.logs = true
        #endif
        
        if let config = configuration {
            // Явно оставляем дефолт YES: без линковки `YandexMobileMetricaCrashes` в таргет отправка ошибок/крашей не работает.
            config.crashReporting = true
            YMMYandexMetrica.activate(with: config)
            print("✅ [AppAnalytics] AppMetrica initialized with API key: \(apiKey)")
        } else {
            print("❌ [AppAnalytics] Failed to create AppMetrica configuration")
        }
    }
    
    /// Приводит Apple App ID к виду «только цифры» (в письмах часто пишут id6760…; в SDK нужен числовой id).
    private func normalizedAppleAppStoreID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(
            of: "^id",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    private func initializeAppsFlyer() {
        guard ConfigurationManager.shared.isAppsFlyerConfigured else {
            print("ℹ️ [AppAnalytics] AppsFlyer пропущен: нет валидных APPSFLYER_DEV_KEY и/или APP_STORE_ID в APIKeys.plist")
            return
        }

        do {
            let devKey = try ConfigurationManager.shared.getRequiredValue(for: .appsFlyerDevKey)
            let rawAppStoreID = try ConfigurationManager.shared.getRequiredValue(for: .appStoreID)
            let appStoreID = normalizedAppleAppStoreID(rawAppStoreID)
            
            print("🔍 [AppAnalytics] AppsFlyer keys loaded:")
            print("  - Dev Key: \(devKey)")
            print("  - App Store ID: \(appStoreID)")
            
            AppsFlyerLib.shared().appsFlyerDevKey = devKey
            AppsFlyerLib.shared().appleAppID = appStoreID
            
            // Проверяем Bundle ID
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            print("🔍 [AppAnalytics] Bundle ID: \(bundleID)")
            print("🔍 [AppAnalytics] AppsFlyer App Store ID: \(appStoreID)")
            #if DEBUG
            if appStoreID.range(of: "^[0-9]+$", options: .regularExpression) == nil {
                print("⚠️ [AppAnalytics] APP_STORE_ID должен быть числом из App Store Connect (например 6760489755), не bundle id.")
            }
            #endif
            
            print("ℹ️ [AppAnalytics] AppsFlyer использует App Store ID для атрибуции")
            
            // Рекомендация AppsFlyer для iOS 14+: дождаться ATT перед сбором идентификаторов при вызове start().
            if #available(iOS 14, *) {
                AppsFlyerLib.shared().waitForATTUserAuthorization(timeoutInterval: 60)
            }
            
            #if DEBUG
            // Включаем логи и отладочный трафик для «Мастера интеграции» / проверки SDK в кабинете (релиз-сборки без этого флага).
            AppsFlyerLib.shared().isDebug = true
            print("🔍 [AppAnalytics] AppsFlyer isDebug = true (только DEBUG-сборка)")
            #endif
            
            print("✅ [AppAnalytics] AppsFlyer initialized successfully")
            
            // Устанавливаем delegate после полной инициализации
            if let delegate = AppDelegate.instance {
                AppsFlyerLib.shared().delegate = delegate
                print("✅ [AppAnalytics] AppsFlyer delegate set")
                
                // Проверяем статус после установки delegate
                let devKey = AppsFlyerLib.shared().appsFlyerDevKey
                let appStoreID = AppsFlyerLib.shared().appleAppID
                print("🔍 [AppAnalytics] AppsFlyer status after delegate set:")
                print("  - Dev Key: \(devKey)")
                print("  - App Store ID: \(appStoreID)")
                
                // AppsFlyer.start() вызывается из applicationDidBecomeActive; здесь не дублируем.
                // Стандартное событие af_app_opened отправляется автоматически при start().
            } else {
                print("❌ [AppAnalytics] AppDelegate instance not available")
            }
            
            // Проверяем статус инициализации
            print("🔍 [AppAnalytics] AppsFlyer initialization completed")
            
        } catch {
            print("❌ [AppAnalytics] Failed to get AppsFlyer keys: \(error)")
        }
    }
    
    // MARK: - Crashlytics Methods
    
    /// Log custom error to Crashlytics
    func logError(_ error: Error, userInfo: [String: Any]? = nil) {
        Crashlytics.crashlytics().record(error: error, userInfo: userInfo)
        print("✅ [AppAnalytics] Error logged to Crashlytics: \(error.localizedDescription)")
    }
    
    /// Log custom message to Crashlytics
    func logMessage(_ message: String) {
        Crashlytics.crashlytics().log(message)
        print("✅ [AppAnalytics] Message logged to Crashlytics: \(message)")
    }
    
    /// Set user ID in Crashlytics
    func setCrashlyticsUserID(_ userID: String) {
        Crashlytics.crashlytics().setUserID(userID)
        print("✅ [AppAnalytics] Crashlytics User ID set: \(userID)")
    }
    
    /// Set custom key in Crashlytics
    func setCrashlyticsCustomKey(_ key: String, value: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
        print("✅ [AppAnalytics] Crashlytics custom key set: \(key) = \(value)")
    }
    
    // MARK: - API Keys
    
    private func getAppMetricaAPIKey() -> String? {
        guard let path = Bundle.main.path(forResource: "APIKeys", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let apiKey = plist["YANDEX_APPMETRICA_API_KEY"] as? String,
              apiKey != "YOUR_YANDEX_APPMETRICA_API_KEY" else {
            return nil
        }
        return apiKey
    }
    
    // MARK: - Event Reporting (Async)
    
    /// Отправить событие во все аналитические сервисы асинхронно.
    /// Без MainActor: Firebase/AppMetrica/AppsFlyer допускают вызов с фона — UI не блокируется.
    func reportEvent(_ event: String, parameters: [String: Any]? = nil) async {
        print("📊 [AppAnalytics] 📊 EVENT: \(event) 📊")
        if let params = parameters, !params.isEmpty {
            print("📊 [AppAnalytics] Parameters: \(params)")
        }
        
        await withTaskGroup(of: Void.self) { group in
            // AppMetrica
            group.addTask {
                await self.reportToAppMetrica(event: event, parameters: parameters)
            }
            
            // Firebase Analytics
            group.addTask {
                await self.reportToFirebase(event: event, parameters: parameters)
            }
            
            // Adapty
            group.addTask {
                await self.reportToAdapty(event: event, parameters: parameters)
            }
            
            // AppsFlyer
            group.addTask {
                await self.reportToAppsFlyer(event: event, parameters: parameters)
            }
        }
    }
    
    // MARK: - User Management (Async)
    
    /// Установить User ID во всех сервисах
    @MainActor
    func setUserID(_ userID: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                YMMYandexMetrica.setUserProfileID(userID)
                print("✅ [AppAnalytics] AppMetrica User ID set: \(userID)")
            }
            
            group.addTask {
                Analytics.setUserID(userID)
                print("✅ [AppAnalytics] Firebase User ID set: \(userID)")
            }
            
            group.addTask {
                guard ConfigurationManager.shared.isAppsFlyerConfigured else { return }
                AppsFlyerLib.shared().customerUserID = userID
                // AppsFlyer User ID set
            }
            
            group.addTask {
                Crashlytics.crashlytics().setUserID(userID)
                print("✅ [AppAnalytics] Crashlytics User ID set: \(userID)")
            }
        }
    }
    
    /// Установить свойство пользователя во всех сервисах
    @MainActor
    func setUserProperty(_ property: String, value: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // AppMetrica doesn't have setUserProfileValue, we'll skip this for now
                print("⚠️ [AppAnalytics] AppMetrica User property setting skipped: \(property) = \(value)")
            }
            
            group.addTask {
                Analytics.setUserProperty(value, forName: property)
                print("✅ [AppAnalytics] Firebase User property set: \(property) = \(value)")
            }
            
            group.addTask {
                // AppsFlyer doesn't have setAdditionalData, we'll skip this for now
                print("⚠️ [AppAnalytics] AppsFlyer User property setting skipped: \(property) = \(value)")
            }
        }
    }
    
    // MARK: - Revenue Tracking (Async)
    
    /// Отправить информацию о покупке во все сервисы
    @MainActor
    func reportRevenue(price: Double, currency: String, productID: String) async {
        await withTaskGroup(of: Void.self) { group in
            // AppMetrica Revenue
            group.addTask {
                let revenue = YMMRevenueInfo(priceDecimal: NSDecimalNumber(value: price), currency: currency)
                // Note: productID is read-only in YMMRevenueInfo, we'll include it in parameters instead
                
                YMMYandexMetrica.reportRevenue(revenue) { _ in
                    print("✅ [AppAnalytics] AppMetrica Revenue reported: \(price) \(currency) for \(productID)")
                }
            }
            
            // Firebase Analytics Revenue
            group.addTask {
                Analytics.logEvent(AnalyticsEventPurchase, parameters: [
                    AnalyticsParameterValue: price,
                    AnalyticsParameterCurrency: currency,
                    AnalyticsParameterItemID: productID
                ])
                print("✅ [AppAnalytics] Firebase Revenue reported: \(price) \(currency) for \(productID)")
            }
            
            // AppsFlyer Revenue
            group.addTask {
                guard ConfigurationManager.shared.isAppsFlyerConfigured else { return }
                AppsFlyerLib.shared().logEvent(AFEventPurchase, withValues: [
                    AFEventParamRevenue: price,
                    AFEventParamCurrency: currency,
                    AFEventParamContent: productID
                ])
                // AppsFlyer Revenue reported
            }
        }
    }
    
    // MARK: - Private Reporting Methods

    /// AppMetrica принимает только JSON-совместимые типы в parameters; неподдерживаемые значения отбрасываем/нормализуем.
    private func appMetricaJSONParameters(_ parameters: [String: Any]?) -> [AnyHashable: Any]? {
        guard let parameters else { return nil }

        func sanitize(_ value: Any) -> Any? {
            switch value {
            case let v as String: return v
            case let v as Int: return v
            case let v as Int8: return Int(v)
            case let v as Int16: return Int(v)
            case let v as Int32: return Int(v)
            case let v as Int64: return Int(v)
            case let v as UInt: return Int(v)
            case let v as UInt8: return Int(v)
            case let v as UInt16: return Int(v)
            case let v as UInt32: return Int(v)
            case let v as UInt64: return Int(v)
            case let v as Double: return v
            case let v as Float: return Double(v)
            case let v as Bool: return v
            case let v as NSNumber: return v
            case let v as Date: return ISO8601DateFormatter().string(from: v)
            case let v as URL: return v.absoluteString
            case let array as [Any]:
                return array.compactMap { sanitize($0) }
            case let dict as [String: Any]:
                var out: [String: Any] = [:]
                for (k, val) in dict {
                    if let s = sanitize(val) {
                        out[k] = s
                    }
                }
                return out
            default:
                return String(describing: value)
            }
        }

        var result: [AnyHashable: Any] = [:]
        for (key, value) in parameters {
            if let sanitized = sanitize(value) {
                result[key] = sanitized
            }
        }
        return result.isEmpty ? nil : result
    }
    
    private func reportToAppMetrica(event: String, parameters: [String: Any]?) async {
        YMMYandexMetrica.reportEvent(event, parameters: appMetricaJSONParameters(parameters)) { _ in
            print("✅ [AppAnalytics] AppMetrica event reported: \(event)")
        }
    }
    
    private func reportToFirebase(event: String, parameters: [String: Any]?) async {
        Analytics.logEvent(event, parameters: parameters)
        print("✅ [AppAnalytics] Firebase event reported: \(event)")
    }
    
    private func reportToAdapty(event: String, parameters: [String: Any]?) async {
        // Adapty doesn't have a direct logEvent method, we'll skip this for now
        print("⚠️ [AppAnalytics] Adapty event logging skipped: \(event)")
        
        // Also log to paywall if it's a paywall-related event
        if event.contains("paywall") || event.contains("subscription") {
            do {
                let tier = PaywallCacheManager.shared.currentPlacementTier
                let placementId = try PaywallCacheManager.shared.configuredAdaptyPlacementId()
                Adapty.getPaywall(placementId: placementId) { result in
                    switch result {
                    case .success(let paywall):
                        Adapty.logShowPaywall(paywall)
                        print("✅ [AppAnalytics] Adapty paywall event logged: \(event) (\(tier.rawValue))")
                    case .failure(let error):
                        print("❌ [AppAnalytics] Failed to get paywall for event: \(error)")
                    }
                }
            } catch {
                print("❌ [AppAnalytics] Failed to get placement ID: \(error)")
            }
        }
    }
    
    private func reportToAppsFlyer(event: String, parameters: [String: Any]?) async {
        guard ConfigurationManager.shared.isAppsFlyerConfigured else { return }
        AppsFlyerLib.shared().logEvent(event, withValues: parameters)
        // AppsFlyer event reported
    }

    /// Прямые вызовы `logEvent` вне `reportEvent`: те же условия, что и для `start()`.
    private func appsFlyerLogEvent(_ name: String, withValues values: [AnyHashable: Any]?) {
        guard ConfigurationManager.shared.isAppsFlyerConfigured else { return }
        AppsFlyerLib.shared().logEvent(name, withValues: values)
    }
}

// MARK: - Event Constants

extension AppAnalyticsService {
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

// MARK: - Convenience Methods for Common Events

extension AppAnalyticsService {
    
    /// Отправить событие запуска приложения
    @MainActor
    func reportAppLaunch() async {
        print("🚀 [AppAnalytics] 🚀 APP LAUNCH 🚀")
        await reportEvent(Events.appLaunch)
        
        // Также отправляем стандартные события
        Analytics.logEvent(AnalyticsEventAppOpen, parameters: nil)
        appsFlyerLogEvent("app_open", withValues: nil)
    }
    
    /// Отправить событие начала генерации
    @MainActor
    /// Имена параметров Firebase/legacy остаются `style_name` / `style_category`, чтобы не ломать уже настроенные воронки.
    func reportGenerationStarted(effectPresetName: String, effectSectionName: String, isProUser: Bool) async {
        print("🎨 [AppAnalytics] 🎨 GENERATION STARTED 🎨")
        print("🎨 [AppAnalytics] Effect: \(effectPresetName), Section: \(effectSectionName), Pro: \(isProUser)")
        await reportEvent(Events.generationStarted, parameters: [
            Parameters.styleName: effectPresetName,
            Parameters.styleCategory: effectSectionName,
            Parameters.isProUser: isProUser
        ])
    }
    
    /// Отправить событие успешной генерации
    @MainActor
    func reportGenerationCompleted(effectPresetName: String, effectSectionName: String, isProUser: Bool, generationCount: Int) async {
        print("✅ [AppAnalytics] ✅ GENERATION COMPLETED ✅")
        print("✅ [AppAnalytics] Effect: \(effectPresetName), Section: \(effectSectionName), Pro: \(isProUser), Count: \(generationCount)")
        await reportEvent(Events.generationCompleted, parameters: [
            Parameters.styleName: effectPresetName,
            Parameters.styleCategory: effectSectionName,
            Parameters.isProUser: isProUser,
            Parameters.generationCount: generationCount
        ])
        
        // Также отправляем стандартные события покупки
        Analytics.logEvent(AnalyticsEventPurchase, parameters: [
            AnalyticsParameterValue: 1.0,
            AnalyticsParameterCurrency: "USD",
            "generation_count": generationCount
        ])
        
        appsFlyerLogEvent(AFEventPurchase, withValues: [
            AFEventParamRevenue: 1.0,
            AFEventParamCurrency: "USD",
            "generation_count": generationCount
        ])
    }
    
    /// Отправить событие ошибки генерации
    @MainActor
    func reportGenerationFailed(effectPresetName: String, effectSectionName: String, isProUser: Bool, errorMessage: String) async {
        print("❌ [AppAnalytics] ❌ GENERATION FAILED ❌")
        print("❌ [AppAnalytics] Effect: \(effectPresetName), Section: \(effectSectionName), Pro: \(isProUser)")
        print("❌ [AppAnalytics] Error: \(errorMessage)")
        await reportEvent(Events.generationFailed, parameters: [
            Parameters.styleName: effectPresetName,
            Parameters.styleCategory: effectSectionName,
            Parameters.isProUser: isProUser,
            Parameters.errorMessage: errorMessage
        ])
    }
    
    /// Отправить событие загрузки фото
    @MainActor
    func reportPhotoUploaded(photoId: String) async {
        print("📸 [AppAnalytics] 📸 PHOTO UPLOADED 📸")
        print("📸 [AppAnalytics] Photo ID: \(photoId)")
        await reportEvent(Events.photoUploaded, parameters: [
            "photo_id": photoId
        ])
        
        // Также отправляем стандартные события
        Analytics.logEvent(AnalyticsEventAddToCart, parameters: [
            AnalyticsParameterItemID: photoId,
            AnalyticsParameterItemName: "User Photo",
            AnalyticsParameterItemCategory: "Photo Upload"
        ])
        
        appsFlyerLogEvent(AFEventAddToCart, withValues: [
            AFEventParamContent: photoId,
            AFEventParamContentType: "Photo Upload"
        ])
    }
    
    /// Выбор пресета эффекта в UI; ключи событий в консолях остаются прежними (`style_selected`, …).
    @MainActor
    func reportEffectPresetSelected(effectPresetName: String, effectSectionName: String, isProUser: Bool) async {
        print("🎯 [AppAnalytics] 🎯 EFFECT PRESET SELECTED 🎯")
        print("🎯 [AppAnalytics] Effect: \(effectPresetName), Section: \(effectSectionName), Pro: \(isProUser)")
        await reportEvent(Events.styleSelected, parameters: [
            Parameters.styleName: effectPresetName,
            Parameters.styleCategory: effectSectionName,
            Parameters.isProUser: isProUser
        ])
        
        Analytics.logEvent(AnalyticsEventViewItem, parameters: [
            AnalyticsParameterItemName: effectPresetName,
            AnalyticsParameterItemCategory: effectSectionName
        ])
        
        appsFlyerLogEvent(AFEventContentView, withValues: [
            AFEventParamContent: effectPresetName,
            AFEventParamContentType: effectSectionName
        ])
    }
    
    /// Отправить событие показа пейвола
    @MainActor
    func reportPaywallShown() async {
        print("💰 [AppAnalytics] 💰 PAYWALL SHOWN 💰")
        await reportEvent(Events.paywallShown)
        
        // Также отправляем стандартные события
        Analytics.logEvent("paywall_shown", parameters: nil)  // Кастомное событие вместо покупки
        appsFlyerLogEvent(AFEventInitiatedCheckout, withValues: nil)
    }
    
    /// Отправить событие покупки подписки
    @MainActor
    func reportSubscriptionStarted(productId: String, productName: String, price: Double, currency: String) async {
        print("💎 [AppAnalytics] 💎 SUBSCRIPTION STARTED 💎")
        print("💎 [AppAnalytics] Product: \(productName) (\(productId)), Price: \(price) \(currency)")
        await reportEvent(Events.subscriptionStarted, parameters: [
            Parameters.subscriptionType: productId
        ])
        
        // Также отправляем стандартные события покупки
        Analytics.logEvent(AnalyticsEventPurchase, parameters: [
            AnalyticsParameterItemID: productId,
            AnalyticsParameterItemName: productName,
            AnalyticsParameterValue: price,
            AnalyticsParameterCurrency: currency
        ])
        
        appsFlyerLogEvent(AFEventPurchase, withValues: [
            AFEventParamContent: productId,
            AFEventParamContentType: productName,
            AFEventParamRevenue: price,
            AFEventParamCurrency: currency
        ])
    }
    
    /// Отправить событие удаления фото
    @MainActor
    func reportPhotoDeleted(photoId: String) async {
        print("🗑️ [AppAnalytics] 🗑️ PHOTO DELETED 🗑️")
        print("🗑️ [AppAnalytics] Photo ID: \(photoId)")
        await reportEvent(Events.photoDeleted, parameters: [
            "photo_id": photoId,
            "photo_type": "generated_image"
        ])
        
        // Также отправляем кастомные события
        Analytics.logEvent("photo_deleted", parameters: [
            "photo_id": photoId,
            "photo_type": "generated_image"
        ])
        
        appsFlyerLogEvent("photo_deleted", withValues: [
            "photo_id": photoId,
            "photo_type": "generated_image"
        ])
    }
    
    /// Отправить событие открытия настроек
    @MainActor
    func reportSettingsOpened() async {
        print("⚙️ [AppAnalytics] ⚙️ SETTINGS OPENED ⚙️")
        await reportEvent(Events.settingsOpened)
        
        // Также отправляем кастомные события
        Analytics.logEvent("settings_opened", parameters: nil)
        appsFlyerLogEvent("settings_opened", withValues: nil)
    }
    
    /// Отправить событие открытия галереи. Выполняется с utility-приоритетом вне main: тяжёлые SDK не блокируют кадр.
    func reportGalleryOpened(photoCount: Int) async {
        await Task.detached(priority: .utility) {
            await AppAnalyticsService.shared.emitGalleryOpenedEvents(photoCount: photoCount)
        }.value
    }

    /// Внутренняя отправка: reportEvent уже шлёт в AppMetrica/Firebase/Adapty/AppsFlyer; дубли убраны.
    private func emitGalleryOpenedEvents(photoCount: Int) async {
        print("🖼️ [AppAnalytics] 🖼️ GALLERY OPENED 🖼️")
        print("🖼️ [AppAnalytics] Photo Count: \(photoCount)")
        await reportEvent(Events.galleryOpened, parameters: [
            Parameters.photoCount: photoCount
        ])
    }
    
    /// Отправить событие завершения онбординга
    @MainActor
    func reportOnboardingCompleted() async {
        print("🎉 [AppAnalytics] 🎉 ONBOARDING COMPLETED 🎉")
        await reportEvent(Events.onboardingCompleted)
        
        // Также отправляем стандартные события
        Analytics.logEvent(AnalyticsEventTutorialComplete, parameters: nil)
        appsFlyerLogEvent("tutorial_complete", withValues: nil)
    }
} 