import SwiftUI

/// Модификатор для добавления свайпа справа для закрытия экрана
/// Основан на рабочей реализации из MediaDetailView
struct EdgeSwipeDismissModifier: ViewModifier {
    let onDismiss: () -> Void
    @State private var edgeSwipeActive = false
    @State private var edgeSwipeOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: edgeSwipeOffset)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let screenWidth = UIScreen.main.bounds.width
                        let edgeZone = screenWidth * 0.075
                        
                        // Активируем свайп только если начали с левого края и двигаем вправо
                        if value.startLocation.x <= edgeZone && value.translation.width > 0 {
                            edgeSwipeActive = true
                            edgeSwipeOffset = value.translation.width
                        } else if edgeSwipeActive {
                            edgeSwipeOffset = value.translation.width
                        }
                    }
                    .onEnded { value in
                        if edgeSwipeActive && edgeSwipeOffset > 80 {
                            // Свайп достаточно далеко - закрываем экран
                            onDismiss()
                        } else {
                            // Возвращаем на место
                            withAnimation(.easeOut(duration: 0.2)) {
                                edgeSwipeOffset = 0
                            }
                        }
                        edgeSwipeActive = false
                    }
            )
    }
}

// MARK: - View Extension
extension View {
    /// Добавляет возможность закрытия экрана свайпом справа
    /// - Parameter onDismiss: Callback для закрытия экрана
    func edgeSwipeDismiss(onDismiss: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeDismissModifier(onDismiss: onDismiss))
    }
} 