import Adapty
import Foundation

/// Журнал токенов, выданных за покупки/подписки: синхронизируется с профилем Adapty (purchase, renew, refund).
/// `generationLimits` (сколько токенов даёт продукт) берутся из bundled `paywall_config.json` с overlay из Adapty remote config.
///
/// Модель простая: каждое начисление (пакет или новый период подписки) — `+N` токенов; refund — `−N` тех же токенов
/// (баланс не уходит ниже нуля). Один grant = одна транзакция/период; повторные sync дедуплицируются по `id`.
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

    private init() {
        load()
    }

    /// Синхронизирует начисления и отзывы с актуальным профилем Adapty (launch, foreground, после покупки).
    func sync(with profile: AdaptyProfile) {
        reconcileNonSubscriptions(profile)
        reconcileSubscriptions(profile)
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

    private func reconcileNonSubscriptions(_ profile: AdaptyProfile) {
        for (_, purchases) in profile.nonSubscriptions {
            for purchase in purchases {
                let grantId = packGrantId(purchase)
                if purchase.isRefund {
                    revokeGrant(id: grantId)
                } else {
                    let tokens = tokenAmount(for: purchase.vendorProductId)
                    if grantIfNeeded(id: grantId, productId: purchase.vendorProductId, tokens: tokens),
                       isPackProductId(purchase.vendorProductId) {
                        AppState.shared.notePackGenerationsGranted(tokens)
                    }
                }
            }
        }
    }

    private func reconcileSubscriptions(_ profile: AdaptyProfile) {
        for (_, subscription) in profile.subscriptions {
            let grantId = subscriptionGrantId(subscription)
            // Refund подписки: снимаем токены только за refund-нутый период (ровно N).
            if subscription.isRefund {
                revokeGrant(id: grantId)
            } else if subscription.isActive {
                // Новый период = новый id → одно начисление +N за период (повторные sync внутри периода дедуплицируются).
                let tokens = tokenAmount(for: subscription.vendorProductId)
                grantIfNeeded(id: grantId, productId: subscription.vendorProductId, tokens: tokens)
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

    /// Отзыв grant при refund: снимаем выданное количество токенов (баланс не уходит ниже нуля).
    private func revokeGrant(id: String) {
        guard let index = grants.firstIndex(where: { $0.id == id && !$0.isRevoked }) else { return }
        let grant = grants[index]
        grants[index].isRevoked = true
        tokenWallet.clawBack(grant.tokensGranted)
        print("↩️ [PurchaseTokenLedger] refund −\(grant.tokensGranted) tokens grantId=\(id)")
    }

    // MARK: - Helpers

    private func hasGrant(id: String) -> Bool {
        grants.contains { $0.id == id }
    }

    private func tokenAmount(for productId: String) -> Int {
        max(0, PaywallCacheManager.shared.generationLimit(for: productId) ?? 0)
    }

    private func isPackProductId(_ productId: String) -> Bool {
        PaywallCacheManager.shared.paywallConfig?.purchasePlanIds?.contains(productId) == true
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Grant].self, from: data) else {
            grants = []
            return
        }
        grants = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
