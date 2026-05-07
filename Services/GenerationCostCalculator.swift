import Foundation

enum PromptGenerationKind {
    case video(durationSeconds: Int, audioEnabled: Bool)
    case photo
}

struct GenerationCostCalculator {
    private let logic: PaywallConfig.LogicConfig
    private static let fallbackStartingTokenBalance = 30
    private static let fallbackDailyTokenAllowance = 10
    private static let fallbackTokensPerEffectGeneration = 25
    private static let fallbackPromptVideoTokensPerSecond = 5
    private static let fallbackPromptVideoAudioAddonTokens = 2
    private static let fallbackPromptPhotoGenerationTokens = 1

    init(config: PaywallConfig? = PaywallCacheManager.shared.paywallConfig) {
        self.logic = config?.logic ?? .init()
    }

    // Стоимость эффекта берётся из БД только если `token_cost` не NULL; иначе действует глобальный конфиг.
    func effectGenerationCost(presetTokenCost: Int?) -> Int {
        if let presetTokenCost {
            return max(0, presetTokenCost)
        }

        return max(0, logic.tokensPerEffectGeneration ?? Self.fallbackTokensPerEffectGeneration)
    }

    func promptGenerationCost(kind: PromptGenerationKind) -> Int {
        switch kind {
        case .video(let durationSeconds, let audioEnabled):
            let seconds = max(0, durationSeconds)
            let perSecond = max(0, logic.promptVideoTokensPerSecond ?? Self.fallbackPromptVideoTokensPerSecond)
            // Аудио: доплата за каждую секунду ролика (не единоразовая сумма за toggle).
            let audioTokensPerSecond = max(0, logic.promptVideoAudioAddonTokens ?? Self.fallbackPromptVideoAudioAddonTokens)
            let audioAddon = audioEnabled ? seconds * audioTokensPerSecond : 0
            return seconds * perSecond + audioAddon

        case .photo:
            return max(0, logic.promptPhotoGenerationTokens ?? Self.fallbackPromptPhotoGenerationTokens)
        }
    }

    var startingTokenBalance: Int {
        max(0, logic.startingTokenBalance ?? Self.fallbackStartingTokenBalance)
    }

    var dailyTokenAllowance: Int {
        max(0, logic.dailyTokenAllowance ?? Self.fallbackDailyTokenAllowance)
    }

    /// Базовые токены за 1 с prompt-видео (без доплаты за аудио).
    var promptVideoTokenCostPerSecond: Int {
        max(0, logic.promptVideoTokensPerSecond ?? Self.fallbackPromptVideoTokensPerSecond)
    }
}
