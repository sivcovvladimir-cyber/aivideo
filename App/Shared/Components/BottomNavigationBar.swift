import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BottomNavigationBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var themeManager = ThemeManager.shared

    private var currentTheme: ThemeType {
        themeManager.currentTheme
    }

    private var isEffectsActive: Bool {
        appState.currentScreen == .effectsHome
    }

    private var isGenerationActive: Bool {
        appState.currentScreen == .generation
    }

    private var isGalleryActive: Bool {
        appState.currentScreen == .gallery
    }

    /// Лёгкий тинт поверх материала: те же «тёмный/светлый» оттенки, что и фон приложения, но полупрозрачные — читается как liquid glass.
    private var liquidGlassTint: Color {
          switch currentTheme {
            case .dark:
                return AppTheme.Colors.background.opacity(0.3)
            case .light:
                return AppTheme.Colors.background.opacity(0.15)
            }
    }

    private var liquidGlassStroke: Color {
        switch currentTheme {
        case .dark:
            return Color.white.opacity(0.12)
        case .light:
            return Color.black.opacity(0.12)
        }
    }

    /// Высота капсулы навбара: контент 48 pt + вертикальные отступы 10+10.
    private let liquidCapsuleHeight: CGFloat = 68

    /// Базовый отступ капсулы от нижнего края области таббара (над home indicator / низом экрана).
    private let barBottomPadding: CGFloat = 16

    /// На iPhone с home indicator чуть поджимаем капсулу к индикатору; на 8 pt выше «максимального» прижима — комфортнее тап.
    private var resolvedBarBottomPadding: CGFloat {
        #if canImport(UIKit)
        if Self.keyWindowSafeAreaBottom() > 0 {
            return max(0, barBottomPadding - 6)
        }
        #endif
        return barBottomPadding
    }

    /// Нижний inset (home indicator). На iPhone без полоски обычно 0.
    private var safeAreaBottomInset: CGFloat {
        #if canImport(UIKit)
        return Self.keyWindowSafeAreaBottom()
        #else
        return 0
        #endif
    }

    /// Высота только капсулы + нижний отступ — якорь overlay не меняем (иначе таббар «подпрыгивает» вверх).
    private var tabBarLayoutHeight: CGFloat {
        liquidCapsuleHeight + resolvedBarBottomPadding
    }

    /// Высота градиента: та же зона + дорисовка вниз под home indicator (визуально, без роста layout).
    private var gradientBackgroundHeight: CGFloat {
        tabBarLayoutHeight + safeAreaBottomInset
    }

    #if canImport(UIKit)
    private static func keyWindowSafeAreaBottom() -> CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return 0 }
        return window.safeAreaInsets.bottom
    }
    #endif

    // Генератор подготавливается заранее (onAppear), чтобы impactOccurred() срабатывал мгновенно при тапе.
    #if canImport(UIKit)
    private static let tabImpactGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()
    #endif

    private static func playTabSwitchImpactFeedback() {
        #if canImport(UIKit)
        tabImpactGenerator.impactOccurred()
        tabImpactGenerator.prepare()
        #endif
    }

    var body: some View {
        let barShape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        ZStack(alignment: .bottom) {
            HStack(spacing: 18) {
                navigationTabView(
                    isActive: isEffectsActive,
                    systemName: isEffectsActive ? "flame.fill" : "flame",
                    title: "effects_tab".localized,
                    action: { appState.currentScreen = .effectsHome }
                )

                generationTabButton

                navigationTabView(
                    isActive: isGalleryActive,
                    systemName: isGalleryActive ? "photo.fill" : "photo",
                    title: "library_tab".localized,
                    action: { appState.currentScreen = .gallery }
                )
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .frame(height: 48)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            // Важно: tint должен лежать под контентом, иначе цвет иконок/подписей визуально искажается.
            .background(.thinMaterial, in: barShape)
            .background(barShape.fill(liquidGlassTint).allowsHitTesting(false))
            .overlay(barShape.stroke(liquidGlassStroke, lineWidth: 0.5).allowsHitTesting(false))
            .clipShape(barShape)
            .shadow(color: .black.opacity(currentTheme == .dark ? 0.35 : 0.08), radius: 16, x: 0, y: 6)
            .padding(.horizontal, 22)
            .padding(.bottom, resolvedBarBottomPadding)
        }
        .frame(height: tabBarLayoutHeight)
        .frame(maxWidth: .infinity, alignment: .bottom)
        // Градиент layout-neutral: не увеличивает высоту таббара (не поднимает якорь overlay). Сдвиг вниз — дорисовка под home indicator.
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: AppTheme.Colors.background.opacity(0), location: 0),
                    .init(color: AppTheme.Colors.background.opacity(0.6), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: gradientBackgroundHeight)
            .frame(maxWidth: .infinity)
            .offset(y: safeAreaBottomInset)
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
        }
        .themeAware()
        .themeAnimation()
    }

    private var generationTabButton: some View {
        Button {
            guard !isGenerationActive else { return }
            Self.playTabSwitchImpactFeedback()
            DispatchQueue.main.async {
                appState.currentScreen = .generation
            }
        } label: {
            // Чуть шире круга по горизонтали — капсула; плюс чуть меньше, чтобы не «давил» на края.
            ZStack {
                Capsule(style: .continuous)
                    .fill(AppTheme.Colors.primaryGradient)
                    .frame(width: 64, height: 52)
                    .shadow(color: AppTheme.Colors.primary.opacity(0.35), radius: 12, x: 0, y: 5)

                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AppTheme.Colors.onPrimaryText)
            }
            .opacity(isGenerationActive ? 0.82 : 1)
        }
        .appPlainButtonStyle()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("generation_tab".localized))
    }

    private func navigationTabView(
        isActive: Bool,
        systemName: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        // Dark: активный белый, неактивные белый 66%. Light: активный чёрный, неактивные — textSecondary.
        let tabForeground: Color = {
            switch currentTheme {
            case .dark:
                return isActive ? AppTheme.Colors.primary : AppTheme.Colors.textPrimary.opacity(0.66)
            case .light:
                return isActive ? AppTheme.Colors.primary : AppTheme.Colors.textPrimary.opacity(0.66)
            }
        }()
        return VStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: isActive ? .semibold : .medium))
                .foregroundColor(tabForeground)
                .frame(width: 26, height: 26)

            Text(title)
                .font(AppTheme.Typography.tabBar(isActive: isActive))
                .tracking(0.20)
                .foregroundColor(tabForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive else { return }
            // Сначала тактильный отклик синхронно; смену экрана — на следующий цикл run loop,
            // иначе тяжёлая перерисовка (галерея и т.п.) блокирует main и вибрация «доезжает» поздно.
            Self.playTabSwitchImpactFeedback()
            DispatchQueue.main.async {
                action()
            }
        }
    }
}
