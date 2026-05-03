import SwiftUI

@main
struct AIVideoApp: App {
    // Register AppDelegate for life cycle events
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var appState = AppState.shared
    @StateObject private var dynamicModalManager = DynamicModalManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(dynamicModalManager)
                .onAppear {
                    // Устанавливаем dynamicModalManager в appState
                    appState.dynamicModalManager = dynamicModalManager

                    // Устанавливаем цвет фона для области статус бара через SwiftUI
                    AppTheme.syncWindowBackgroundWithTheme()

                    // Report app launch event асинхронно с задержкой
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Task {
                            await AppAnalyticsService.shared.reportAppLaunch()
                        }
                    }

                    // Запрашиваем разрешение на трекинг (IDFA) с небольшой задержкой
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        PermissionManager.shared.requestTrackingPermission { status in
                            print("🔍 [AI Video] IDFA permission status: \(status.rawValue)")
                        }
                    }
                }
        }
    }
}
