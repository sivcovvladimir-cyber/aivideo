import Foundation
import UIKit

class ContactService {
    static let shared = ContactService()

    private init() {}

    // MARK: - Public API

    func submitContactForm(message: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendToSupabase(type: "contact", message: message, completion: completion)
    }

    func submitNegativeFeedback(message: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sendToSupabase(type: "negative_feedback", message: message, completion: completion)
    }

    // MARK: - Private

    private func sendToSupabase(type: String, message: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let model = UIDevice.current.model
        let sysVersion = UIDevice.current.systemVersion
        let locale = Locale.current.identifier
        let timezone = TimeZone.current.identifier
        
        let payload = SupabaseFeedbackPayload(
            type: type,
            message: message,
            userInstallId: UserInstallIDService.shared.installId,
            appVersion: appVersion,
            buildNumber: buildNumber,
            iosVersion: sysVersion,
            deviceModel: model,
            locale: locale,
            timezone: timezone
        )

        SupabaseService.shared.submitAppFeedback(payload: payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}
