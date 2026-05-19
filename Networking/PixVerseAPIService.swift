import Foundation

enum PixVerseGenerationKind: Codable {
    case video
    case image
}

struct PixVerseCreateVideoRequest {
    let prompt: String
    let firstFramePath: String?
    /// Второй кадр i2v: `last_frame_path` в POST videos/create (два референса с экрана генерации).
    let lastFramePath: String?
    let templateId: Int?
    let duration: Int
    let audio: Bool?
    let aspectRatio: String?
    let replyRef: String
}

struct PixVerseCreateTransitionVideoRequest {
    let frame1Path: String
    let frame2Path: String
    let transitionPrompt: String
    let duration: Int
    let audio: Bool?
    let replyRef: String
}

struct PixVerseCreateFusionVideoRequest {
    let prompt: String
    let frame1Path: String
    let frame2Path: String
    let duration: Int
    let audio: Bool?
    let aspectRatio: String
    let replyRef: String
}

struct PixVerseCreateFramesVideoRequest {
    let firstFramePath: String
    let lastFramePath: String
    let duration: Int
    let audio: Bool?
    let replyRef: String
}

struct PixVerseCreateImageRequest {
    let prompt: String
    let imagePath: String?
    /// Второй референс i2i: `image_path_2` только вместе с `image_path_1` (см. POST images/create).
    let secondImagePath: String?
    /// Опционально: для i2i с `image_path_*` useapi берёт дефолт `auto` (см. POST images/create).
    let aspectRatio: String?
    let replyRef: String
}

struct PixVerseCreatedJob: Codable {
    let id: String
    let kind: PixVerseGenerationKind
}

struct PixVerseCompletedResult {
    let id: String
    let kind: PixVerseGenerationKind
    let url: URL
}

struct PixVerseUploadResult {
    let path: String
    let url: URL?
}

/// Снимок тела POST к PixVerse/useapi для `generation_logs.request_metadata`.
struct PixVerseAPIRequestRecord: Codable, Equatable {
    let endpoint: String
    let httpMethod: String
    let bodyJSON: String

    init?(endpoint: String, httpMethod: String = "POST", body: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        self.endpoint = endpoint
        self.httpMethod = httpMethod
        self.bodyJSON = json
    }

    /// Полный контекст запроса: платформа + endpoint + JSON, который ушёл в API.
    func supabaseRequestMetadata() -> [String: Any] {
        var metadata: [String: Any] = [
            "platform": "ios",
            "endpoint": endpoint,
            "http_method": httpMethod
        ]
        if let data = bodyJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            metadata["body"] = parsed
        }
        return metadata
    }
}

struct PixVerseCreateJobOutcome {
    let job: PixVerseCreatedJob
    let requestRecord: PixVerseAPIRequestRecord
}

/// POST create уже собран и (обычно) отправлен — сохраняем `request_metadata` даже при 4xx/5xx и пустом `video_id`.
enum PixVerseCreateJobError: Error {
    case requestFailed(record: PixVerseAPIRequestRecord, underlying: Error)

    var requestRecord: PixVerseAPIRequestRecord {
        switch self {
        case .requestFailed(let record, _): return record
        }
    }

    var underlying: Error {
        switch self {
        case .requestFailed(_, let error): return error
        }
    }
}

final class PixVerseAPIService {
    static let shared = PixVerseAPIService()

    /// Сразу перед POST create (тело готово) — чтобы журнал успел сохранить request JSON ещё до ответа провайдера.
    var onCreateRequestWillSend: (@MainActor (PixVerseAPIRequestRecord) async -> Void)?

    private let baseURL = URL(string: "https://api.useapi.net/v2/pixverse")!
    private let defaultVideoModel = "pixverse-c1"
    private let defaultVideoQuality = "720p"
    private let defaultImageModel = "nano-banana-2"
    private let defaultImageQuality = "1080p"
    private let maxJobs = 3

    private var apiToken: String {
        ConfigurationManager.shared.getValue(for: .useAPIToken) ?? ""
    }

    private var accountEmail: String? {
        let value = ConfigurationManager.shared.getValue(for: .pixVerseAccountEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private init() {}

    func uploadImage(_ data: Data, contentType: String = "image/jpeg") async throws -> PixVerseUploadResult {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        var components = URLComponents(url: baseURL.appendingPathComponent("files/"), resolvingAgainstBaseURL: false)
        if let accountEmail {
            components?.queryItems = [URLQueryItem(name: "email", value: accountEmail)]
        }
        guard let url = components?.url else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let response = try await performWithRetry(request, decode: PixVerseUploadResponse.self)
        if let first = response.result?.first, let path = first.path, !path.isEmpty {
            return PixVerseUploadResult(path: path, url: first.url.flatMap(URL.init(string:)))
        }
        if let path = response.path, !path.isEmpty {
            return PixVerseUploadResult(path: path, url: response.url.flatMap(URL.init(string:)))
        }
        throw NetworkError.uploadFailed
    }

    func createVideo(_ payload: PixVerseCreateVideoRequest) async throws -> PixVerseCreateJobOutcome {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let endpointPath = "videos/create"
        var body: [String: Any] = [
            "prompt": payload.prompt,
            "duration": payload.duration,
            "quality": defaultVideoQuality,
            "replyRef": payload.replyRef,
            "maxJobs": maxJobs,
            "off_peak_mode": false
        ]

        if let accountEmail {
            body["email"] = accountEmail
        }

        if let templateId = payload.templateId {
            body["template_id"] = templateId
        } else {
            body["model"] = defaultVideoModel
        }

        if let firstFramePath = payload.firstFramePath {
            body["first_frame_path"] = firstFramePath
        }
        if let lastFramePath = payload.lastFramePath {
            body["last_frame_path"] = lastFramePath
        }
        // Выходной формат кадра: нужен и без референса (text→video), и вместе с `first_frame_path` / шаблоном.
        if let aspectRatio = payload.aspectRatio, !aspectRatio.isEmpty {
            body["aspect_ratio"] = aspectRatio
        }

        if let audio = payload.audio {
            body["audio"] = audio
        }

        return try await submitCreateJob(endpointPath: endpointPath, body: body) { response in
            guard let videoId = response.videoId, !videoId.isEmpty else {
                throw NetworkError.invalidResponse
            }
            return PixVerseCreatedJob(id: videoId, kind: .video)
        }
    }

    func createImage(_ payload: PixVerseCreateImageRequest) async throws -> PixVerseCreateJobOutcome {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let endpointPath = "images/create"
        var body: [String: Any] = [
            "prompt": payload.prompt,
            "model": defaultImageModel,
            "quality": defaultImageQuality,
            "create_count": 1,
            "replyRef": payload.replyRef,
            "maxJobs": maxJobs
        ]
        if let aspectRatio = payload.aspectRatio, !aspectRatio.isEmpty {
            body["aspect_ratio"] = aspectRatio
        }

        if let accountEmail {
            body["email"] = accountEmail
        }
        if let imagePath = payload.imagePath {
            body["image_path_1"] = imagePath
        }
        if let second = payload.secondImagePath {
            body["image_path_2"] = second
        }

        return try await submitCreateJob(endpointPath: endpointPath, body: body) { response in
            let imageId = response.successIds?.first ?? response.imageId
            guard let imageId, !imageId.isEmpty else {
                throw NetworkError.invalidResponse
            }
            return PixVerseCreatedJob(id: imageId, kind: .image)
        }
    }

    func createVideoTransition(_ payload: PixVerseCreateTransitionVideoRequest) async throws -> PixVerseCreateJobOutcome {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let endpointPath = "videos/create-transition"
        var body: [String: Any] = [
            "frame_1_path": payload.frame1Path,
            "frame_2_path": payload.frame2Path,
            "duration_1_to_2": max(1, min(8, payload.duration)),
            "quality": defaultVideoQuality,
            "replyRef": payload.replyRef,
            "maxJobs": maxJobs,
            "off_peak_mode": false
        ]

        if let accountEmail {
            body["email"] = accountEmail
        }
        let prompt = payload.transitionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            body["prompt_1_to_2"] = prompt
        }
        if let audio = payload.audio {
            body["audio"] = audio
        }

        return try await submitCreateJob(endpointPath: endpointPath, body: body) { response in
            guard let videoId = response.videoId, !videoId.isEmpty else {
                throw NetworkError.invalidResponse
            }
            return PixVerseCreatedJob(id: videoId, kind: .video)
        }
    }

    func createVideoFusion(_ payload: PixVerseCreateFusionVideoRequest) async throws -> PixVerseCreateJobOutcome {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let endpointPath = "videos/create-fusion"
        var body: [String: Any] = [
            "model": defaultVideoModel,
            "prompt": payload.prompt,
            "frame_1_path": payload.frame1Path,
            "frame_2_path": payload.frame2Path,
            "duration": payload.duration,
            "quality": defaultVideoQuality,
            "aspect_ratio": payload.aspectRatio,
            "replyRef": payload.replyRef,
            "maxJobs": maxJobs,
            "off_peak_mode": false
        ]

        if let accountEmail {
            body["email"] = accountEmail
        }
        if let audio = payload.audio {
            body["audio"] = audio
        }

        return try await submitCreateJob(endpointPath: endpointPath, body: body) { response in
            guard let videoId = response.videoId, !videoId.isEmpty else {
                throw NetworkError.invalidResponse
            }
            return PixVerseCreatedJob(id: videoId, kind: .video)
        }
    }

    func createVideoFrames(_ payload: PixVerseCreateFramesVideoRequest) async throws -> PixVerseCreateJobOutcome {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let endpointPath = "videos/create-frames"
        var body: [String: Any] = [
            "model": defaultVideoModel,
            "first_frame_path": payload.firstFramePath,
            "last_frame_path": payload.lastFramePath,
            "duration": payload.duration,
            "quality": defaultVideoQuality,
            "replyRef": payload.replyRef,
            "maxJobs": maxJobs,
            "off_peak_mode": false
        ]

        if let accountEmail {
            body["email"] = accountEmail
        }
        if let audio = payload.audio {
            body["audio"] = audio
        }

        return try await submitCreateJob(endpointPath: endpointPath, body: body) { response in
            guard let videoId = response.videoId, !videoId.isEmpty else {
                throw NetworkError.invalidResponse
            }
            return PixVerseCreatedJob(id: videoId, kind: .video)
        }
    }

    func pollUntilCompleted(job: PixVerseCreatedJob, maxAttempts: Int = 120, interval: UInt64 = 5_000_000_000) async throws -> PixVerseCompletedResult {
        for attempt in 1...maxAttempts {
            do {
                if let result = try await fetchStatus(job: job) {
                    return result
                }
            } catch NetworkError.notFound where job.kind == .video {
                // useapi returns 404 for videos that are still processing; keep polling.
            }

            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: interval)
            }
        }

        throw NetworkError.generationTimeoutWithRequestId(job.id)
    }

    private var isConfigured: Bool {
        !apiToken.isEmpty && !apiToken.hasPrefix("YOUR_")
    }

    /// Собирает `request_metadata`, уведомляет журнал, затем POST create; при ошибке ответа не теряем JSON тела.
    private func submitCreateJob(
        endpointPath: String,
        body: [String: Any],
        parseJob: (PixVerseCreateResponse) throws -> PixVerseCreatedJob
    ) async throws -> PixVerseCreateJobOutcome {
        guard let requestRecord = PixVerseAPIRequestRecord(endpoint: endpointPath, body: body) else {
            throw NetworkError.invalidData
        }
        if let onCreateRequestWillSend {
            await onCreateRequestWillSend(requestRecord)
        }
        let url = baseURL.appendingPathComponent(endpointPath)
        do {
            let response = try await postJSON(url: url, body: body, decode: PixVerseCreateResponse.self)
            do {
                let job = try parseJob(response)
                return PixVerseCreateJobOutcome(job: job, requestRecord: requestRecord)
            } catch {
                throw PixVerseCreateJobError.requestFailed(record: requestRecord, underlying: error)
            }
        } catch let error as PixVerseCreateJobError {
            throw error
        } catch {
            throw PixVerseCreateJobError.requestFailed(record: requestRecord, underlying: error)
        }
    }

    private func fetchStatus(job: PixVerseCreatedJob) async throws -> PixVerseCompletedResult? {
        let path = job.kind == .video ? "videos" : "images"
        let url = baseURL.appendingPathComponent(path).appendingPathComponent(job.id)

        switch job.kind {
        case .video:
            let status = try await get(url: url, decode: PixVerseVideoStatusResponse.self)
            // UseAPI иногда возвращает `QUEUED` как `final=true`; не считаем это фейлом и продолжаем polling.
            if status.shouldContinuePolling {
                return nil
            }
            if status.isTerminalFailure {
                throw NetworkError.serverError(status.error ?? status.videoStatusName ?? "Video generation failed")
            }
            guard status.isCompleted else { return nil }
            guard let urlString = status.url, let resultURL = URL(string: urlString) else { throw NetworkError.invalidResponse }
            return PixVerseCompletedResult(id: job.id, kind: .video, url: resultURL)

        case .image:
            let status = try await get(url: url, decode: PixVerseImageStatusResponse.self)
            if status.isTerminalFailure {
                throw NetworkError.serverError(status.error ?? status.imageStatusName ?? "Image generation failed")
            }
            guard status.imageStatusFinal == true || status.imageStatusName == "COMPLETED" else { return nil }
            guard let urlString = status.imageURL, let resultURL = URL(string: urlString) else { throw NetworkError.invalidResponse }
            return PixVerseCompletedResult(id: job.id, kind: .image, url: resultURL)
        }
    }

    private func postJSON<T: Decodable>(url: URL, body: [String: Any], decode type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await performWithRetry(request, decode: type)
    }

    private func get<T: Decodable>(url: URL, decode type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await performWithRetry(request, decode: type)
    }

    private func performWithRetry<T: Decodable>(_ request: URLRequest, decode type: T.Type, maxAttempts: Int = 3) async throws -> T {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await perform(request, decode: type)
            } catch {
                lastError = error
                guard attempt < maxAttempts, shouldRetry(error) else { throw error }
                let delaySeconds = min(pow(2.0, Double(attempt - 1)), 4.0)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }

        throw lastError ?? NetworkError.unknown
    }

    private func shouldRetry(_ error: Error) -> Bool {
        switch error {
        case NetworkError.requestFailed(_), NetworkError.invalidResponse:
            return true
        case NetworkError.httpError(let code):
            return code == 429 || (500...599).contains(code)
        case NetworkError.providerAPIFailure(let code, _, _, _):
            return code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NetworkError.requestFailed(error)
        }

        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NetworkError.unauthorized }
            if http.statusCode == 404 { throw NetworkError.notFound }
            let bodyText = String(decoding: data, as: UTF8.self)
            let requestURL = request.url?.absoluteString
            let apiError = try? JSONDecoder().decode(PixVerseErrorResponse.self, from: data)
            if let message = apiError?.error, !message.isEmpty {
                throw NetworkError.providerAPIFailure(
                    statusCode: http.statusCode,
                    message: message,
                    responseBody: bodyText.isEmpty ? nil : bodyText,
                    requestURL: requestURL
                )
            }
            if http.statusCode == 412 {
                throw NetworkError.providerAPIFailure(
                    statusCode: http.statusCode,
                    message: "Not enough credits or quota for this request.",
                    responseBody: bodyText.isEmpty ? nil : bodyText,
                    requestURL: requestURL
                )
            }
            if http.statusCode == 422 {
                throw NetworkError.providerAPIFailure(
                    statusCode: http.statusCode,
                    message: "The generation request was rejected. Check the prompt, image, template, or aspect ratio.",
                    responseBody: bodyText.isEmpty ? nil : bodyText,
                    requestURL: requestURL
                )
            }
            if http.statusCode == 596 {
                throw NetworkError.providerAPIFailure(
                    statusCode: http.statusCode,
                    message: "HTTP \(http.statusCode)",
                    responseBody: bodyText.isEmpty ? nil : bodyText,
                    requestURL: requestURL
                )
            }
            throw NetworkError.providerAPIFailure(
                statusCode: http.statusCode,
                message: "HTTP \(http.statusCode)",
                responseBody: bodyText.isEmpty ? nil : bodyText,
                requestURL: requestURL
            )
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed
        }
    }

}

private struct PixVerseErrorResponse: Decodable {
    let error: String?
}

private struct PixVerseUploadResponse: Decodable {
    let path: String?
    let url: String?
    let result: [PixVerseUploadedFile]?
}

private struct PixVerseUploadedFile: Decodable {
    let url: String?
    let path: String?
}

private struct PixVerseCreateResponse: Decodable {
    let videoId: String?
    let imageId: String?
    let successIds: [String]?

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case imageId = "image_id"
        case successIds = "success_ids"
    }
}

private struct PixVerseVideoStatusResponse: Decodable {
    let url: String?
    let error: String?
    let videoStatusName: String?
    let videoStatusFinal: Bool?

    private var normalizedStatusName: String {
        (videoStatusName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var isCompleted: Bool {
        normalizedStatusName == "COMPLETED"
    }

    var shouldContinuePolling: Bool {
        !isCompleted && (normalizedStatusName == "QUEUED" || videoStatusFinal != true)
    }

    var isTerminalFailure: Bool {
        videoStatusFinal == true && !isCompleted && normalizedStatusName != "QUEUED"
    }

    enum CodingKeys: String, CodingKey {
        case url
        case error
        case videoStatusName = "video_status_name"
        case videoStatusFinal = "video_status_final"
    }
}

private struct PixVerseImageStatusResponse: Decodable {
    let imageURL: String?
    let error: String?
    let imageStatusName: String?
    let imageStatusFinal: Bool?

    var isTerminalFailure: Bool {
        imageStatusFinal == true && imageStatusName != "COMPLETED"
    }

    enum CodingKeys: String, CodingKey {
        case imageURL = "image_url"
        case error
        case imageStatusName = "image_status_name"
        case imageStatusFinal = "image_status_final"
    }
}
