import Foundation

/// Общий кэш голосов lip sync на сессию приложения.
///
/// Раньше список голосов и флаги загрузки жили в `@State` внутри `LipSyncGenerationSection`, а эта секция
/// пересоздаётся при каждом переключении вкладок Video/Photo/Lip sync и при повторном входе на экран.
/// Быстрое переключение туда-обратно оставляло предыдущий `Task` fetch orphan'ом: он дописывал результат
/// в уже не отображаемое состояние, а свежесозданная секция стартовала свою собственную загрузку — если
/// именно в этот момент открывалась панель выбора голоса, UI мог показывать бесконечный лоадер, пока
/// пользователь не выходил и не заходил снова. Единый `@MainActor`-синглтон убирает саму возможность гонки:
/// состояние загрузки живёт вне жизненного цикла View и переживает переключение вкладок.
@MainActor
final class LipSyncVoiceStore: ObservableObject {
    static let shared = LipSyncVoiceStore()

    @Published private(set) var voices: [PixVerseVoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var didLoadOnce = false

    private init() {}

    /// Голоса без служебной записи «Auto» — она отрисовывается отдельной строкой в UI.
    var presetVoices: [PixVerseVoice] {
        voices.filter { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "auto" }
    }

    /// useapi не поддерживает настоящий auto-выбор голоса для TTS: если в `videos/lipsync` передать `prompt`
    /// без `speaker_id`, запрос падает ошибкой. Поэтому «Auto» в UI на деле означает «взять первый голос
    /// из каталога» — так пользователю не нужно вручную выбирать голос, а API получает валидный `speaker_id`.
    var defaultSpeakerId: String? {
        presetVoices.first?.speakerId
    }

    func loadIfNeeded(force: Bool = false) {
        if isLoading { return }
        if didLoadOnce && !force { return }
        isLoading = true
        loadFailed = false
        Task {
            do {
                let fetched = try await PixVerseAPIService.shared.fetchLipSyncVoices()
                voices = fetched
                isLoading = false
                didLoadOnce = true
            } catch {
                loadFailed = true
                isLoading = false
                didLoadOnce = true
            }
        }
    }

    func reload() {
        voices = []
        loadFailed = false
        didLoadOnce = false
        isLoading = false
        loadIfNeeded(force: true)
    }
}
