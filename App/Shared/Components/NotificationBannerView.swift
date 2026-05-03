import SwiftUI
import Combine
import UIKit

// MARK: - Notification Types
enum NotificationType {
    case error
    case success
    case info
    
    var backgroundColor: Color {
        switch self {
        case .error:
            return Color.red
        case .success:
            return Color.green
        case .info:
            return Color.blue
        }
    }
    
    var icon: String {
        switch self {
        case .error:
            return "exclamationmark.triangle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    /// Ошибка дольше (прочитать текст важнее); success и info короче на ~1 с, чтобы баннер не задерживал экран.
    var displayDuration: TimeInterval {
        switch self {
        case .error:
            return 3.0
        case .success:
            return 1.5
        case .info:
            return 2.0
        }
    }
}

/// Размер окна баннера: `.compact` — узкая карточка и лимит строк; `.fitContent` — высота/ширина под полный текст (без обрезки по строкам).
enum NotificationBannerSizing: Equatable {
    case compact
    case fitContent
}

struct NotificationBannerView: View {
    let message: String
    let type: NotificationType
    let isVisible: Bool
    let onDismiss: () -> Void
    let customDuration: TimeInterval?
    
    @State private var offset: CGFloat = -200
    @State private var opacity: Double = 0
    
    var body: some View {
        VStack {
            if isVisible {
                HStack(spacing: 12) {
                    // Иконка уведомления
                    Image(systemName: type.icon)
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .semibold))
                    
                                // Текст уведомления
            Text(message)
                .font(AppTheme.Typography.bodySecondary)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                    
                    Spacer()
                    
                    // Кнопка закрытия
                    Button(action: {
                        hideBanner()
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            type.backgroundColor,
                            type.backgroundColor
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 20) // Увеличили отступ сверху для опускания баннера ниже
                .offset(y: offset)
                .opacity(opacity)
                .onAppear {
                    showBanner()
                }
            }
            
            Spacer()
        }
        .zIndex(1000) // Высокий z-index чтобы быть поверх всего
    }
    
    private func showBanner() {
        withAnimation(.easeOut(duration: 0.3)) {
            offset = 0
            opacity = 1
        }
        
        // Автоматически скрываем через заданное время
        let duration = customDuration ?? type.displayDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            hideBanner()
        }
    }
    
    private func hideBanner() {
        withAnimation(.easeIn(duration: 0.3)) {
            offset = -200
            opacity = 0
        }
        
        // Вызываем callback после завершения анимации
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Notification Manager
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    // Overlay window properties
    private var notificationWindows: [(window: UIWindow, id: UUID)] = []
    private var notificationCount = 0
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Показать уведомление
    func showNotification(
        _ message: String,
        type: NotificationType = .error,
        customDuration: TimeInterval? = nil,
        sizing: NotificationBannerSizing = .compact
    ) {
        DispatchQueue.main.async {
            self.createNotificationWindow(message: message, type: type, customDuration: customDuration, sizing: sizing)
        }
    }
    
    /// Показать ошибку; `customDuration` и `sizing: .fitContent` — для длинных сообщений (окно под контент, без `lineLimit`).
    func showError(_ message: String, customDuration: TimeInterval? = nil, sizing: NotificationBannerSizing = .compact) {
        showNotification(message, type: .error, customDuration: customDuration, sizing: sizing)
    }
    
    /// Показать успешное уведомление
    func showSuccess(_ message: String) {
        showNotification(message, type: .success)
    }
    
    /// Показать информационное уведомление
    func showInfo(_ message: String, customDuration: TimeInterval? = nil) {
        showNotification(message, type: .info, customDuration: customDuration)
    }
    
    // MARK: - Private Methods
    
    /// Очистить все уведомления
    func clearQueue() {
        DispatchQueue.main.async {
            for notificationWindow in self.notificationWindows {
                notificationWindow.window.isHidden = true
            }
            self.notificationWindows.removeAll()
        }
    }
    
    // MARK: - Overlay Window Methods
    
    private func createNotificationWindow(message: String, type: NotificationType, customDuration: TimeInterval?, sizing: NotificationBannerSizing) {
        let notificationId = UUID()
        
        // Вычисляем позицию для нового уведомления с учетом высоты предыдущих
        let topOffset = calculateTopOffsetForNewNotification()
        
        // Создаем новое окно с размером только под уведомление
        let screenWidth = UIScreen.main.bounds.width
        let screenH = UIScreen.main.bounds.height
        // `.fitContent`: стартовая высота выше, затем окно подгоняется по измерению SwiftUI (`onSizeChanged`).
        let notificationHeight: CGFloat = sizing == .fitContent
            ? min(screenH * 0.48, 380)
            : 100
        let windowFrame = CGRect(
            x: 0,
            y: topOffset,
            width: screenWidth,
            height: notificationHeight
        )
        
        let window: UIWindow
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: windowScene)
            window.frame = windowFrame
        } else {
            window = UIWindow(frame: windowFrame)
        }
        
        window.windowLevel = UIWindow.Level(rawValue: 9999)
        window.backgroundColor = UIColor.clear
        window.isUserInteractionEnabled = true
        
        // Создаем SwiftUI view для уведомления
        let notificationView = StackedNotificationView(
            message: message,
            type: type,
            sizing: sizing,
            onDismiss: {
                // Удаляем это конкретное окно
                self.removeNotificationWindow(withId: notificationId)
            },
            onSizeChanged: { newHeight in
                // Обновляем размер окна и пересчитываем позиции
                self.updateNotificationWindowSize(window: window, newHeight: newHeight)
            },
            customDuration: customDuration
        )
        
        let hostingController = UIHostingController(rootView: notificationView)
        hostingController.view.backgroundColor = UIColor.clear
        hostingController.view.isUserInteractionEnabled = true
        
        window.rootViewController = hostingController
        window.isHidden = false
        
        // Добавляем окно в массив
        notificationWindows.append((window: window, id: notificationId))
        notificationCount += 1
    }
    
    private func removeNotificationWindow(withId id: UUID) {
        // Находим и удаляем окно
        if let index = notificationWindows.firstIndex(where: { $0.id == id }) {
            let windowToRemove = notificationWindows[index].window
            notificationWindows.remove(at: index)
            windowToRemove.isHidden = true
            
            // Обновляем позиции оставшихся уведомлений
            updateNotificationPositions()
        }
    }
    
    private func updateNotificationWindowSize(window: UIWindow, newHeight: CGFloat) {
        // Обновляем размер окна
        let screenWidth = UIScreen.main.bounds.width
        let newFrame = CGRect(
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: screenWidth,
            height: newHeight
        )
        
        UIView.animate(withDuration: 0.2) {
            window.frame = newFrame
        }
        
        // Пересчитываем позиции всех уведомлений после этого
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.updateNotificationPositions()
        }
    }
    
    private func calculateTopOffsetForNewNotification() -> CGFloat {
        // Получаем safe area для правильного отступа сверху
        let safeAreaTop: CGFloat
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            safeAreaTop = windowScene.windows.first?.safeAreaInsets.top ?? 0
        } else {
            safeAreaTop = 0
        }
        
        var totalHeight: CGFloat = safeAreaTop + 20 // Отступ с учетом safe area
        
        for notificationWindow in notificationWindows {
            totalHeight += notificationWindow.window.frame.height + 8 // 8px отступ между уведомлениями
        }
        
        return totalHeight
    }
    
    private func updateNotificationPositions() {
        // Получаем safe area для правильного отступа сверху
        let safeAreaTop: CGFloat
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            safeAreaTop = windowScene.windows.first?.safeAreaInsets.top ?? 0
        } else {
            safeAreaTop = 0
        }
        
        var currentTopOffset: CGFloat = safeAreaTop + 20 // Начальный отступ с учетом safe area
        
        // Обновляем позиции всех окон с учетом их реальной высоты
        for notificationWindow in notificationWindows {
            let screenWidth = UIScreen.main.bounds.width
            let notificationHeight = notificationWindow.window.frame.height
            
            let newFrame = CGRect(
                x: 0,
                y: currentTopOffset,
                width: screenWidth,
                height: notificationHeight
            )
            
            // Анимированно обновляем позицию окна
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                notificationWindow.window.frame = newFrame
            }
            
            currentTopOffset += notificationHeight + 8 // 8px отступ между уведомлениями
        }
    }
    

}



// MARK: - Stacked Notification View
struct StackedNotificationView: View {
    let message: String
    let type: NotificationType
    let sizing: NotificationBannerSizing
    let onDismiss: () -> Void
    let onSizeChanged: ((CGFloat) -> Void)?
    let customDuration: TimeInterval?
    
    @State private var offset: CGFloat = -200
    @State private var opacity: Double = 0
    @State private var autoHideTimer: DispatchWorkItem?
    @State private var contentHeight: CGFloat = 0
    
    var body: some View {
        bannerBody
            .offset(y: offset)
            .opacity(opacity)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            contentHeight = geometry.size.height
                            onSizeChanged?(contentHeight)
                        }
                        .onChange(of: geometry.size.height) { _, newHeight in
                            if newHeight != contentHeight {
                                contentHeight = newHeight
                                onSizeChanged?(newHeight)
                            }
                        }
                }
            )
            .onAppear {
                showBanner()
                autoHideTimer?.cancel()
                let duration = customDuration ?? type.displayDuration
                let timer = DispatchWorkItem {
                    hideBanner()
                }
                autoHideTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timer)
            }
    }

    @ViewBuilder
    private var bannerBody: some View {
        switch sizing {
        case .compact:
            compactBannerChrome
        case .fitContent:
            fitContentBannerChrome
        }
    }

    private var compactBannerChrome: some View {
        HStack(spacing: 12) {
            Image(systemName: type.icon)
                .foregroundColor(.white)
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(AppTheme.Typography.bodySecondary)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
            Spacer()
            Image(systemName: "xmark")
                .foregroundColor(.white.opacity(0.8))
                .font(.system(size: 14, weight: .medium))
        }
        .contentShape(Rectangle())
        .onTapGesture { hideBanner() }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(bannerFill)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
    }

    /// Как `.compact` — иконка слева от текста и крестик справа; отличие: без `lineLimit`, шире поле текста, высота по контенту.
    private var fitContentBannerChrome: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: type.icon)
                .foregroundColor(.white)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 2)
            Text(message)
                .font(AppTheme.Typography.bodySecondary)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "xmark")
                .foregroundColor(.white.opacity(0.85))
                .font(.system(size: 14, weight: .medium))
                .padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { hideBanner() }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(bannerFill)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 8)
    }

    private var bannerFill: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                type.backgroundColor,
                type.backgroundColor
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private func showBanner() {
        withAnimation(.easeOut(duration: 0.3)) {
            offset = 0
            opacity = 1
        }
    }
    
    private func hideBanner() {
        // Отменяем автоматический таймер
        autoHideTimer?.cancel()
        
        withAnimation(.easeIn(duration: 0.3)) {
            offset = -200
            opacity = 0
        }
        
        // Вызываем callback после завершения анимации
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}



// MARK: - Preview
struct NotificationBannerView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                Text("Main Content")
                    .foregroundColor(.white)
                
                Button("Show Error") {
                    NotificationManager.shared.showError("This is a test error message.")
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.red)
                .cornerRadius(8)
                
                Button("Show Success") {
                    NotificationManager.shared.showSuccess("Operation completed successfully!")
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.green)
                .cornerRadius(8)
                
                Button("Show Info") {
                    NotificationManager.shared.showInfo("This is an informational message.")
                }
                .foregroundColor(.white)
                .padding()
                .background(Color.blue)
                .cornerRadius(8)
            }
        }
    }
}