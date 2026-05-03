import Foundation

enum PromptGenerationKind {
    case video(durationSeconds: Int, audioEnabled: Bool)
    case photo
}

struct GenerationCostCalculator {
    private let logic: PaywallConfig.LogicConfig

    init(config: PaywallConfig? = PaywallCacheManager.shared.paywallConfig) {
        self.logic = config?.logic ?? .getDefault()
    }

    // Стоимость эффекта берётся из БД только если `token_cost` не NULL; иначе действует глобальный конфиг.
    func effectGenerationCost(presetTokenCost: Int?) -> Int {
        if let presetTokenCost {
            return max(0, presetTokenCost)
        }

        return max(0, logic.tokensPerEffectGeneration ?? PaywallConfig.LogicConfig.defaultTokensPerEffectGeneration)
    }

    func promptGenerationCost(kind: PromptGenerationKind) -> Int {
        switch kind {
        case .video(let durationSeconds, let audioEnabled):
            let seconds = max(0, durationSeconds)
            let perSecond = max(0, logic.promptVideoTokensPerSecond ?? PaywallConfig.LogicConfig.defaultPromptVideoTokensPerSecond)
            // Аудио: доплата за каждую секунду ролика (не единоразовая сумма за toggle).
            let audioTokensPerSecond = max(0, logic.promptVideoAudioAddonTokens ?? PaywallConfig.LogicConfig.defaultPromptVideoAudioAddonTokens)
            let audioAddon = audioEnabled ? seconds * audioTokensPerSecond : 0
            return seconds * perSecond + audioAddon

        case .photo:
            return max(0, logic.promptPhotoGenerationTokens ?? PaywallConfig.LogicConfig.defaultPromptPhotoGenerationTokens)
        }
    }

    var startingTokenBalance: Int {
        max(0, logic.startingTokenBalance ?? PaywallConfig.LogicConfig.defaultStartingTokenBalance)
    }

    var dailyTokenAllowance: Int {
        max(0, logic.dailyTokenAllowance ?? PaywallConfig.LogicConfig.defaultDailyTokenAllowance)
    }

    /// Базовые токены за 1 с prompt-видео (без доплаты за аудио).
    var promptVideoTokenCostPerSecond: Int {
        max(0, logic.promptVideoTokensPerSecond ?? PaywallConfig.LogicConfig.defaultPromptVideoTokensPerSecond)
    }
}
