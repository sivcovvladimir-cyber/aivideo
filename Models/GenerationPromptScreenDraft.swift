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
    var photoAspectRaw: String
    var videoAspectRaw: String
    var referenceImageJPEGData: Data?
    /// Второй референс с экрана генерации (макс. 2 фото → фото-режим шлёт `image_path_2`, видео-режим — один из `transition` / `fusion` / `frames`).
    var referenceImage2JPEGData: Data?

    static let initial = GenerationPromptScreenDraft(
        modeRaw: "video",
        videoTwoImageModeRaw: "transition",
        videoTransitionStyleRaw: nil,
        prompt: "",
        durationSeconds: 5,
        audioEnabled: false,
        photoAspectRaw: "9:16",
        videoAspectRaw: "9:16",
        referenceImageJPEGData: nil,
        referenceImage2JPEGData: nil
    )
}
