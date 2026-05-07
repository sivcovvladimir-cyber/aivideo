import Foundation

@MainActor
protocol GenerationBillingGateway: AnyObject {
    func spendTokensForGeneration(cost: Int) -> Bool
    func refundTokensForGeneration(cost: Int)
    func presentInsufficientTokensGate(requiredTokens: Int)
}

@MainActor
final class GenerationBillingService {
    static let shared = GenerationBillingService()

    private let gateway: GenerationBillingGateway

    private init(gateway: GenerationBillingGateway = AppState.shared) {
        self.gateway = gateway
    }

    // Централизует токен-биллинг генерации, чтобы orchestration-пайплайн не хранил детали wallet/gate.
    func reserveOrPresentPaywall(cost: Int) -> Bool {
        guard gateway.spendTokensForGeneration(cost: cost) else {
            gateway.presentInsufficientTokensGate(requiredTokens: cost)
            return false
        }
        return true
    }

    func refund(cost: Int) {
        gateway.refundTokensForGeneration(cost: cost)
    }
}

@MainActor
extension AppState: GenerationBillingGateway {}
