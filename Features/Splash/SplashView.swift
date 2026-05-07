import SwiftUI

struct SplashView: View {
    @EnvironmentObject var appState: AppState

    /// Имя из Info.plist (`CFBundleDisplayName`), как в шаринге/водяном знаке — одно с подписью на иконке.
    private var appDisplayName: String {
        (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? "AI Video"
    }

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()

            // Лого по центру экрана фиксированного размера; название — у нижнего края (не под логотипом).
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(appDisplayName)
                    .font(AppTheme.Typography.font(weight: .semiBold, size: 26))
                    .minimumScaleFactor(0.85)
                    .lineLimit(2)
                    .foregroundStyle(AppTheme.Colors.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            print("🚀 [SplashView] === APP STARTUP ===")
            print("🚀 [SplashView] onAppear called - triggering loadInitialData")
            appState.loadInitialData()
        }
        .themeAware()
        .themeAnimation()
    }
} 