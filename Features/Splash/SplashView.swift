import SwiftUI

struct SplashView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()

            Image(colorScheme == .dark ? "Logo Dark" : "Logo Light")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(.horizontal, 12)
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