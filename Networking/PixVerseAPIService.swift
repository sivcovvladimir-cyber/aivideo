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

final class PixVerseAPIService {
    static let shared = PixVerseAPIService()

    private let baseURL = URL(string: "https://api.useapi.net/v2/pixverse")!
    private let defaultVideoModel = "pixverse-c1"
    private let defaultVideoQuality = "540p"
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

    func createVideo(_ payload: PixVerseCreateVideoRequest) async throws -> PixVerseCreatedJob {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let url = baseURL.appendingPathComponent("videos/create")
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

        let response = try await postJSON(url: url, body: body, decode: PixVerseCreateResponse.self)
        if let videoId = response.videoId, !videoId.isEmpty {
            return PixVerseCreatedJob(id: videoId, kind: .video)
        }
        throw NetworkError.invalidResponse
    }

    func createImage(_ payload: PixVerseCreateImageRequest) async throws -> PixVerseCreatedJob {
        guard isConfigured else { throw NetworkError.invalidConfiguration }

        let url = baseURL.appendingPathComponent("images/create")
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

        let response = try await postJSON(url: url, body: body, decode: PixVerseCreateResponse.self)
        let imageId = response.successIds?.first ?? response.imageId
        if let imageId, !imageId.isEmpty {
            return PixVerseCreatedJob(id: imageId, kind: .image)
        }
        throw NetworkError.invalidResponse
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

    private func fetchStatus(job: PixVerseCreatedJob) async throws -> PixVerseCompletedResult? {
        let path = job.kind == .video ? "videos" : "images"
        let url = baseURL.appendingPathComponent(path).appendingPathComponent(job.id)

        switch job.kind {
        case .video:
            let status = try await get(url: url, decode: PixVerseVideoStatusResponse.self)
            if status.isTerminalFailure {
                throw NetworkError.serverError(status.error ?? status.videoStatusName ?? "Video generation failed")
            }
            guard status.videoStatusFinal == true || status.videoStatusName == "COMPLETED" else { return nil }
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
            let apiError = try? JSONDecoder().decode(PixVerseErrorResponse.self, from: data)
            if let message = apiError?.error, !message.isEmpty {
                throw mapPixVerseError(statusCode: http.statusCode, message: message)
            }
            if http.statusCode == 412 {
                throw NetworkError.serverError("Not enough credits or quota for this request.")
            }
            if http.statusCode == 422 {
                throw NetworkError.serverError("The generation request was rejected. Check the prompt, image, template, or aspect ratio.")
            }
            if http.statusCode == 596 {
                throw NetworkError.httpError(http.statusCode)
            }
            throw NetworkError.httpError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed
        }
    }

    private func mapPixVerseError(statusCode: Int, message: String) -> NetworkError {
        switch statusCode {
        case 412:
            return .serverError("Quota or credits error: \(message)")
        case 422:
            return .serverError("Request validation failed: \(message)")
        case 596:
            return .httpError(statusCode)
        default:
            return .serverError(message)
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

    var isTerminalFailure: Bool {
        videoStatusFinal == true && videoStatusName != "COMPLETED"
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
