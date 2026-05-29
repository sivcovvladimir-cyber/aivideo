import SwiftUI
import UIKit

/// Sticky full-width баннер под safe area: несколько слотов, стили info/error/success, tap, dismiss по слоту, опциональный max-таймер.
@MainActor
final class FullWidthTopBannerCoordinator {
    static let shared = FullWidthTopBannerCoordinator()

    struct Presentation: Equatable {
        let message: String
        let style: NotificationType
        /// Опциональный **максимум** на экране; `nil` — до tap или `dismiss(id:)`.
        let maxAutoHideDuration: TimeInterval?
        /// При нескольких активных слотах показывается баннер с наибольшим priority.
        let priority: Int

        init(
            message: String,
            style: NotificationType = .info,
            maxAutoHideDuration: TimeInterval? = nil,
            priority: Int = 0
        ) {
            self.message = message
            self.style = style
            self.maxAutoHideDuration = maxAutoHideDuration
            self.priority = priority
        }
    }

    private struct ActiveSlot {
        var presentation: Presentation
        var autoHideWorkItem: DispatchWorkItem?
    }

    private struct VisibleState: Equatable {
        let slotID: String
        let presentation: Presentation
    }

    private var activeSlots: [String: ActiveSlot] = [:]
    private var overlayWindow: UIWindow?
    private var visibleState: VisibleState?

    private init() {}

    func show(id: String, presentation: Presentation) {
        activeSlots[id]?.autoHideWorkItem?.cancel()
        activeSlots[id] = ActiveSlot(presentation: presentation, autoHideWorkItem: nil)
        scheduleAutoHideIfNeeded(for: id)
        refreshVisibleBanner()
    }

    func dismiss(id: String) {
        activeSlots[id]?.autoHideWorkItem?.cancel()
        activeSlots.removeValue(forKey: id)
        refreshVisibleBanner()
    }

    func dismissAll() {
        for id in activeSlots.keys {
            activeSlots[id]?.autoHideWorkItem?.cancel()
        }
        activeSlots.removeAll()
        hideOverlay()
    }

    private func scheduleAutoHideIfNeeded(for id: String) {
        guard var slot = activeSlots[id],
              let duration = slot.presentation.maxAutoHideDuration else { return }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.dismiss(id: id)
            }
        }
        slot.autoHideWorkItem = work
        activeSlots[id] = slot
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func refreshVisibleBanner() {
        guard let top = pickTopVisibleSlot() else {
            hideOverlay()
            return
        }

        let nextState = VisibleState(slotID: top.id, presentation: top.presentation)
        if visibleState == nextState, overlayWindow != nil { return }

        visibleState = nextState
        showOverlay(message: top.presentation.message, style: top.presentation.style)
    }

    private func pickTopVisibleSlot() -> (id: String, presentation: Presentation)? {
        activeSlots.max { lhs, rhs in
            let lp = lhs.value.presentation.priority
            let rp = rhs.value.presentation.priority
            if lp != rp { return lp < rp }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value.presentation) }
    }

    private func hideOverlay() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
        visibleState = nil
    }

    private func showOverlay(message: String, style: NotificationType) {
        overlayWindow?.isHidden = true
        overlayWindow = nil

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let screenBounds = windowScene.screen.bounds
        let screenWidth = screenBounds.width
        // Окно с y=0: фон закрашивает safe area; текст — в полосе под ней. Высота окна = safeTop + контент (остальной экран кликабелен).
        let safeTop: CGFloat
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
            safeTop = keyWindow.safeAreaInsets.top
        } else {
            safeTop = 0
        }
        let bannerBodyHeight: CGFloat = 44
        let windowHeight = safeTop + bannerBodyHeight
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: screenWidth, height: windowHeight)
        window.windowLevel = UIWindow.Level(rawValue: 9_999)
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = true

        let banner = FullWidthTopBannerView(
            message: message,
            style: style,
            safeTopInset: safeTop
        ) { [weak self] in
            self?.dismissAll()
        }

        let hosting = UIHostingController(rootView: banner)
        hosting.view.backgroundColor = .clear
        hosting.view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            hosting.safeAreaRegions = []
        }
        window.rootViewController = hosting
        window.isHidden = false
        overlayWindow = window
    }
}

extension FullWidthTopBannerCoordinator {
    func showInfo(
        id: String,
        message: String,
        maxAutoHideDuration: TimeInterval? = nil,
        priority: Int = 0
    ) {
        show(
            id: id,
            presentation: Presentation(
                message: message,
                style: .info,
                maxAutoHideDuration: maxAutoHideDuration,
                priority: priority
            )
        )
    }

    func showError(
        id: String,
        message: String,
        maxAutoHideDuration: TimeInterval? = nil,
        priority: Int = 0
    ) {
        show(
            id: id,
            presentation: Presentation(
                message: message,
                style: .error,
                maxAutoHideDuration: maxAutoHideDuration,
                priority: priority
            )
        )
    }

    func showSuccess(
        id: String,
        message: String,
        maxAutoHideDuration: TimeInterval? = nil,
        priority: Int = 0
    ) {
        show(
            id: id,
            presentation: Presentation(
                message: message,
                style: .success,
                maxAutoHideDuration: maxAutoHideDuration,
                priority: priority
            )
        )
    }
}

// MARK: - Full-width top banner (safe area)

struct FullWidthTopBannerView: View {
    let message: String
    let style: NotificationType
    let safeTopInset: CGFloat
    let onTapDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if safeTopInset > 0 {
                Color.clear
                    .frame(height: safeTopInset)
            }
            Text(message)
                .font(AppTheme.Typography.bodySecondary)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(style.backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture { onTapDismiss() }
        .ignoresSafeArea(edges: .top)
    }
}
