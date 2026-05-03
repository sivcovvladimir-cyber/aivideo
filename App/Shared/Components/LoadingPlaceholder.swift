import SwiftUI

/// Красивый анимированный плейсхолдер для загрузки изображений
struct LoadingPlaceholder: View {
    var body: some View {
        ZStack {
            // Градиентный фон
            LinearGradient(
                colors: [
                    AppTheme.Colors.cardBackground,
                    AppTheme.Colors.cardBackground.opacity(0.8),
                    AppTheme.Colors.cardBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Стандартный ProgressView
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                .scaleEffect(1.5)
        }
    }
}

/// Плейсхолдер с анимированным лоадером для разных типов контента
struct IconLoadingPlaceholder: View {
    let iconName: String
    let iconColor: Color
    let useSpinner: Bool
    
    @State private var isAnimating = false
    
    /// nil — дефолтный цвет иконки (`AppTheme.contentCircularLoaderTint`); спиннер при `useSpinner` всегда берёт тот же тинт из темы.
    /// `iconName` — имя SF Symbol (без legacy-алиасов IconView).
    init(iconName: String = "photo", iconColor: Color? = nil, useSpinner: Bool = true) {
        self.iconName = iconName
        self.iconColor = iconColor ?? AppTheme.contentCircularLoaderTint
        self.useSpinner = useSpinner
    }
    
    var body: some View {
        ZStack {
            // Градиентный фон
            LinearGradient(
                colors: [
                    AppTheme.Colors.cardBackground,
                    AppTheme.Colors.cardBackground.opacity(0.8),
                    AppTheme.Colors.cardBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            if useSpinner {
                // Спиннер всегда `contentCircularLoaderTint`; `iconColor` — только для режима с иконкой.
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.contentCircularLoaderTint))
                    .scaleEffect(1.2)
            } else {
                // Fallback без IconView: только SF Symbol по имени.
                Image(systemName: iconName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(iconColor)
                    .opacity(isAnimating ? 0.6 : 1.0)
                    .scaleEffect(isAnimating ? 0.9 : 1.0)
                    .animation(
                        Animation.easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview
struct LoadingPlaceholder_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            LoadingPlaceholder()
                .frame(width: 120, height: 120)
                .cornerRadius(12)
            
            IconLoadingPlaceholder()
                .frame(width: 120, height: 120)
                .cornerRadius(12)
            
            IconLoadingPlaceholder(iconColor: .green)
                .frame(width: 120, height: 120)
                .cornerRadius(12)
        }
        .padding()
        .background(AppTheme.Colors.background)
    }
} 