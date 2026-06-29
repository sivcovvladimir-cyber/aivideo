import Adapty
import Foundation

/// Журнал токенов, выданных за покупки/подписки: checkout выдаёт токены, sync с Adapty только отзывает refund.
/// `generationLimits` (сколько токенов даёт продукт) берутся из bundled `paywall_config.json` с overlay из Adapty remote config.
///
/// Важно: restore / transfer / family sharing / inherited Adapty child profiles не должны восстанавливать токены
/// на новом профиле или после reinstall. Поэтому `sync(with:)` не создаёт новые grants.
@MainActor
final class PurchaseTokenLedgerService {
    static let shared = PurchaseTokenLedgerService()

    struct Grant: Codable, Equatable {
        let id: String
        let productId: String
        let tokensGranted: Int
        var isRevoked: Bool
        let grantedAt: Date
    }

    private let storageKey = "aivideo_purchase_token_grants"
    private var grants: [Grant] = []
    private let tokenWallet = TokenWalletService.shared
    private let keychain = KeychainService.shared

    private init() {
        load()
    }

    /// Синхронизирует только отзывы с актуальным профилем Adapty.
    /// Новые токены выдаются исключительно из checkout-пути (`grantFromCheckout`), а не при restore/profile update.
    func sync(with profile: AdaptyProfile) {
        revokeRefundedNonSubscriptions(profile)
        revokeRefundedSubscriptions(profile)
        persist()
    }

    /// Немедленное начисление после checkout, когда профиль Adapty ещё не обновился (локальный StoreKit-путь).
    func grantFromCheckout(productId: String, tokens: Int, transactionId: String?) {
        let grantId = transactionId.map { "txn:\($0)" } ?? "checkout:\(productId):\(Self.checkoutBucket())"
        if grantIfNeeded(id: grantId, productId: productId, tokens: tokens), isPackProductId(productId) {
            AppState.shared.notePackGenerationsGranted(tokens)
        }
        persist()
    }

    // MARK: - Reconcile

    private func revokeRefundedNonSubscriptions(_ profile: AdaptyProfile) {
        for (_, purchases) in profile.nonSubscriptions {
            for purchase in purchases {
                if purchase.isRefund {
                    revokeGrant(id: packGrantId(purchase), fallbackProductId: purchase.vendorProductId)
                }
            }
        }
    }

    private func revokeRefundedSubscriptions(_ profile: AdaptyProfile) {
        for (_, subscription) in profile.subscriptions {
            if subscription.isRefund {
                revokeGrant(id: subscriptionGrantId(subscription), fallbackProductId: subscription.vendorProductId)
            }
        }
    }

    // MARK: - Grant / revoke

    /// Начисляет `+N` токенов один раз на `id`. Возвращает true, если grant создан впервые.
    @discardableResult
    private func grantIfNeeded(id: String, productId: String, tokens: Int) -> Bool {
        guard tokens > 0, !hasGrant(id: id) else { return false }
        tokenWallet.addTokens(tokens)
        grants.append(Grant(
            id: id,
            productId: productId,
            tokensGranted: tokens,
            isRevoked: false,
            grantedAt: Date()
        ))
        print("🎟️ [PurchaseTokenLedger] +\(tokens) tokens grantId=\(id) product=\(productId)")
        return true
    }

    /// Отзыв grant при refund: сначала ищем точный id транзакции, затем любой активный grant этого продукта.
    private func revokeGrant(id: String, fallbackProductId: String) {
        let exactIndex = grants.firstIndex { $0.id == id && !$0.isRevoked }
        let fallbackIndex = grants.firstIndex { $0.productId == fallbackProductId && !$0.isRevoked }
        guard let index = exactIndex ?? fallbackIndex else { return }
        let grant = grants[index]
        grants[index].isRevoked = true
        tokenWallet.clawBack(grant.tokensGranted)
        print("↩️ [PurchaseTokenLedger] refund −\(grant.tokensGranted) tokens grantId=\(id)")
    }

    // MARK: - Helpers

    private func hasGrant(id: String) -> Bool {
        grants.contains { $0.id == id }
    }

    private func isPackProductId(_ productId: String) -> Bool {
        PaywallCacheManager.shared.paywallConfig?.purchasePlanIds?.contains(productId) == true
    }

    var totalGrantCount: Int {
        grants.count
    }

    var activeGrantCount: Int {
        grants.filter { !$0.isRevoked }.count
    }

    var diagnosticsSnapshot: [String: Any] {
        [
            "grants_count": totalGrantCount,
            "active_grants_count": activeGrantCount,
            "revoked_grants_count": grants.filter(\.isRevoked).count,
            "active_product_ids": Array(Set(grants.filter { !$0.isRevoked }.map(\.productId))).sorted()
        ]
    }

    /// Стабильный id пакета по store-транзакции (совпадает с checkout-id из StoreKit), иначе по purchaseId Adapty.
    private func packGrantId(_ purchase: AdaptyProfile.NonSubscription) -> String {
        if let txn = purchase.vendorTransactionId { return "txn:\(txn)" }
        return "pack:\(purchase.purchaseId)"
    }

    /// id периода подписки: привязан к моменту продления/активации — новый период даёт новый id (значит новое `+N`).
    private func subscriptionGrantId(_ subscription: AdaptyProfile.Subscription) -> String {
        let marker = subscription.renewedAt ?? subscription.activatedAt ?? subscription.startsAt ?? Date.distantPast
        return "sub:\(subscription.vendorProductId):\(Int(marker.timeIntervalSince1970))"
    }

    private static func checkoutBucket() -> Int {
        Int(Date().timeIntervalSince1970 / 300)
    }

    // MARK: - Persistence

    private func load() {
        let storedData = keychain.getPurchaseTokenGrantsData() ?? UserDefaults.standard.data(forKey: storageKey)
        guard let data = storedData,
              let decoded = try? JSONDecoder().decode([Grant].self, from: data) else {
            grants = []
            return
        }
        grants = decoded
        if keychain.getPurchaseTokenGrantsData() == nil {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        keychain.setPurchaseTokenGrantsData(data)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
