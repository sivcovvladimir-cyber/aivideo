import SwiftUI
import FirebaseCore
import FirebaseAnalytics
import AppsFlyerLib
import Adapty
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, AppsFlyerLibDelegate {
    
    // Статический доступ для установки delegate из AppAnalyticsService
    static var instance: AppDelegate?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        // Устанавливаем статический доступ
        AppDelegate.instance = self
        
        // UIKit-окно прозрачное — весь фон рисует SwiftUI.
        configureStatusBarAppearance()

        // --- Adapty ---
        do {
            let adaptyKey = try ConfigurationManager.shared.getRequiredValue(for: .adaptyPublicKey)
            Adapty.activate(adaptyKey)
            
            // Проверяем статус подписки при запуске
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in
                    AppState.shared.updateProStatusFromAdapty()
                }
            }
        } catch {
            print("🚨 ERROR: Failed to get Adapty Public Key: \(error)")
        }

        // Initialize AppAnalytics (включая AppsFlyer)
        AppAnalyticsService.shared.initialize()
        
        // SwiftUI lifecycle (@main App) не вызывает applicationDidBecomeActive на AppDelegate —
        // используем Notification, как рекомендует AppsFlyer для SceneDelegate / SwiftUI.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActiveNotification),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        return true
    }
    
    /// Вызывается через NotificationCenter при каждом выходе приложения на передний план (и при первом старте).
    @objc private func didBecomeActiveNotification() {
        print("🔍 [AppDelegate] didBecomeActiveNotification → starting AppsFlyer...")
        AppsFlyerLib.shared().start()
        print("✅ [AppDelegate] AppsFlyer started")
        
        configureStatusBarAppearance()
        Task { @MainActor in
            AppState.shared.handleAppDidBecomeActive()
        }
    }
    
    // MARK: - Status Bar Configuration
    private func configureStatusBarAppearance() {
        AppTheme.syncWindowBackgroundWithTheme()
    }
    
    // MARK: - AppsFlyer Delegate
    
    func onConversionDataSuccess(_ conversionInfo: [AnyHashable : Any]) {
        print("✅ [AppDelegate] AppsFlyer conversion data received: \(conversionInfo)")
    }
    
    func onConversionDataFail(_ error: Error) {
        print("❌ [AppDelegate] AppsFlyer conversion data failed: \(error)")
    }
    
    func onAppOpenAttribution(_ attributionData: [AnyHashable : Any]) {
        print("✅ [AppDelegate] AppsFlyer app open attribution: \(attributionData)")
    }
    
    func onAppOpenAttributionFailure(_ error: Error) {
        print("❌ [AppDelegate] AppsFlyer app open attribution failed: \(error)")
    }
    

    
    // MARK: - URL Handling (Deep Links)
    
    /// Deep links: AppsFlyer (OneLink / URI) и кастомная схема `aivideo`.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        // OneLink / URI-схемы: без вызова handleOpen атрибуция AppsFlyer по ссылкам не заработает (базовые install-события — отдельно).
        AppsFlyerLib.shared().handleOpen(url, options: options)

        print("🔗 [AppDelegate] Deep link received: \(url)")
        
        // Обрабатываем кастомные deep links
        if url.scheme == "aivideo" {
            print("✅ [AppDelegate] Custom deep link handled: \(url)")
            handleCustomDeepLink(url)
            return true
        }
        
        return false
    }
    
    /// Обрабатываем универсальные ссылки (Universal Links)
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Universal Links для OneLink: передаём в AppsFlyer до собственной логики (см. sample AppsFlyer).
        // `continue` — ключевое слово Swift; closure из UIApplicationDelegate имеет тип [UIUserActivityRestoring]?, а SDK ожидает другую сигнатуру — из‑за этого «ambiguous»; в sample AppsFlyer передают nil.
        AppsFlyerLib.shared().`continue`(userActivity, restorationHandler: nil)

        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            print("🔗 [AppDelegate] Universal link received: \(url)")
            
            handleUniversalLink(url)
            return true
        }
        
        return false
    }
    
    /// Обрабатываем кастомные deep links
    private func handleCustomDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        
        switch components.host {
        case "paywall":
            print("🔗 [AppDelegate] Deep link to paywall")
            // Переходим на пейвол
            DispatchQueue.main.async {
                Task { @MainActor in
                    AppState.shared.presentPaywallFullscreen()
                }
            }
            
        case "gallery":
            print("🔗 [AppDelegate] Deep link to gallery")
            // Переходим в галерею
            DispatchQueue.main.async {
                Task { @MainActor in
                    AppState.shared.currentScreen = .gallery
                }
            }

        case "effects":
            print("🔗 [AppDelegate] Deep link to effects")
            DispatchQueue.main.async {
                Task { @MainActor in
                    AppState.shared.currentScreen = .effectsHome
                }
            }
            
        case "create":
            print("🔗 [AppDelegate] Legacy deep link to create routed to generation")
            DispatchQueue.main.async {
                Task { @MainActor in
                    AppState.shared.currentScreen = .generation
                }
            }

        case "generation":
            print("🔗 [AppDelegate] Deep link to generation")
            DispatchQueue.main.async {
                Task { @MainActor in
                    AppState.shared.currentScreen = .generation
                }
            }
            
        default:
            print("⚠️ [AppDelegate] Unknown deep link host: \(components.host ?? "nil")")
        }
    }
    
    /// Обрабатываем universal links
    private func handleUniversalLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        
        // Обрабатываем ссылки на ваш сайт
        if components.host == "aivideo.app" || components.host == "www.aivideo.app" {
            print("🔗 [AppDelegate] Website universal link: \(url)")
            // Можно добавить логику для обработки ссылок с сайта
        }
    }
    
    // MARK: - Memory Warning Handling
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        print("⚠️ [AppDelegate] Memory warning received")
        // Clear caches to free up memory
        Task { @MainActor in
            AppState.shared.handleMemoryWarning()
        }
    }
    

    

    

} 