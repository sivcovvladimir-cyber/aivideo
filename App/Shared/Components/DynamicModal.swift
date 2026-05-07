import SwiftUI

// MARK: - Input Field Types

enum InputFieldType {
    case singleLine(placeholder: String, isSecure: Bool = false)
    case multiLine(placeholder: String, lineLimit: ClosedRange<Int> = 3...6)
    case password(placeholder: String = "Enter password")
    
    var placeholder: String {
        switch self {
        case .singleLine(let placeholder, _):
            return placeholder
        case .multiLine(let placeholder, _):
            return placeholder
        case .password(let placeholder):
            return placeholder
        }
    }
    
    var isSecure: Bool {
        switch self {
        case .singleLine(_, let isSecure):
            return isSecure
        case .multiLine:
            return false
        case .password:
            return true
        }
    }
    
    var isMultiLine: Bool {
        switch self {
        case .singleLine:
            return false
        case .multiLine:
            return true
        case .password:
            return false
        }
    }
    
    var lineLimit: ClosedRange<Int>? {
        switch self {
        case .singleLine:
            return nil
        case .multiLine(_, let lineLimit):
            return lineLimit
        case .password:
            return nil
        }
    }
}

// MARK: - Dynamic Modal Configuration

struct DynamicModalConfig {
    let title: String
    let description: String
    let primaryButtonTitle: String
    let secondaryButtonTitle: String
    let iconName: String
    let primaryAction: () -> Void
    let secondaryAction: (() -> Void)?
    
    // Input field configuration
    let showInputField: Bool
    let inputFieldType: InputFieldType?
    let inputText: Binding<String>?
    let optionalSecondaryPlaceholder: String?
    let optionalSecondaryText: Binding<String>?
    let inputAction: ((String) -> Void)?
    let inputActionWithSecondary: ((String, String) -> Void)?
    let inputValidationError: ((String) -> Void)?
    
    // Dismiss configuration
    let allowDismissOnBackgroundTap: Bool

    /// Блок «шары + иконка» над заголовком; для компактных диалогов можно отключить.
    let showsHeroDecoration: Bool
    
    init(
        title: String,
        description: String,
        primaryButtonTitle: String = "OK",
        secondaryButtonTitle: String = "Cancel",
        iconName: String = "star.fill",
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil,
        showInputField: Bool = false,
        inputFieldType: InputFieldType? = nil,
        inputText: Binding<String>? = nil,
        optionalSecondaryPlaceholder: String? = nil,
        optionalSecondaryText: Binding<String>? = nil,
        inputAction: ((String) -> Void)? = nil,
        inputActionWithSecondary: ((String, String) -> Void)? = nil,
        inputValidationError: ((String) -> Void)? = nil,
        allowDismissOnBackgroundTap: Bool = true,
        showsHeroDecoration: Bool = true
    ) {
        self.title = title
        self.description = description
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.iconName = iconName
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.showInputField = showInputField
        self.inputFieldType = inputFieldType
        self.inputText = inputText
        self.optionalSecondaryPlaceholder = optionalSecondaryPlaceholder
        self.optionalSecondaryText = optionalSecondaryText
        self.inputAction = inputAction
        self.inputActionWithSecondary = inputActionWithSecondary
        self.inputValidationError = inputValidationError
        self.allowDismissOnBackgroundTap = allowDismissOnBackgroundTap
        self.showsHeroDecoration = showsHeroDecoration
    }
}

// MARK: - Dynamic Modal View

struct DynamicModal: View {
    @Binding var isPresented: Bool
    let config: DynamicModalConfig
    @State private var internalText = ""
    @State private var internalSecondaryText = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Полупрозрачный фон
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    // Закрываем при тапе на фон только если разрешено
                    if config.allowDismissOnBackgroundTap {
                        dismissModal()
                    }
                }
            
            // Модальное окно
            VStack(spacing: 24) {
                if config.showsHeroDecoration {
                    // Композиция с шарами и иконкой
                    ZStack(alignment: .center) {
                        Image("Balls")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .foregroundStyle(AppTheme.Colors.primaryGradient)

                        Image(systemName: config.iconName)
                            .font(.system(size: 50, weight: .semibold))
                            .foregroundColor(.white)
                            .offset(x: 1.5)
                    }
                    .frame(width: 120, height: 120)
                }

                // Заголовок
                Text(config.title)
                    .font(AppTheme.Typography.modalTitle)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                
                // Описание
                Text(config.description)
                    .font(AppTheme.Typography.body)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                
                // Поле ввода (если включено)
                if config.showInputField, 
                   let inputFieldType = config.inputFieldType {
                    VStack(alignment: .leading, spacing: 8) {
                        Group {
                            if inputFieldType.isSecure {
                                SecureField(inputFieldType.placeholder, text: $internalText)
                                    .focused($isTextFieldFocused)
                            } else if inputFieldType.isMultiLine {
                                TextField(inputFieldType.placeholder, text: $internalText, axis: .vertical)
                                    .lineLimit(inputFieldType.lineLimit ?? 3...6)
                                    .focused($isTextFieldFocused)
                            } else {
                                TextField(inputFieldType.placeholder, text: $internalText)
                                    .focused($isTextFieldFocused)
                            }
                        }
                        .environment(\.colorScheme, AppTheme.current == .dark ? .dark : .light)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.Colors.textPrimary)
                        .accentColor(AppTheme.Colors.primary)
                        .padding(16)
                        .background(AppTheme.Colors.cardBackground)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(AppTheme.Colors.border, lineWidth: 1)
                        )
                        .onSubmit {
                            if let inputActionWithSecondary = config.inputActionWithSecondary {
                                inputActionWithSecondary(internalText, internalSecondaryText)
                            } else if let inputAction = config.inputAction {
                                inputAction(internalText)
                            }
                        }

                        if let secondaryPlaceholder = config.optionalSecondaryPlaceholder,
                           config.optionalSecondaryText != nil {
                            TextField(secondaryPlaceholder, text: $internalSecondaryText)
                                .environment(\.colorScheme, AppTheme.current == .dark ? .dark : .light)
                                .font(AppTheme.Typography.body)
                                .foregroundColor(AppTheme.Colors.textPrimary)
                                .accentColor(AppTheme.Colors.primary)
                                .padding(16)
                                .background(AppTheme.Colors.cardBackground)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(AppTheme.Colors.border, lineWidth: 1)
                                )
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                    }
                }
                
                // Кнопки
                VStack(spacing: 12) {
                    // Основная кнопка
                    Button(action: {
                        // Если есть поле ввода и обработчик, передаем текст напрямую
                        if config.showInputField, 
                           (config.inputAction != nil || config.inputActionWithSecondary != nil) {
                            // Получаем текст из TextField напрямую
                            let currentText = internalText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let secondaryText = internalSecondaryText.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Проверяем, что поле не пустое
                            if currentText.isEmpty {
                                // Показываем ошибку валидации
                                if let validationError = config.inputValidationError {
                                    validationError("Field cannot be empty")
                                }
                                return // Не закрываем модал
                            }
                            if let inputActionWithSecondary = config.inputActionWithSecondary {
                                inputActionWithSecondary(currentText, secondaryText)
                            } else if let inputAction = config.inputAction {
                                inputAction(currentText)
                            }
                            // Не закрываем модал автоматически - пусть inputAction сам решает
                        } else {
                            config.primaryAction()
                            dismissModal()
                        }
                    }) {
                        Text(config.primaryButtonTitle)
                            .font(AppTheme.Typography.cardTitle)
                            .foregroundColor(.white)
                            // Та же заливка, что у главных CTA (генерация, пейвол), а не плоский `primary` из `.solidAccent`.
                            .primaryCTAChrome(isEnabled: true, fill: .productGradient)
                    }
                    .appPlainButtonStyle()
                    
                    // Вторичная кнопка
                    Button(action: {
                        if let secondaryAction = config.secondaryAction {
                            secondaryAction()
                        }
                        dismissModal()
                    }) {
                        Text(config.secondaryButtonTitle)
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .appPlainButtonStyle()
                }
            }
            .padding(32)
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(24)
            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale))
        .animation(.easeInOut(duration: 0.3), value: isPresented)
        .zIndex(1000) // Убеждаемся, что модальное окно поверх всего
        .onAppear {
            if let text = config.inputText?.wrappedValue {
                internalText = text
            }
            if let secondaryText = config.optionalSecondaryText?.wrappedValue {
                internalSecondaryText = secondaryText
            }
        }

    }
    
    private func dismissModal() {
        isPresented = false
    }
}

// MARK: - Dynamic Modal Manager

class DynamicModalManager: ObservableObject {
    @Published var isPresented: Bool = false
    @Published var currentConfig: DynamicModalConfig?
    
    func showModal(with config: DynamicModalConfig) {
        currentConfig = config
        isPresented = true
    }
    
    func dismissModal() {
        isPresented = false
        currentConfig = nil
    }
}

// MARK: - View Extension for Easy Usage

extension View {
    func dynamicModal(
        isPresented: Binding<Bool>,
        config: DynamicModalConfig
    ) -> some View {
        self.overlay(
            Group {
                if isPresented.wrappedValue {
                    DynamicModal(isPresented: isPresented, config: config)
                }
            }
        )
    }
    
    func dynamicModal(
        manager: DynamicModalManager
    ) -> some View {
        self.overlay(
            Group {
                if manager.isPresented {
                    if let config = manager.currentConfig {
                        DynamicModal(isPresented: Binding(
                            get: { manager.isPresented },
                            set: { manager.isPresented = $0 }
                        ), config: config)
                    }
                }
            }
        )
    }
}

// MARK: - Predefined Configurations

extension DynamicModalConfig {
    // Конфигурация для оценки приложения
    static func appRating(
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: "do_you_like_this_app".localized,
            description: "app_rating_description".localized,
            primaryButtonTitle: "yes_i_like_this_app".localized,
            secondaryButtonTitle: "no_i_dont".localized,
            iconName: "star.fill",
            primaryAction: primaryAction,
            secondaryAction: secondaryAction,
            allowDismissOnBackgroundTap: false // Запрещаем закрытие по тапу на фон для окна рейтинга
        )
    }
    
    // Конфигурация для подтверждения действия
    static func confirmation(
        title: String,
        description: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: "confirm".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "checkmark.circle.fill",
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        )
    }
    
    // Конфигурация для успеха
    static func success(
        title: String,
        description: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: "ok".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "checkmark.circle.fill",
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        )
    }
    
    // Конфигурация для ошибки
    static func error(
        title: String,
        description: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: "ok".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "xmark.circle.fill",
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        )
    }
    
    // Конфигурация для ввода пароля
    static func passwordInput(
        title: String,
        description: String,
        placeholder: String = "Enter password",
        inputText: Binding<String>,
        primaryAction: @escaping (String) -> Void,
        secondaryAction: (() -> Void)? = nil,
        validationError: ((String) -> Void)? = nil
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: "confirm".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "lock.fill",
            primaryAction: { },
            secondaryAction: secondaryAction,
            showInputField: true,
            inputFieldType: .password(placeholder: placeholder),
            inputText: inputText,
            inputAction: primaryAction,
            inputValidationError: validationError,
            allowDismissOnBackgroundTap: false
        )
    }
    
    // Конфигурация для однострочного ввода
    static func singleLineInput(
        title: String,
        description: String,
        placeholder: String,
        inputText: Binding<String>,
        primaryAction: @escaping (String) -> Void,
        secondaryAction: (() -> Void)? = nil,
        validationError: ((String) -> Void)? = nil,
        isSecure: Bool = false
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: "confirm".localized,
            secondaryButtonTitle: "cancel".localized,
            iconName: "doc.text.fill",
            primaryAction: { },
            secondaryAction: secondaryAction,
            showInputField: true,
            inputFieldType: .singleLine(placeholder: placeholder, isSecure: isSecure),
            inputText: inputText,
            inputAction: primaryAction,
            inputValidationError: validationError,
            allowDismissOnBackgroundTap: false
        )
    }
    
    // Конфигурация для многострочного ввода
    static func multiLineInput(
        title: String,
        description: String,
        placeholder: String,
        inputText: Binding<String>,
        allowDismissOnBackgroundTap: Bool = false,
        primaryButtonTitle: String = "confirm".localized,
        primaryAction: @escaping (String) -> Void,
        secondaryAction: (() -> Void)? = nil,
        validationError: ((String) -> Void)? = nil,
        lineLimit: ClosedRange<Int> = 3...6
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: "cancel".localized,
            iconName: "envelope.fill",
            primaryAction: { },
            secondaryAction: secondaryAction,
            showInputField: true,
            inputFieldType: .multiLine(placeholder: placeholder, lineLimit: lineLimit),
            inputText: inputText,
            inputAction: primaryAction,
            inputValidationError: validationError,
            allowDismissOnBackgroundTap: allowDismissOnBackgroundTap
        )
    }

    // Конфигурация для многострочного ввода + optional второго поля (например email для ответа).
    static func multiLineInput(
        title: String,
        description: String,
        placeholder: String,
        inputText: Binding<String>,
        optionalSecondaryPlaceholder: String,
        optionalSecondaryText: Binding<String>,
        allowDismissOnBackgroundTap: Bool = true,
        primaryButtonTitle: String = "confirm".localized,
        primaryAction: @escaping (String, String) -> Void,
        secondaryAction: (() -> Void)? = nil,
        validationError: ((String) -> Void)? = nil,
        lineLimit: ClosedRange<Int> = 3...6
    ) -> DynamicModalConfig {
        return DynamicModalConfig(
            title: title,
            description: description,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: "cancel".localized,
            iconName: "envelope.fill",
            primaryAction: { },
            secondaryAction: secondaryAction,
            showInputField: true,
            inputFieldType: .multiLine(placeholder: placeholder, lineLimit: lineLimit),
            inputText: inputText,
            optionalSecondaryPlaceholder: optionalSecondaryPlaceholder,
            optionalSecondaryText: optionalSecondaryText,
            inputActionWithSecondary: primaryAction,
            inputValidationError: validationError,
            allowDismissOnBackgroundTap: allowDismissOnBackgroundTap
        )
    }
} 