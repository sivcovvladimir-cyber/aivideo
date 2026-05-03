import SwiftUI

enum TopNavigationBarTitleAlignment {
    case center
    case leading
}

struct TopNavigationBar: View {
    let title: String
    let titleAlignment: TopNavigationBarTitleAlignment
    let showBackButton: Bool
    let showRightButton: Bool
    let rightButtonIcon: String?
    let rightButtonColor: Color?
    let customRightContent: AnyView?
    let onBackTap: () -> Void
    let onRightTap: () -> Void
    let backgroundColor: Color
    
    init(
        title: String,
        titleAlignment: TopNavigationBarTitleAlignment = .leading,
        showBackButton: Bool = true,
        showRightButton: Bool = false,
        rightButtonIcon: String? = nil,
        rightButtonColor: Color? = nil,
        customRightContent: AnyView? = nil,
        backgroundColor: Color = AppTheme.Colors.background,
        onBackTap: @escaping () -> Void = {},
        onRightTap: @escaping () -> Void = {}
    ) {
        self.title = title
        self.titleAlignment = titleAlignment
        self.showBackButton = showBackButton
        self.showRightButton = showRightButton
        self.rightButtonIcon = rightButtonIcon
        self.rightButtonColor = rightButtonColor
        self.customRightContent = customRightContent
        self.backgroundColor = backgroundColor
        self.onBackTap = onBackTap
        self.onRightTap = onRightTap
    }
    
    var body: some View {
        HStack {
            // Left button (Back or spacer)
            if showBackButton {
                Button(action: onBackTap) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.Colors.textPrimary)
                }
                .appPlainButtonStyle()
                .frame(width: 28)
            } else if titleAlignment == .center {
                Spacer()
                    .frame(width: 28)
            } else {
                // Для leading-тайтла не резервируем место под "невидимую" стрелку.
                Color.clear
                    .frame(width: 0)
            }
            
            if titleAlignment == .center {
                Spacer()
                Text(title)
                    .font(AppTheme.Typography.navigationTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
            } else {
                Text(title)
                    .font(AppTheme.Typography.navigationTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                Spacer()
            }
            
            // Right button or spacer
            if showRightButton, let rightIcon = rightButtonIcon {
                Button(action: onRightTap) {
                    Image(systemName: rightIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(rightButtonColor ?? AppTheme.Colors.textPrimary)
                        .opacity(0.9)
                }
                .appPlainButtonStyle()
                .frame(width: 28)
            } else {
                Spacer()
                    .frame(width: 28)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 16, bottom: 16, trailing: 16))
        // Кастомный правый элемент (например PRO-бейдж) рисуем поверх,
        // чтобы его ширина не сдвигала заголовок и он оставался по центру.
        .overlay(alignment: .trailing) {
            if let customRightContent {
                customRightContent
                    .padding(.trailing, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
            }
        }
        .frame(height: 60)
        .background(backgroundColor)
        .themeAware()
        .themeAnimation()
    }
}

// MARK: - PRO / токены в навбаре

/// Плашка справа сверху: при положительном балансе токенов показываем число; при нуле — подпись PRO (призыв к апгрейду). Иконка sparkles — единый визуальный якорь «AI‑расход».
struct ProStatusBadge: View {
    let tokenBalance: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                Text(tokenBalance > 0 ? "\(tokenBalance)" : "PRO")
                    .font(AppTheme.Typography.navigationBadge)
            }
            .foregroundColor(AppTheme.Colors.onPrimaryText)
            .padding(.horizontal, 17)
            .padding(.vertical, 9)
            .background(AppTheme.Colors.primaryGradient)
            .clipShape(Capsule())
        }
        .appPlainButtonStyle()
    }
}

// MARK: - Preview
struct TopNavigationBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            // Standard navigation bar with back button
            TopNavigationBar(
                title: "AI Video",
                showBackButton: true,
                onBackTap: {
                    print("Back tapped")
                }
            )
            
            // Navigation bar with right button (filter)
            TopNavigationBar(
                title: "Gallery",
                showBackButton: false,
                showRightButton: true,
                rightButtonIcon: "magnifyingglass",
                onRightTap: {
                    print("Filter tapped")
                }
            )
            
            // Settings navigation bar
            TopNavigationBar(
                title: "Settings",
                showBackButton: false,
                backgroundColor: AppTheme.Colors.background
            )
            
            Spacer()
        }
        .background(Color.black)
    }
} 