import Foundation

/// Подсказка о недоступности CDN-превью (RU): sticky top banner через `FullWidthTopBannerCoordinator`.
enum PreviewMediaAccessNotifier {
    private enum BannerSlot {
        static let previewMediaR2 = "connectivity.previewMedia.r2"
    }

    private static var showsRegionalConnectivityHints: Bool {
        if #available(iOS 16, *) {
            return Locale.current.region?.identifier.uppercased() == "RU"
        }
        return (Locale.current.regionCode ?? "").uppercased() == "RU"
    }

    static func notifyR2PrimaryLoadFailed(originalURL: String) {
        guard PreviewMediaURLFallback.isR2Host(originalURL) else { return }
        guard showsRegionalConnectivityHints else { return }
        Task { @MainActor in
            FullWidthTopBannerCoordinator.shared.showInfo(
                id: BannerSlot.previewMediaR2,
                message: "preview_media_unreachable_vpn_hint".localized,
                maxAutoHideDuration: 10,
                priority: 5
            )
        }
    }

    static func notifyR2PrimaryLoadSucceeded(originalURL: String) {
        guard PreviewMediaURLFallback.isR2Host(originalURL) else { return }
        Task { @MainActor in
            FullWidthTopBannerCoordinator.shared.dismiss(id: BannerSlot.previewMediaR2)
        }
    }
}
