import Combine
import Foundation
import UIKit

enum GenerationJobPhase: Equatable {
    case idle
    case uploading
    case queued
    case processing
    case saving
}

enum GenerationJobRequest {
    /// `aspectRatio` — только для text→video; при референсах оставляем `nil`, формат кадра задаёт вход. Два локальных файла → `first_frame_path` + `last_frame_path` после upload.
    case promptVideo(prompt: String, duration: Int, audioEnabled: Bool, aspectRatio: String?, inputImagePath: String?, secondInputImagePath: String?)
    /// `aspectRatio` — только text→image; при референсах (`image_path_1`…`2`) не передаём в API — дефолт `auto` по документации useapi.
    case promptPhoto(prompt: String, aspectRatio: String?, inputImagePath: String?, secondInputImagePath: String?)
    case effect(preset: EffectPreset, inputImagePath: String)
}

extension GenerationJobRequest: Codable {}

enum LibraryGenerationJobState: Codable, Equatable {
    case queued
    case processing
    case failed(message: String)

    var localizedTitle: String {
        switch self {
        case .queued:
            return "library_job_queued_title".localized
        case .processing:
            return "library_job_processing_title".localized
        case .failed:
            return "library_job_failed_title".localized
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .queued:
            return "library_job_queued_subtitle".localized
        case .processing:
            return "library_job_processing_subtitle".localized
        case .failed(let message):
            return message
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct LibraryGenerationJob: Codable, Identifiable {
    let id: Int
    let title: String
    let cost: Int
    let request: GenerationJobRequest
    var state: LibraryGenerationJobState
    let createdAt: Date
    var providerJob: PixVerseCreatedJob?
}

@MainActor
final class GenerationJobService: ObservableObject {
    static let shared = GenerationJobService()

    @Published private(set) var phase: GenerationJobPhase = .idle
    @Published private(set) var isRunning = false
    @Published var isOverlayVisible = false
    @Published private(set) var recentJobs: [LibraryGenerationJob] = []

    /// Пользователь нажал «в фоне» на оверлее: после успеха показываем notification, а не полноэкранный detail.
    private var skipDirectDetailAfterSuccess = false

    private let api = PixVerseAPIService.shared
    private let billing = GenerationBillingService.shared
    private var activeTask: Task<Void, Never>?
    /// v5: у `promptPhoto` `aspectRatio` опционален (i2i без явного aspect — провайдер по умолчанию `auto`).
    /// v6: `LibraryGenerationJob.id` — монотонный `Int` (не UUID).
    /// v7: второй референс в `promptVideo` / `promptPhoto` + новый ключ `persistedJobsKey` (сброс старых закодированных джобов в UserDefaults).
    private let persistedJobsKey = "aivideo_generation_recent_jobs_v7"
    private static let nextJobIdKey = "aivideo_library_generation_job_next_id"
    private static let jobIdLock = NSLock()

    private init() {
        recentJobs = loadPersistedJobs()
        resumePersistedProviderJobs()
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return "generation_overlay_title".localized
        case .uploading:
            return "generation_overlay_uploading".localized
        case .queued:
            return "generation_overlay_queued".localized
        case .processing:
            return "generation_overlay_processing".localized
        case .saving:
            return "generation_overlay_saving".localized
        }
    }

    func start(request: GenerationJobRequest, cost: Int) {
        guard !isRunning else {
            NotificationManager.shared.showInfo("generation_already_running".localized)
            return
        }

        guard billing.reserveOrPresentPaywall(cost: cost) else {
            return
        }

        let jobId = Self.allocateNextJobId()
        let libraryJob = LibraryGenerationJob(
            id: jobId,
            title: request.libraryTitle,
            cost: cost,
            request: request,
            state: .queued,
            createdAt: Date(),
            providerJob: nil
        )

        recentJobs.insert(libraryJob, at: 0)
        persistJobs()
        skipDirectDetailAfterSuccess = false
        isRunning = true
        isOverlayVisible = true
        phase = .queued

        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.run(jobId: jobId, request: request, cost: cost)
        }
    }

    func retry(job: LibraryGenerationJob) {
        removeJob(job.id)
        start(request: job.request, cost: job.cost)
    }

    func persistInputImage(_ image: UIImage) throws -> String {
        guard let payload = image.pixelDataForPixVerseUpload(jpegQuality: 0.9) else {
            throw NetworkError.invalidData
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIVideoJobInputs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let ext = payload.contentType == "image/png" ? "png" : "jpg"
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try payload.data.write(to: url)
        return url.path
    }

    func continueInBackground() {
        skipDirectDetailAfterSuccess = true
        isOverlayVisible = false
        // Тот же интервал, что и у остальных `.info` (см. `NotificationType.displayDuration`) — отдельные 4 с казались слишком долгими.
        NotificationManager.shared.showInfo("generation_background_toast".localized)
    }

    /// Локальный счётчик id джобов в табе «генерации»: один клиент, без координации с сервером — `Int` удобнее UUID.
    private static func allocateNextJobId() -> Int {
        jobIdLock.lock()
        defer { jobIdLock.unlock() }
        let n = max(0, UserDefaults.standard.integer(forKey: nextJobIdKey)) + 1
        UserDefaults.standard.set(n, forKey: nextJobIdKey)
        return n
    }

    private func run(jobId: Int, request: GenerationJobRequest, cost: Int) async {
        var activeProviderJobId: String?
        do {
            let createdJob = try await createJob(for: request)
            activeProviderJobId = createdJob.id
            phase = .processing
            updateJobProvider(jobId, providerJob: createdJob)
            updateJob(jobId, state: .processing)
            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "running",
                providerJobId: createdJob.id,
                resultURL: nil,
                errorMessage: nil,
                startedAt: Date(),
                completedAt: nil
            )
            let result = try await api.pollUntilCompleted(job: createdJob)
            phase = .saving
            let media = try await downloadAndSave(result: result, prompt: request.promptForLibrary)

            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "succeeded",
                providerJobId: createdJob.id,
                resultURL: result.url.absoluteString,
                errorMessage: nil,
                startedAt: nil,
                completedAt: Date()
            )

            AppState.shared.addGeneratedMedia(media)
            removeJob(jobId)
            finishSuccess(media: media)
        } catch {
            billing.refund(cost: cost)
            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "failed",
                providerJobId: activeProviderJobId,
                resultURL: nil,
                errorMessage: error.localizedDescription,
                startedAt: nil,
                completedAt: Date()
            )
            // Галерея показывает только готовые медиа и активные джобы; карточки с ошибкой провайдера не храним — текст уже в баннере.
            removeJob(jobId)
            finishFailure(error)
        }
    }

    private func resumePersistedProviderJobs() {
        let resumableJobs = recentJobs.filter { !$0.state.isFailed && $0.providerJob != nil }
        guard !resumableJobs.isEmpty else { return }

        isRunning = true
        for job in resumableJobs {
            guard let providerJob = job.providerJob else { continue }
            Task { [weak self] in
                guard let self else { return }
                await self.resumePolling(job: job, providerJob: providerJob)
            }
        }
    }

    private func resumePolling(job: LibraryGenerationJob, providerJob: PixVerseCreatedJob) async {
        do {
            phase = .processing
            updateJob(job.id, state: .processing)
            await Self.pushGenerationLog(
                clientJobId: job.id,
                request: job.request,
                cost: job.cost,
                status: "running",
                providerJobId: providerJob.id,
                resultURL: nil,
                errorMessage: nil,
                startedAt: Date(),
                completedAt: nil
            )
            let result = try await api.pollUntilCompleted(job: providerJob)
            phase = .saving
            let media = try await downloadAndSave(result: result, prompt: job.request.promptForLibrary)
            await Self.pushGenerationLog(
                clientJobId: job.id,
                request: job.request,
                cost: job.cost,
                status: "succeeded",
                providerJobId: providerJob.id,
                resultURL: result.url.absoluteString,
                errorMessage: nil,
                startedAt: nil,
                completedAt: Date()
            )
            AppState.shared.addGeneratedMedia(media)
            removeJob(job.id)
            finishSuccess(media: media)
        } catch {
            billing.refund(cost: job.cost)
            await Self.pushGenerationLog(
                clientJobId: job.id,
                request: job.request,
                cost: job.cost,
                status: "failed",
                providerJobId: providerJob.id,
                resultURL: nil,
                errorMessage: error.localizedDescription,
                startedAt: nil,
                completedAt: Date()
            )
            removeJob(job.id)
            finishFailure(error)
        }
    }

    private func createJob(for request: GenerationJobRequest) async throws -> PixVerseCreatedJob {
        let replyRef = UUID().uuidString

        switch request {
        case .promptVideo(let prompt, let duration, let audioEnabled, let aspectRatio, let inputImagePath, let secondInputImagePath):
            phase = .queued
            let uploadedFirst = try await uploadInputImageIfNeeded(inputImagePath)
            let uploadedSecond = try await uploadInputImageIfNeeded(secondInputImagePath)
            return try await api.createVideo(PixVerseCreateVideoRequest(
                prompt: prompt,
                firstFramePath: uploadedFirst,
                lastFramePath: uploadedSecond,
                templateId: nil,
                duration: duration,
                audio: audioEnabled,
                aspectRatio: aspectRatio,
                replyRef: replyRef
            ))

        case .promptPhoto(let prompt, let aspectRatio, let inputImagePath, let secondInputImagePath):
            phase = .queued
            let uploadedFirst = try await uploadInputImageIfNeeded(inputImagePath)
            let uploadedSecond = try await uploadInputImageIfNeeded(secondInputImagePath)
            return try await api.createImage(PixVerseCreateImageRequest(
                prompt: prompt,
                imagePath: uploadedFirst,
                secondImagePath: uploadedSecond,
                aspectRatio: aspectRatio,
                replyRef: replyRef
            ))

        case .effect(let preset, let inputImagePath):
            phase = .uploading
            let upload = try await uploadRequiredInputImage(inputImagePath)
            phase = .queued
            return try await api.createVideo(PixVerseCreateVideoRequest(
                prompt: preset.promptTemplate ?? preset.description ?? preset.title,
                firstFramePath: upload.path,
                lastFramePath: nil,
                templateId: preset.providerTemplateId,
                duration: preset.durationSeconds ?? 5,
                audio: nil,
                aspectRatio: preset.aspectRatio,
                replyRef: replyRef
            ))
        }
    }

    private func uploadInputImageIfNeeded(_ path: String?) async throws -> String? {
        guard let path else { return nil }
        return try await uploadRequiredInputImage(path).path
    }

    private func uploadRequiredInputImage(_ path: String) async throws -> PixVerseUploadResult {
        guard FileManager.default.fileExists(atPath: path) else { throw NetworkError.invalidData }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        // Любой вход (HEIC, крупный JPEG/PNG с диска) — один пайплайн: декод → ужимание под лимит upload → JPEG/PNG под API.
        guard let ui = UIImage.decodedForAPIUpload(from: raw) else { throw NetworkError.invalidData }
        guard let payload = ui.pixelDataForPixVerseUpload(jpegQuality: 0.9) else {
            throw NetworkError.invalidData
        }
        let data = payload.data
        let contentType = payload.contentType
        phase = .uploading
        return try await api.uploadImage(data, contentType: contentType)
    }

    private func downloadAndSave(result: PixVerseCompletedResult, prompt: String?) async throws -> GeneratedMedia {
        let (data, response) = try await URLSession.shared.data(from: result.url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NetworkError.httpError(http.statusCode)
        }
        let mediaType: MediaType = result.kind == .video ? .video : .image
        let resultURL = result.url.absoluteString
        return try await Task.detached(priority: .userInitiated) {
            try GeneratedImageService.shared.saveGeneratedMedia(
                data: data,
                type: mediaType,
                prompt: prompt,
                resultUrl: resultURL
            )
        }.value
    }

    private func finishSuccess(media: GeneratedMedia) {
        // Оверлей ещё виден только если пользователь не нажал «в фоне»; восстановление job после перезапуска идёт без оверлея.
        let openFullscreenDetail = isOverlayVisible && !skipDirectDetailAfterSuccess
        isRunning = false
        isOverlayVisible = false
        skipDirectDetailAfterSuccess = false
        phase = .idle
        activeTask = nil

        if openFullscreenDetail {
            AppState.shared.presentGenerationSuccessDetail(media)
        } else {
            NotificationManager.shared.showSuccess("generation_completed_success".localized)
        }
    }

    private func finishFailure(_ error: Error) {
        skipDirectDetailAfterSuccess = false
        isRunning = false
        isOverlayVisible = false
        phase = .idle
        activeTask = nil
        NotificationManager.shared.showError(
            "generation_failed_refunded".localized(with: error.localizedDescription),
            customDuration: 5,
            sizing: .fitContent
        )
    }

    private func updateJob(_ id: Int, state: LibraryGenerationJobState) {
        guard let index = recentJobs.firstIndex(where: { $0.id == id }) else { return }
        recentJobs[index].state = state
        persistJobs()
    }

    private func updateJobProvider(_ id: Int, providerJob: PixVerseCreatedJob) {
        guard let index = recentJobs.firstIndex(where: { $0.id == id }) else { return }
        recentJobs[index].providerJob = providerJob
        persistJobs()
    }

    private func removeJob(_ id: Int) {
        recentJobs.removeAll { $0.id == id }
        persistJobs()
    }

    private func persistJobs() {
        guard let data = try? JSONEncoder().encode(recentJobs) else { return }
        UserDefaults.standard.set(data, forKey: persistedJobsKey)
    }

    /// Сторона Supabase не должна ломать пайплайн генерации: ошибки только в лог.
    private static func pushGenerationLog(
        clientJobId: Int,
        request: GenerationJobRequest,
        cost: Int,
        status: String,
        providerJobId: String?,
        resultURL: String?,
        errorMessage: String?,
        startedAt: Date?,
        completedAt: Date?
    ) async {
        let meta = request.generationLogRouting
        // Дублируем вызов в консоль с префиксом `[Supabase]`, чтобы отличить «RPC не вызывался» от «вызвался, но отказал PostgREST».
        SupabaseService.logGenerationJournal(
            "pushGenerationLog enqueue client=\(clientJobId) job_status=\(status) gen_type=\(meta.generationType) preset=\(meta.effectPresetId.map(String.init) ?? "nil") provider_job=\(providerJobId ?? "nil") tokens=\(cost)"
        )
        await SupabaseService.shared.upsertVideoGenerationLog(
            clientGenerationId: clientJobId,
            generationType: meta.generationType,
            status: status,
            effectPresetId: meta.effectPresetId,
            providerJobId: providerJobId,
            prompt: request.promptForLibrary,
            aspectRatio: meta.aspectRatio,
            durationSeconds: meta.durationSeconds,
            audioEnabled: meta.audioEnabled,
            tokenCost: cost,
            resultURL: resultURL,
            errorMessage: errorMessage,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func loadPersistedJobs() -> [LibraryGenerationJob] {
        guard let data = UserDefaults.standard.data(forKey: persistedJobsKey) else {
            return []
        }
        guard let jobs = try? JSONDecoder().decode([LibraryGenerationJob].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: persistedJobsKey)
            return []
        }
        // Не восстанавливаем в списке для галереи: завершённые с ошибкой и «оборванные» без provider_job (после kill приложения).
        let cleaned = jobs.filter { job in
            if job.state.isFailed { return false }
            return job.providerJob != nil
        }
        if cleaned.count != jobs.count, let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: persistedJobsKey)
        }
        return cleaned
    }
}

private extension GenerationJobRequest {
    /// Поля для RPC `upsert_generation_log` (тип пресета, длительность, аудио).
    var generationLogRouting: (generationType: String, effectPresetId: Int?, aspectRatio: String?, durationSeconds: Int?, audioEnabled: Bool?) {
        switch self {
        case .promptVideo(_, let duration, let audioEnabled, let aspectRatio, _, _):
            return ("prompt_video", nil, aspectRatio, duration, audioEnabled)
        case .promptPhoto(_, let aspectRatio, _, _):
            return ("prompt_photo", nil, aspectRatio, nil, nil)
        case .effect(let preset, _):
            return ("effect_video", preset.id, preset.aspectRatio, preset.durationSeconds, nil)
        }
    }

    var libraryTitle: String {
        switch self {
        case .promptVideo:
            return "library_job_prompt_video".localized
        case .promptPhoto:
            return "library_job_prompt_photo".localized
        case .effect(let preset, _):
            return preset.title
        }
    }

    var promptForLibrary: String? {
        switch self {
        case .promptVideo(let prompt, _, _, _, _, _), .promptPhoto(let prompt, _, _, _):
            return prompt
        case .effect(let preset, _):
            return preset.promptTemplate ?? preset.description ?? preset.title
        }
    }
}

