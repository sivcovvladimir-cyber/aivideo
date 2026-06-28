import Foundation
import ImageIO
import UIKit

/// Снимок контекста при падении генерации — уходит в `generation_logs.response_metadata` (и краткий текст в `error_message`).
struct GenerationFailureDiagnostics {
    var failurePhase: String = "queued"
    private(set) var uploadTraces: [ImageUploadTrace] = []

    mutating func setPhase(_ phase: String) {
        failurePhase = phase
    }

    mutating func recordUpload(_ trace: ImageUploadTrace) {
        uploadTraces.append(trace)
    }

    /// Короткая строка для колонки `error_message` (полный JSON — в `response_metadata`).
    func errorMessageSummary(for error: Error) -> String {
        if let provider = error as? NetworkError, case .providerAPIFailure(let code, let message, _, _) = provider {
            return "HTTP \(code): \(message)"
        }
        return error.localizedDescription
    }

    func responseMetadata(
        error: Error,
        clientJobId: Int,
        request: GenerationJobRequest,
        providerJobId: String?,
        requestMetadata: [String: Any]?
    ) -> [String: Any] {
        var payload: [String: Any] = AppBuildMetadata.dictionary()
        payload["client_generation_id"] = clientJobId
        payload["failure_phase"] = failurePhase
        payload["provider_job_id"] = Self.jsonValue(providerJobId)
        payload["captured_at"] = ISO8601DateFormatter().string(from: Date())
        payload["error"] = Self.errorDictionary(error)
        payload["generation_request"] = Self.requestDictionary(request)
        payload["uploads"] = uploadTraces.map(\.dictionary)
        if uploadTraces.count >= 2 {
            let first = uploadTraces[0]
            let second = uploadTraces[1]
            if let w1 = first.encodedPixelWidth, let h1 = first.encodedPixelHeight,
               let w2 = second.encodedPixelWidth, let h2 = second.encodedPixelHeight {
                payload["upload_pair"] = [
                    "encoded_width_match": w1 == w2,
                    "encoded_height_match": h1 == h2,
                    "image_1": "\(w1)x\(h1)",
                    "image_2": "\(w2)x\(h2)"
                ] as [String: Any]
            }
        }
        if let requestMetadata, !requestMetadata.isEmpty {
            payload["provider_create_request"] = requestMetadata
        }
        return payload
    }

    private static func errorDictionary(_ error: Error) -> [String: Any] {
        var dict: [String: Any] = [
            "type": String(describing: type(of: error)),
            "localized_description": error.localizedDescription
        ]
        if let provider = error as? NetworkError {
            dict["network_error"] = provider.diagnosticLabel
            if case .providerAPIFailure(let code, let message, let body, let url) = provider {
                dict["http_status"] = code
                dict["api_message"] = message
                if let url { dict["request_url"] = url }
                if let body, !body.isEmpty {
                    dict["response_body"] = body.count > 24_000 ? String(body.prefix(24_000)) + "…" : body
                }
            }
        }
        if let create = error as? PixVerseCreateJobError {
            dict["pixverse_create"] = [
                "endpoint": create.requestRecord.endpoint,
                "http_method": create.requestRecord.httpMethod,
                "body_json": create.requestRecord.bodyJSON
            ]
            dict["underlying"] = errorDictionary(create.underlying)
        }
        return dict
    }

    private static func requestDictionary(_ request: GenerationJobRequest) -> [String: Any] {
        switch request {
        case .promptVideo(let prompt, let duration, let audio, let aspect, let path0, let path1, let twoImageMode, let quality):
            return [
                "kind": "prompt_video",
                "prompt_length": prompt.count,
                "duration": duration,
                "audio_enabled": audio,
                "aspect_ratio": jsonValue(aspect),
                "local_image_path_1": jsonValue(path0),
                "local_image_path_2": jsonValue(path1),
                "two_image_mode": jsonValue(twoImageMode?.rawValue),
                "video_quality": quality.rawValue
            ]
        case .promptPhoto(let prompt, let aspect, let path0, let path1):
            return [
                "kind": "prompt_photo",
                "prompt_length": prompt.count,
                "aspect_ratio": jsonValue(aspect),
                "local_image_path_1": jsonValue(path0),
                "local_image_path_2": jsonValue(path1)
            ]
        case .effect(let preset, let path):
            return [
                "kind": "effect_video",
                "effect_preset_id": preset.id,
                "effect_title": preset.title,
                "template_id": jsonValue(preset.providerTemplateId),
                "video_quality": preset.resolvedVideoQualityForGeneration(),
                "local_image_path": path
            ]
        case .lipSync(let linesPrompt, let speakerId, let audioPath, let videoPath, let providerJobId, let originalAudio):
            return [
                "kind": "lip_sync",
                "lines_prompt_length": linesPrompt?.count ?? 0,
                "speaker_id": jsonValue(speakerId),
                "local_audio_path": jsonValue(audioPath),
                "local_video_path": jsonValue(videoPath),
                "source_provider_job_id": jsonValue(providerJobId),
                "original_audio_enabled": originalAudio
            ]
        }
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

struct ImageUploadTrace {
    let label: String
    let localPath: String
    let rawFileBytes: Int
    let rawFormatHint: String
    let decodedPointWidth: Double
    let decodedPointHeight: Double
    let decodedScale: Double
    let decodedPixelWidth: Int
    let decodedPixelHeight: Int
    let afterPipelinePointWidth: Double
    let afterPipelinePointHeight: Double
    let afterPipelineScale: Double
    let afterPipelinePixelWidth: Int
    let afterPipelinePixelHeight: Int
    let uploadContentType: String
    let uploadBytes: Int
    let encodedPixelWidth: Int?
    let encodedPixelHeight: Int?
    let providerPath: String?
    let providerURL: String?

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "label": label,
            "local_path": localPath,
            "raw_file_bytes": rawFileBytes,
            "raw_format_hint": rawFormatHint,
            "decoded": [
                "points": "\(decodedPointWidth)x\(decodedPointHeight)",
                "scale": decodedScale,
                "pixels": "\(decodedPixelWidth)x\(decodedPixelHeight)"
            ],
            "after_pipeline": [
                "points": "\(afterPipelinePointWidth)x\(afterPipelinePointHeight)",
                "scale": afterPipelineScale,
                "pixels": "\(afterPipelinePixelWidth)x\(afterPipelinePixelHeight)"
            ],
            "upload": [
                "content_type": uploadContentType,
                "bytes": uploadBytes,
                "encoded_pixels": Self.jsonValue(
                    encodedPixelWidth.flatMap { w in
                        encodedPixelHeight.map { h in "\(w)x\(h)" }
                    }
                )
            ]
        ]
        if let providerPath { d["provider_path"] = providerPath }
        if let providerURL { d["provider_url"] = providerURL }
        if let w = encodedPixelWidth, let h = encodedPixelHeight {
            if w < 300 || h < 300 {
                d["warning_small_encoded"] = true
            }
            if w % 2 != 0 || h % 2 != 0 {
                d["warning_odd_dimensions"] = true
            }
        }
        return d
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    static func capture(
        label: String,
        localPath: String,
        raw: Data,
        decoded: UIImage,
        afterPipeline: UIImage,
        uploadContentType: String,
        uploadData: Data,
        uploadResult: PixVerseUploadResult?
    ) -> ImageUploadTrace {
        let encodedPixels = UIImage.jpegPixelDimensions(from: uploadData)
        return ImageUploadTrace(
            label: label,
            localPath: localPath,
            rawFileBytes: raw.count,
            rawFormatHint: Data.imageFormatHint(raw),
            decodedPointWidth: Double(decoded.size.width),
            decodedPointHeight: Double(decoded.size.height),
            decodedScale: Double(decoded.scale),
            decodedPixelWidth: decoded.pixelWidth,
            decodedPixelHeight: decoded.pixelHeight,
            afterPipelinePointWidth: Double(afterPipeline.size.width),
            afterPipelinePointHeight: Double(afterPipeline.size.height),
            afterPipelineScale: Double(afterPipeline.scale),
            afterPipelinePixelWidth: afterPipeline.pixelWidth,
            afterPipelinePixelHeight: afterPipeline.pixelHeight,
            uploadContentType: uploadContentType,
            uploadBytes: uploadData.count,
            encodedPixelWidth: encodedPixels?.width,
            encodedPixelHeight: encodedPixels?.height,
            providerPath: uploadResult?.path,
            providerURL: uploadResult?.url?.absoluteString
        )
    }
}

enum AppBuildMetadata {
    static func dictionary() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "platform": "ios",
            "app_version": jsonValue(info["CFBundleShortVersionString"] as? String),
            "build_number": jsonValue(info["CFBundleVersion"] as? String),
            "bundle_id": jsonValue(Bundle.main.bundleIdentifier),
            "ios_version": UIDevice.current.systemVersion,
            "device_model": UIDevice.current.model,
            "locale": Locale.current.identifier,
            "install_id": UserInstallIDService.shared.installId
        ]
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

private extension UIImage {
    static func jpegPixelDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }
}

private extension Data {
    static func imageFormatHint(_ data: Data) -> String {
        guard data.count >= 3 else { return "empty_or_tiny" }
        if data.isLikelyJPEGOrPNGImagePayload {
            if data[0] == 0x89 { return "png" }
            return "jpeg"
        }
        if data.count >= 12 {
            let ftyp = String(data: data.subdata(in: 4..<8), encoding: .ascii) ?? ""
            if ftyp == "ftyp" { return "heif/heic_container" }
        }
        return "unknown"
    }
}

private extension NetworkError {
    var diagnosticLabel: String {
        switch self {
        case .invalidURL: return "invalidURL"
        case .invalidConfiguration: return "invalidConfiguration"
        case .invalidData: return "invalidData"
        case .requestFailed: return "requestFailed"
        case .invalidResponse: return "invalidResponse"
        case .decodingFailed: return "decodingFailed"
        case .uploadFailed: return "uploadFailed"
        case .downloadFailed: return "downloadFailed"
        case .unauthorized: return "unauthorized"
        case .notFound: return "notFound"
        case .serverError: return "serverError"
        case .httpError(let code): return "httpError(\(code))"
        case .providerAPIFailure(let code, _, _, _): return "providerAPIFailure(\(code))"
        case .noData: return "noData"
        case .generationTimeoutWithRequestId: return "generationTimeout"
        case .unknown: return "unknown"
        }
    }
}
