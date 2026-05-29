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

enum PromptVideoTwoImageMode: String, Codable, CaseIterable {
    case transition
    case fusion
    case frames
}

/// Пресеты стиля перехода между двумя сценами (подставляются в промпт по тапу на чип).
enum PromptVideoTransitionStyle: String, Codable, CaseIterable {
    case matchOnAction
    case whipPan
    case matchCut
    case zoomBlur
    case dissolve
    case smoothCrossfade
    /// Последний в цикле: очищает промпт для своего описания.
    case custom
}

enum GenerationJobRequest {
    /// `aspectRatio` — только для text→video; при референсах оставляем `nil`, формат кадра задаёт вход.
    /// Для двух локальных фото используем отдельные API-режимы (`transition`/`fusion`/`frames`) после upload.
    case promptVideo(prompt: String, duration: Int, audioEnabled: Bool, aspectRatio: String?, inputImagePath: String?, secondInputImagePath: String?, twoImageMode: PromptVideoTwoImageMode?)
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
    /// Тело POST к провайдеру при создании задачи — для `generation_logs.request_metadata` при upsert и resume.
    var providerRequestLog: PixVerseAPIRequestRecord?
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
    /// Контекст текущего job для `generation_logs.response_metadata` при ошибках (upload/create/poll).
    private var activeFailureDiagnostics = GenerationFailureDiagnostics()
    /// v5: у `promptPhoto` `aspectRatio` опционален (i2i без явного aspect — провайдер по умолчанию `auto`).
    /// v6: `LibraryGenerationJob.id` — монотонный `Int` (не UUID).
    /// v8: режим двух фото в `promptVideo`; v9: `providerRequestLog` для полного JSON в `request_metadata`.
    private let persistedJobsKey = "aivideo_generation_recent_jobs_v9"
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
        activeFailureDiagnostics = GenerationFailureDiagnostics()
        defer { activeFailureDiagnostics = GenerationFailureDiagnostics() }

        // Один активный job — хук на POST create пишет request JSON до разбора ответа.
        // Статус оставляем `running`, чтобы не зависеть от возможного enum в RPC; стадию кладём в metadata.
        api.onCreateRequestWillSend = { [weak self] record in
            guard let self else { return }
            self.updateJobRequestLog(jobId, requestLog: record)
            var requestMetadata = record.supabaseRequestMetadata()
            requestMetadata["submission_stage"] = "create_request_sent"
            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "running",
                providerJobId: nil,
                requestMetadata: requestMetadata,
                resultURL: nil,
                errorMessage: nil,
                startedAt: Date(),
                completedAt: nil
            )
        }
        defer { api.onCreateRequestWillSend = nil }

        do {
            activeFailureDiagnostics.setPhase("create_job")
            let outcome = try await createJob(for: request)
            activeProviderJobId = outcome.job.id
            activeFailureDiagnostics.setPhase("processing")
            phase = .processing
            updateJobProvider(jobId, providerJob: outcome.job, requestLog: outcome.requestRecord)
            updateJob(jobId, state: .processing)
            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "running",
                providerJobId: outcome.job.id,
                requestMetadata: outcome.requestRecord.supabaseRequestMetadata(),
                resultURL: nil,
                errorMessage: nil,
                startedAt: Date(),
                completedAt: nil
            )
            activeFailureDiagnostics.setPhase("polling")
            let result = try await api.pollUntilCompleted(job: outcome.job)
            activeFailureDiagnostics.setPhase("saving")
            phase = .saving
            let media = try await downloadAndSave(result: result, prompt: request.promptForLibrary)

            await Self.pushGenerationLog(
                clientJobId: jobId,
                request: request,
                cost: cost,
                status: "succeeded",
                providerJobId: outcome.job.id,
                requestMetadata: outcome.requestRecord.supabaseRequestMetadata(),
                resultURL: result.url.absoluteString,
                errorMessage: nil,
                startedAt: nil,
                completedAt: Date()
            )

            AppState.shared.addGeneratedMedia(media)
            removeJob(jobId)
            finishSuccess(media: media)
        } catch let createError as PixVerseCreateJobError {
            billing.refund(cost: cost)
            await Self.logGenerationFailure(
                clientJobId: jobId,
                request: request,
                cost: cost,
                providerJobId: activeProviderJobId,
                requestMetadata: createError.requestRecord.supabaseRequestMetadata(),
                error: createError.underlying,
                diagnostics: activeFailureDiagnostics
            )
            removeJob(jobId)
            finishFailure(createError.underlying)
        } catch {
            billing.refund(cost: cost)
            let failedRequestMetadata = recentJobs.first(where: { $0.id == jobId })?.providerRequestLog?.supabaseRequestMetadata()
            await Self.logGenerationFailure(
                clientJobId: jobId,
                request: request,
                cost: cost,
                providerJobId: activeProviderJobId,
                requestMetadata: failedRequestMetadata,
                error: error,
                diagnostics: activeFailureDiagnostics
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
        let requestMetadata = job.providerRequestLog?.supabaseRequestMetadata()
        do {
            phase = .processing
            updateJob(job.id, state: .processing)
            await Self.pushGenerationLog(
                clientJobId: job.id,
                request: job.request,
                cost: job.cost,
                status: "running",
                providerJobId: providerJob.id,
                requestMetadata: requestMetadata,
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
                requestMetadata: requestMetadata,
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
            var diagnostics = GenerationFailureDiagnostics()
            diagnostics.setPhase("resume_polling")
            await Self.logGenerationFailure(
                clientJobId: job.id,
                request: job.request,
                cost: job.cost,
                providerJobId: providerJob.id,
                requestMetadata: requestMetadata,
                error: error,
                diagnostics: diagnostics
            )
            removeJob(job.id)
            finishFailure(error)
        }
    }

    private func createJob(for request: GenerationJobRequest) async throws -> PixVerseCreateJobOutcome {
        let replyRef = UUID().uuidString

        switch request {
        case .promptVideo(let prompt, let duration, let audioEnabled, let aspectRatio, let inputImagePath, let secondInputImagePath, let twoImageMode):
            phase = .queued
            activeFailureDiagnostics.setPhase("uploading")
            let uploadedFirst = try await uploadInputImageIfNeeded(inputImagePath, label: "video_image_1")
            let uploadedSecond = try await uploadInputImageIfNeeded(secondInputImagePath, label: "video_image_2")
            // Когда пользователь добавляет 2 фото в режиме видео, роутим запрос на отдельные endpoint'ы:
            // transition (дефолт), fusion или frames — чтобы не отправлять `last_frame_path` в `videos/create`.
            if let first = uploadedFirst, let second = uploadedSecond {
                switch twoImageMode ?? .transition {
                case .transition:
                    return try await api.createVideoTransition(PixVerseCreateTransitionVideoRequest(
                        frame1Path: first,
                        frame2Path: second,
                        transitionPrompt: prompt,
                        duration: duration,
                        audio: audioEnabled,
                        replyRef: replyRef
                    ))
                case .fusion:
                    return try await api.createVideoFusion(PixVerseCreateFusionVideoRequest(
                        prompt: prompt,
                        frame1Path: first,
                        frame2Path: second,
                        duration: duration,
                        audio: audioEnabled,
                        aspectRatio: aspectRatio ?? "9:16",
                        replyRef: replyRef
                    ))
                case .frames:
                    return try await api.createVideoFrames(PixVerseCreateFramesVideoRequest(
                        firstFramePath: first,
                        lastFramePath: second,
                        duration: duration,
                        audio: audioEnabled,
                        replyRef: replyRef
                    ))
                }
            }

            return try await api.createVideo(PixVerseCreateVideoRequest(
                prompt: prompt,
                firstFramePath: uploadedFirst,
                lastFramePath: nil,
                templateId: nil,
                duration: duration,
                audio: audioEnabled,
                aspectRatio: aspectRatio,
                quality: nil,
                replyRef: replyRef
            ))

        case .promptPhoto(let prompt, let aspectRatio, let inputImagePath, let secondInputImagePath):
            phase = .queued
            activeFailureDiagnostics.setPhase("uploading")
            let uploadedFirst = try await uploadInputImageIfNeeded(inputImagePath, label: "photo_image_1")
            let uploadedSecond = try await uploadInputImageIfNeeded(secondInputImagePath, label: "photo_image_2")
            return try await api.createImage(PixVerseCreateImageRequest(
                prompt: prompt,
                imagePath: uploadedFirst,
                secondImagePath: uploadedSecond,
                aspectRatio: aspectRatio,
                replyRef: replyRef
            ))

        case .effect(let preset, let inputImagePath):
            phase = .uploading
            activeFailureDiagnostics.setPhase("uploading")
            let upload = try await uploadRequiredInputImage(inputImagePath, label: "effect_reference")
            phase = .queued
            return try await api.createVideo(PixVerseCreateVideoRequest(
                prompt: preset.promptTemplate ?? preset.description ?? preset.title,
                firstFramePath: upload.path,
                lastFramePath: nil,
                templateId: preset.providerTemplateId,
                duration: preset.durationSeconds ?? 5,
                audio: nil,
                aspectRatio: preset.aspectRatio,
                quality: preset.resolvedVideoQualityForGeneration(),
                replyRef: replyRef
            ))
        }
    }

    private func uploadInputImageIfNeeded(_ path: String?, label: String) async throws -> String? {
        guard let path else { return nil }
        return try await uploadRequiredInputImage(path, label: label).path
    }

    private func uploadRequiredInputImage(_ path: String, label: String) async throws -> PixVerseUploadResult {
        guard FileManager.default.fileExists(atPath: path) else { throw NetworkError.invalidData }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        // Любой вход (HEIC, крупный JPEG/PNG с диска) — один пайплайн: декод → ужимание под лимит upload → JPEG/PNG под API.
        guard let decoded = UIImage.decodedForAPIUpload(from: raw) else { throw NetworkError.invalidData }
        let afterPipeline = decoded.normalizedUprightPixelBuffer().downscaled(maxLongSide: 1080)
        guard let payload = decoded.pixelDataForPixVerseUpload(jpegQuality: 0.9) else {
            throw NetworkError.invalidData
        }
        let data = payload.data
        let contentType = payload.contentType
        phase = .uploading
        let result: PixVerseUploadResult
        do {
            result = try await api.uploadImage(data, contentType: contentType)
        } catch {
            activeFailureDiagnostics.recordUpload(
                ImageUploadTrace.capture(
                    label: label,
                    localPath: path,
                    raw: raw,
                    decoded: decoded,
                    afterPipeline: afterPipeline,
                    uploadContentType: contentType,
                    uploadData: data,
                    uploadResult: nil
                )
            )
            throw error
        }
        activeFailureDiagnostics.recordUpload(
            ImageUploadTrace.capture(
                label: label,
                localPath: path,
                raw: raw,
                decoded: decoded,
                afterPipeline: afterPipeline,
                uploadContentType: contentType,
                uploadData: data,
                uploadResult: result
            )
        )
        return result
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

    private func updateJobRequestLog(_ id: Int, requestLog: PixVerseAPIRequestRecord) {
        guard let index = recentJobs.firstIndex(where: { $0.id == id }) else { return }
        recentJobs[index].providerRequestLog = requestLog
        persistJobs()
    }

    private func updateJobProvider(_ id: Int, providerJob: PixVerseCreatedJob, requestLog: PixVerseAPIRequestRecord?) {
        guard let index = recentJobs.firstIndex(where: { $0.id == id }) else { return }
        recentJobs[index].providerJob = providerJob
        if let requestLog {
            recentJobs[index].providerRequestLog = requestLog
        }
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

    private static func logGenerationFailure(
        clientJobId: Int,
        request: GenerationJobRequest,
        cost: Int,
        providerJobId: String?,
        requestMetadata: [String: Any]?,
        error: Error,
        diagnostics: GenerationFailureDiagnostics
    ) async {
        await pushGenerationLog(
            clientJobId: clientJobId,
            request: request,
            cost: cost,
            status: "failed",
            providerJobId: providerJobId,
            requestMetadata: requestMetadata,
            responseMetadata: diagnostics.responseMetadata(
                error: error,
                clientJobId: clientJobId,
                request: request,
                providerJobId: providerJobId,
                requestMetadata: requestMetadata
            ),
            resultURL: nil,
            errorMessage: diagnostics.errorMessageSummary(for: error),
            startedAt: nil,
            completedAt: Date()
        )
    }

    /// Сторона Supabase не должна ломать пайплайн генерации: ошибки только в лог.
    private static func pushGenerationLog(
        clientJobId: Int,
        request: GenerationJobRequest,
        cost: Int,
        status: String,
        providerJobId: String?,
        requestMetadata: [String: Any]?,
        responseMetadata: [String: Any]? = nil,
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
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
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
        case .promptVideo(_, let duration, let audioEnabled, let aspectRatio, _, _, _):
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
        case .promptVideo(let prompt, _, _, _, _, _, _), .promptPhoto(let prompt, _, _, _):
            return prompt
        case .effect(let preset, _):
            return preset.promptTemplate ?? preset.description ?? preset.title
        }
    }
}

