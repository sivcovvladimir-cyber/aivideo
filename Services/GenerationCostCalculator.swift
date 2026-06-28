import Foundation

enum PromptGenerationKind {
    case video(durationSeconds: Int, audioEnabled: Bool, quality: PromptVideoQuality = .p540)
    case photo
    case lipSync(inputMode: LipSyncInputMode, characterCount: Int, audioDurationSeconds: Double?)
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
        case .video(let durationSeconds, let audioEnabled, let quality):
            let seconds = max(0, durationSeconds)
            let perSecond = max(0, logic.promptVideoTokensPerSecond ?? Self.fallbackPromptVideoTokensPerSecond)
            // Аудио: доплата за каждую секунду ролика (не единоразовая сумма за toggle).
            let audioTokensPerSecond = max(0, logic.promptVideoAudioAddonTokens ?? Self.fallbackPromptVideoAudioAddonTokens)
            let audioAddon = audioEnabled ? seconds * audioTokensPerSecond : 0
            let base = seconds * perSecond + audioAddon
            return Int(ceil(Double(base) * quality.tokenPriceMultiplier))

        case .photo:
            return max(0, logic.promptPhotoGenerationTokens ?? Self.fallbackPromptPhotoGenerationTokens)

        case .lipSync(let inputMode, let characterCount, let audioDurationSeconds):
            return lipSyncCost(
                inputMode: inputMode,
                characterCount: characterCount,
                audioDurationSeconds: audioDurationSeconds
            )
        }
    }

    /// База lip sync = prompt-видео 540p × 5 с без доплаты за аудио.
    var lipSyncBaseCost: Int {
        promptGenerationCost(
            kind: .video(
                durationSeconds: LipSyncLimits.pricingBaseVideoSeconds,
                audioEnabled: false,
                quality: .p540
            )
        )
    }

    /// Цена lip sync: блоки по 50 символов (TTS) или по 5 с (upload); каждый следующий блок +50% базы.
    func lipSyncCost(inputMode: LipSyncInputMode, characterCount: Int, audioDurationSeconds: Double?) -> Int {
        let base = lipSyncBaseCost
        let blocks: Int
        switch inputMode {
        case .lines:
            let chars = max(1, min(characterCount, LipSyncLimits.maxTextCharacters))
            blocks = max(1, Int(ceil(Double(chars) / Double(LipSyncLimits.textBlockCharacters))))
        case .uploadAudio:
            let seconds = min(max(0, audioDurationSeconds ?? 0), LipSyncLimits.maxAudioSeconds)
            blocks = max(1, Int(ceil(seconds / Double(LipSyncLimits.audioBlockSeconds))))
        }
        return Self.tieredBlockCost(base: base, blocks: blocks)
    }

    /// `cost = base × (1 + 0.5 × (blocks - 1))`.
    private static func tieredBlockCost(base: Int, blocks: Int) -> Int {
        guard blocks > 0 else { return base }
        return Int(ceil(Double(base) * (1.0 + 0.5 * Double(blocks - 1))))
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
