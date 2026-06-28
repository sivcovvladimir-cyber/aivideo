import Foundation

/// Черновик экрана «Генерация»: держим в `AppState` между переходами на другие табы, пока живёт процесс приложения.
struct GenerationPromptScreenDraft: Equatable, Codable {
    var modeRaw: String
    var videoTwoImageModeRaw: String?
    /// Выбранный пресет перехода (чип «Выбрать тип»); `nil` — пользователь ещё не тапал.
    var videoTransitionStyleRaw: String?
    var prompt: String
    var durationSeconds: Double
    var audioEnabled: Bool
    /// `540p` / `720p` для prompt-видео.
    var videoQualityRaw: String
    var photoAspectRaw: String
    var videoAspectRaw: String
    var referenceImageJPEGData: Data?
    /// Второй референс с экрана генерации (макс. 2 фото → фото-режим шлёт `image_path_2`, видео-режим — один из `transition` / `fusion` / `frames`).
    var referenceImage2JPEGData: Data?

    // Lip sync
    var lipSyncInputModeRaw: String?
    var lipSyncVideoLocalPath: String?
    var lipSyncVideoProviderJobId: String?
    var lipSyncSelectedSpeakerId: String?
    var lipSyncOriginalAudioEnabled: Bool?
    var lipSyncAudioLocalPath: String?
    var lipSyncAudioDisplayName: String?
    var lipSyncAudioDurationSeconds: Double?

    static let initial = GenerationPromptScreenDraft(
        modeRaw: "video",
        videoTwoImageModeRaw: "transition",
        videoTransitionStyleRaw: nil,
        prompt: "",
        durationSeconds: 5,
        audioEnabled: false,
        videoQualityRaw: PromptVideoQuality.defaultForPromptVideo.rawValue,
        photoAspectRaw: "9:16",
        videoAspectRaw: "9:16",
        referenceImageJPEGData: nil,
        referenceImage2JPEGData: nil,
        lipSyncInputModeRaw: LipSyncInputMode.lines.rawValue,
        lipSyncVideoLocalPath: nil,
        lipSyncVideoProviderJobId: nil,
        lipSyncSelectedSpeakerId: nil,
        lipSyncOriginalAudioEnabled: false,
        lipSyncAudioLocalPath: nil,
        lipSyncAudioDisplayName: nil,
        lipSyncAudioDurationSeconds: nil
    )
}
