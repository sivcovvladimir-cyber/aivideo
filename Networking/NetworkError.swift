import Foundation

/// Ошибки сетевого слоя. LocalizedError даёт человекочитаемый localizedDescription вместо «error N».
public enum NetworkError: LocalizedError {
    case invalidURL
    case invalidConfiguration
    case invalidData
    case requestFailed(Error)
    case invalidResponse
    case decodingFailed
    case uploadFailed
    case downloadFailed
    case unauthorized
    case notFound
    case serverError(String?)
    case httpError(Int)
    case noData
    case generationTimeoutWithRequestId(String)
    case unknown

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidConfiguration: return "Service is not configured"
        case .invalidData: return "Invalid request data"
        case .requestFailed(let err): return "Network error: \(err.localizedDescription)"
        case .invalidResponse: return "Invalid server response"
        case .decodingFailed: return "Failed to parse response"
        case .uploadFailed: return "Upload failed"
        case .downloadFailed: return "Download failed"
        case .unauthorized: return "Unauthorized"
        case .notFound: return "Not found"
        case .serverError(let msg): return msg ?? "Server error"
        case .httpError(let code):
            switch code {
            case 429: return "Provider is rate limited. Please try again in a minute"
            case 500...599: return "Provider is temporarily unavailable"
            default: return "HTTP error \(code)"
            }
        case .noData: return "No data received"
        case .generationTimeoutWithRequestId(let id): return "Generation timed out (\(id))"
        case .unknown: return "Unknown error"
        }
    }
} 