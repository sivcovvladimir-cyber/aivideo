import SwiftUI
import UIKit

// MARK: - Theme Types

enum ThemeType: String, CaseIterable {
    case dark = "dark"
    case light = "light"
    
    var displayName: String {
        switch self {
        case .dark: return "dark_theme".localized
        case .light: return "light_theme".localized
        }
    }
}

// MARK: - Theme Manager

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var currentTheme: ThemeType {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "selected_theme")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .themeChanged, object: nil)
            }
        }
    }

    private init() {
        let savedTheme = UserDefaults.standard.string(forKey: "selected_theme") ?? "dark"
        self.currentTheme = ThemeType(rawValue: savedTheme) ?? .dark
        Self.removeLegacyAccentUserDefaults()
    }

    /// Раньше акцент хранился в UserDefaults — очищаем, чтобы не тащить наследие в новый продукт.
    private static func removeLegacyAccentUserDefaults() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "selected_primary_color_hex")
        ud.removeObject(forKey: "aivideo_primary_accent_preset")
        ud.removeObject(forKey: "aivideo_primary_accent_custom_r")
        ud.removeObject(forKey: "aivideo_primary_accent_custom_g")
        ud.removeObject(forKey: "aivideo_primary_accent_custom_b")
    }

    func toggleTheme() {
        withAnimation(.easeInOut(duration: 0.3)) {
            switch currentTheme {
            case .dark: currentTheme = .light
            case .light: currentTheme = .dark
            }
        }
    }

    /// Тот же однотонный акцент, что и `AppTheme.Colors.primary` (сэмпл `primaryGradient`, не первый стоп).
    var primaryColor: Color {
        AppTheme.Colors.primary
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let themeChanged = Notification.Name("themeChanged")
}

// MARK: - App Theme Manager

/// Глобальная система управления темой приложения
struct AppTheme {
    
    // MARK: - Current Theme
    
    static var current: ThemeType {
        get { ThemeManager.shared.currentTheme }
        set { ThemeManager.shared.currentTheme = newValue }
    }

    // MARK: - Activity indicators

    /// Единый тинт круговых `ProgressView` по приложению: сейчас совпадает с `Colors.primary` — задавайте через это свойство, не дублируя `primary` в вызовах.
    static var contentCircularLoaderTint: Color {
        Colors.primary
    }
    
    // MARK: - Font Weight (маппинг на SF Pro через Font.Weight / UIFont.Weight)

    enum FontWeight: String {
        case regular = "Regular"
        case medium = "Medium"
        case semiBold = "SemiBold"
        case bold = "Bold"

        var swiftUI: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semiBold: return .semibold
            case .bold: return .bold
            }
        }

        var uiKit: UIFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semiBold: return .semibold
            case .bold: return .bold
            }
        }
    }
    
    // MARK: - Colors
    
    struct Colors {
        /// Позиция вдоль `primaryGradient` (0…1) для однотонного акцента: тумблеры, активные пункты, спиннеры — чуть правее середины, без «чистого» фиолета первого стопа.
        static let brandGradientAccentLocation: CGFloat = 0.5

        /// Стопы Figma (location, R, G, B в 0…1) — и `primaryGradient`, и однотонный `primary` считаются с одной шкалы.
        private static let primaryGradientRGBStops: [(CGFloat, Double, Double, Double)] = [
            (0, 110 / 255, 81 / 255, 232 / 255),
            (0.44, 211 / 255, 72 / 255, 209 / 255),
            (0.76, 251 / 255, 93 / 255, 156 / 255),
            (1, 249 / 255, 145 / 255, 127 / 255)
        ]

        /// Основной однотонный акцент: та же шкала, что и `primaryGradient`, в точке `brandGradientAccentLocation`.
        static var primary: Color {
            brandGradientSolidSample(at: brandGradientAccentLocation)
        }

        /// Интерполяция RGB между стопами `primaryGradientRGBStops`.
        private static func brandGradientSolidSample(at unit: CGFloat) -> Color {
            let t = min(max(unit, 0), 1)
            let stops = primaryGradientRGBStops
            guard let first = stops.first else {
                return Color(red: 110 / 255, green: 81 / 255, blue: 232 / 255)
            }
            if t <= first.0 {
                return Color(red: first.1, green: first.2, blue: first.3)
            }
            for i in 1 ..< stops.count {
                let s0 = stops[i - 1]
                let s1 = stops[i]
                if t <= s1.0 {
                    let span = s1.0 - s0.0
                    let u = span > 1e-6 ? CGFloat((t - s0.0) / span) : 0
                    let r = s0.1 + (s1.1 - s0.1) * Double(u)
                    let g = s0.2 + (s1.2 - s0.2) * Double(u)
                    let b = s0.3 + (s1.3 - s0.3) * Double(u)
                    return Color(red: r, green: g, blue: b)
                }
            }
            let last = stops.last!
            return Color(red: last.1, green: last.2, blue: last.3)
        }
        
        /// Сканон RGB основного фона: SwiftUI и UIWindow берут отсюда — менять цвет в одном месте.
        private static var mainBackgroundRGB: (CGFloat, CGFloat, CGFloat) {
            switch current {
            case .dark: return (0.09, 0.10, 0.13)
            case .light: return (1, 1, 1)
            }
        }

        /// Фон приложения
        static var background: Color {
            let (r, g, b) = mainBackgroundRGB
            return Color(red: r, green: g, blue: b)
        }

        /// Тот же фон для UIKit (окно под статус-баром, rootView) — без дублирования hex/RGB.
        static var backgroundUIColor: UIColor {
            let (r, g, b) = mainBackgroundRGB
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        
        /// Фон карточек и элементов
        static var cardBackground: Color {
            switch current {
            case .dark: return Color(red: 0.13, green: 0.14, blue: 0.16) // Более темный для темной темы
            case .light: return Color(red: 0.95, green: 0.95, blue: 0.97)
            }
        }

        /// Подложка под иконки стилей: всегда светлая и мягкая, чтобы превью выглядели ровно в обеих темах.
        static var stylePreviewSubstrate: Color {
            Color(red: 0.925, green: 0.932, blue: 0.948)
        }
        
        /// Основной текст
        static var textPrimary: Color {
            switch current {
            case .dark: return Color.white.opacity(0.85)
            case .light: return Color.black.opacity(0.85)
            }
        }

        /// Цвет текста поверх primary-элементов (кнопки/бейджи): чуть приглушённый, чтобы не давать слишком жёсткий контраст.
        static var onPrimaryText: Color {
            Color.white.opacity(0.93)
        }
        
        /// Вторичный текст и подсказки: в dark не средне-серый (слишком «грязный» на фоне), а приглушённый белый — ниже контраста чем textPrimary.
        static var textSecondary: Color {
            switch current {
            case .dark: return Color.white.opacity(0.72)
            case .light: return Color(red: 0.4, green: 0.4, blue: 0.4)
            }
        }
        
        /// Акцентный цвет (зеленый для скидок, успеха)
        static let accent = Color.green
        
        /// Цвет ошибок
        static let error = Color.red
        
        /// Цвет предупреждений
        static let warning = Color.orange
        
        /// Цвет успеха
        static let success = Color.green
        
        /// Прозрачный цвет для наложения
        static var overlay: Color {
            switch current {
            case .dark: return Color.black.opacity(0.5)
            case .light: return Color.black.opacity(0.3)
            }
        }
        
        /// Цвет границ
        static var border: Color {
            switch current {
            case .dark: return Color(red: 0.3, green: 0.3, blue: 0.35)
            case .light: return Color(red: 0.8, green: 0.8, blue: 0.8)
            }
        }
        
        /// Цвет для неактивных элементов
        static let disabled = Color.gray
        
        /// Темный фон для пейвола (одинаковый для всех тем)
        static let paywallCardBackground = Color(red: 0.13, green: 0.14, blue: 0.16)
        
        /// Продуктовый primary-градиент (Figma): один источник для кнопок, чипов, таб «Создать» и т.д. — везде `AppTheme.Colors.primaryGradient`.
        static var primaryGradient: LinearGradient {
            LinearGradient(
                stops: primaryGradientRGBStops.map { loc, r, g, b in
                    Gradient.Stop(color: Color(red: r, green: g, blue: b), location: loc)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: - UIKit window / status bar sync

    /// UIKit-окно должно быть прозрачным, чтобы не перекрывать SwiftUI-контент при смене темы.
    /// Каждый SwiftUI-экран сам рисует свой `.background(AppTheme.Colors.background)`.
    static func syncWindowBackgroundWithTheme() {
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.backgroundColor = .clear
                    window.rootViewController?.view.backgroundColor = .clear
                }
            }
        }
    }
    
    // MARK: - Typography
    
    struct Typography {
        /// Системный SF Pro: `design: .default` на iOS даёт San Francisco (то, что в интерфейсе Apple).
        static func font(weight: FontWeight, size: CGFloat) -> Font {
            Font.system(size: size, weight: weight.swiftUI, design: .default)
        }

        static func uiFont(weight: FontWeight, size: CGFloat) -> UIFont {
            UIFont.systemFont(ofSize: size, weight: weight.uiKit)
        }

        /// Подписи таббара: активный — semibold, неактивный — medium.
        static func tabBar(isActive: Bool) -> Font {
            font(weight: isActive ? .semiBold : .medium, size: 10.5)
        }

        static let title = font(weight: .semiBold, size: 28)
        static let navigationTitle = font(weight: .semiBold, size: 24)
        static let subtitle = font(weight: .semiBold, size: 18)
        static let cardTitle = font(weight: .bold, size: 18)
        static let body = font(weight: .medium, size: 16)
        static let bodySecondary = font(weight: .medium, size: 14)
        /// Третичный текст (подписи полей 13 pt).
        static let bodyTertiary = font(weight: .medium, size: 13)
        static let caption = font(weight: .medium, size: 12)
        static let button = font(weight: .bold, size: 18)
        static let buttonSmall = font(weight: .bold, size: 16)
        static let price = font(weight: .bold, size: 20)
        /// Заголовок блока преимуществ / акцента (тот же кегль, что price — Bold 20).
        static let featureTitle = font(weight: .bold, size: 20)
        static let period = font(weight: .medium, size: 12)
        static let badge = font(weight: .semiBold, size: 12)

        /// Крупный подзаголовок (например имя бренда в деталях медиа).
        static let headline = font(weight: .medium, size: 20)
        static let modalTitle = font(weight: .bold, size: 24)
        static let overlayTitle = font(weight: .bold, size: 22)
        /// Чип токенов в навбаре (`ProStatusBadge`): чуть крупнее для читаемости на тап.
        static let navigationBadge = font(weight: .bold, size: 15)
        /// Поля ввода на экране создания.
        static let field = font(weight: .medium, size: 15)
        static let sectionLabel = font(weight: .semiBold, size: 14)
        static let sectionLabelSmall = font(weight: .semiBold, size: 13)
        static let labelMicro = font(weight: .semiBold, size: 11)
        static let micro = font(weight: .semiBold, size: 10)
        static let emphasis = font(weight: .bold, size: 17)
        /// Заголовки строк в списках настроек (Medium 18).
        static let listRowTitle = font(weight: .medium, size: 18)
    }
    
    // MARK: - Spacing
    
    struct Spacing {
        /// Маленький отступ
        static let small: CGFloat = 8
        
        /// Средний отступ
        static let medium: CGFloat = 16
        
        /// Большой отступ
        static let large: CGFloat = 24
        
        /// Очень большой отступ
        static let extraLarge: CGFloat = 32
        
        /// Горизонтальный отступ для экранов
        static let screenHorizontal: CGFloat = 24
        
        /// Вертикальный отступ для экранов
        static let screenVertical: CGFloat = 32
    }
    
    // MARK: - Corner Radius
    
    struct CornerRadius {
        /// Маленький радиус
        static let small: CGFloat = 8
        
        /// Средний радиус
        static let medium: CGFloat = 12
        
        /// Большой радиус
        static let large: CGFloat = 16
        
        /// Очень большой радиус
        static let extraLarge: CGFloat = 24
    }
    
    // MARK: - Shadows
    
    struct Shadows {
        /// Легкая тень
        static let light = Shadow(
            color: .black.opacity(0.1),
            radius: 4,
            x: 0,
            y: 2
        )
        
        /// Средняя тень
        static let medium = Shadow(
            color: .black.opacity(0.15),
            radius: 8,
            x: 0,
            y: 4
        )
        
        /// Сильная тень
        static let heavy = Shadow(
            color: .black.opacity(0.2),
            radius: 12,
            x: 0,
            y: 6
        )
    }
    
    // MARK: - Animations
    
    struct Animations {
        /// Быстрая анимация
        static let fast = Animation.easeInOut(duration: 0.2)
        
        /// Средняя анимация
        static let medium = Animation.easeInOut(duration: 0.3)
        
        /// Медленная анимация
        static let slow = Animation.easeInOut(duration: 0.5)
        
        /// Пружинная анимация
        static let spring = Animation.spring(response: 0.5, dampingFraction: 0.8)
    }
}

// MARK: - Shadow Structure

struct Shadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Status Bar Background Modifier

struct StatusBarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            content
            
            VStack {
                Rectangle()
                    .fill(AppTheme.Colors.background)
                    .frame(height: 0) // Will be sized by safe area
                    .ignoresSafeArea(.all, edges: .top)
                
                Spacer()
            }
            .allowsHitTesting(false) // Don't interfere with touch events
        }
    }
}

// MARK: - Theme Aware View Modifier

struct ThemeAwareViewModifier: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared
    
    func body(content: Content) -> some View {
        content
            // Явно связываем SwiftUI colorScheme с выбранной темой, чтобы избежать
            // промежуточных состояний и белых "флэшей" при раннем переключении после запуска.
            .environment(\.colorScheme, themeManager.currentTheme == .dark ? .dark : .light)
    }
}

// MARK: - Plain button press (светлая тема)

/// В light системный highlight на `Button` даёт слишком сильную прозрачность: пиллы `cardBackground` и синие градиенты почти сливаются с белым фоном.
/// Заменяет `.plain` на контролируемое лёгкое затемнение; в dark оставляем чуть заметнее.
struct ThemedPlainButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(labelOpacity(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func labelOpacity(isPressed: Bool) -> CGFloat {
        guard isPressed else { return 1 }
        return themeManager.currentTheme == .light ? 0.94 : 0.86
    }
}

// MARK: - View Extensions

extension View {
    /// Кнопки/чипы: без «провала» при нажатии в светлой теме (см. `ThemedPlainButtonStyle`).
    func appPlainButtonStyle() -> some View {
        buttonStyle(ThemedPlainButtonStyle())
    }

    /// Применить автоматическое обновление при смене темы
    func themeAware() -> some View {
        self.modifier(ThemeAwareViewModifier())
    }
    
    /// Анимация смены темы теперь задаётся централизованно в ThemeManager.toggleTheme().
    /// Оставлен no-op, чтобы не ломать существующие вызовы; при чистке кода можно удалить.
    func themeAnimation() -> some View {
        self
    }
    /// Применить фон для status bar
    func statusBarBackground() -> some View {
        self.modifier(StatusBarBackgroundModifier())
    }
    
    /// Применить стандартную тень
    func standardShadow() -> some View {
        self.shadow(
            color: AppTheme.Shadows.medium.color,
            radius: AppTheme.Shadows.medium.radius,
            x: AppTheme.Shadows.medium.x,
            y: AppTheme.Shadows.medium.y
        )
    }
    
    /// Применить легкую тень
    func lightShadow() -> some View {
        self.shadow(
            color: AppTheme.Shadows.light.color,
            radius: AppTheme.Shadows.light.radius,
            x: AppTheme.Shadows.light.x,
            y: AppTheme.Shadows.light.y
        )
    }
    
    /// Применить стандартные отступы экрана
    func screenPadding() -> some View {
        self.padding(.horizontal, AppTheme.Spacing.screenHorizontal)
    }
    
    /// Применить стандартный радиус для карточек
    func cardStyle() -> some View {
        self
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.CornerRadius.large)
            .standardShadow()
    }
    
    /// Применить стиль для кнопок
    func buttonStyle() -> some View {
        self
            .font(AppTheme.Typography.button)
            .foregroundColor(AppTheme.Colors.onPrimaryText)
            .primaryCTAChrome(isEnabled: true, fill: .solidAccent)
    }
    
    /// Применить стиль для вторичных кнопок
    func secondaryButtonStyle() -> some View {
        self
            .font(AppTheme.Typography.buttonSmall)
            .foregroundColor(AppTheme.Colors.textSecondary)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.CornerRadius.medium)
    }
}

 
