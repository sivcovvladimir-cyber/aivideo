import SwiftUI

// MARK: - Каркас главной CTA

/// Как заполнять капсулу в активном состоянии: продуктовый градиент (генерация, пейвол, онбординг, `DynamicModal`) или плоский `Colors.primary` (где нужен спокойный акцент / `View.buttonStyle()` из темы).
enum PrimaryCTAFill: Equatable {
    case productGradient
    case solidAccent
}

/// Общие числа для главной CTA (вынесены из generic `PrimaryCTAChrome`: в Swift нельзя `static let` внутри обобщённого типа).
private enum PrimaryCTAMetrics {
    /// Основные полноширинные CTA (генерация, пейвол, загрузка фото): выше минимального 44 pt, визуально ближе к референсу Figma.
    static let standardHeight: CGFloat = 64
}

/// Общая оболочка полноширинной CTA: фиксированная высота `PrimaryCTAMetrics.standardHeight`, капсула, фон из темы; disabled-режим делаем приглушённым, но читаемым.
struct PrimaryCTAChrome<Content: View>: View {
    var isEnabled: Bool = true
    var fill: PrimaryCTAFill = .productGradient
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: PrimaryCTAMetrics.standardHeight)
            .background { backgroundView }
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var backgroundView: some View {
        if isEnabled {
            switch fill {
            case .productGradient:
                AppTheme.Colors.primaryGradient
            case .solidAccent:
                AppTheme.Colors.primary
            }
        } else {
            // Disabled: чуть ярче базы и брендового слоя, чем раньше — на тёмном фоне кнопка не «проваливается», но всё ещё явно неактивна.
            ZStack {
                LinearGradient(
                    colors: [
                        AppTheme.Colors.cardBackground.opacity(0.97),
                        AppTheme.Colors.background.opacity(0.94),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                AppTheme.Colors.primaryGradient
                    .opacity(0.36)
            }
        }
    }
}

extension View {
    /// Полноширинная основная CTA: капсула и фон из `AppTheme` (см. `PrimaryCTAChrome`).
    func primaryCTAChrome(isEnabled: Bool = true, fill: PrimaryCTAFill = .productGradient) -> some View {
        PrimaryCTAChrome(isEnabled: isEnabled, fill: fill) { self }
    }
}

// MARK: - Лейбл генерации (заголовок; опционально токены + sparkles)

/// При `tokenCost == nil` — только заголовок по центру. Иначе заголовок по центру кнопки, сумма и sparkles выровнены вправо (не смещают текст).
struct PrimaryGenerationButtonLabel: View {
    let title: String
    var tokenCost: Int?
    var isEnabled: Bool = true

    /// Отступ справа для блока «число + sparkles», чтобы не прилипал к скруглению кнопки.
    private let tokenClusterTrailingInset: CGFloat = 18

    init(title: String, tokenCost: Int? = nil, isEnabled: Bool = true) {
        self.title = title
        self.tokenCost = tokenCost
        self.isEnabled = isEnabled
    }

    var body: some View {
        PrimaryCTAChrome(isEnabled: isEnabled, fill: .productGradient) {
            Group {
                if let tokenCost {
                    ZStack {
                        Text(title)
                            .font(AppTheme.Typography.button)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 6) {
                            Text("\(tokenCost)")
                                .font(AppTheme.Typography.button)
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, tokenClusterTrailingInset)
                    }
                } else {
                    Text(title)
                        .font(AppTheme.Typography.button)
                }
            }
            .foregroundColor(isEnabled ? AppTheme.Colors.onPrimaryText : Color.white.opacity(0.66))
        }
    }
}
