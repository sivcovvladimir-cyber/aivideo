import Foundation
import AVFoundation
import Photos
import AppTrackingTransparency
import AdSupport

class PermissionManager {
    static let shared = PermissionManager()
    private init() {}

    // MARK: - Camera
    func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Photo Library
    func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    completion(newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            completion(false)
        }
    }

    // MARK: - IDFA (AppTrackingTransparency)
    func requestTrackingPermission(completion: ((ATTrackingManager.AuthorizationStatus) -> Void)? = nil) {
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { status in
                completion?(status)
            }
        } else {
            completion?(.authorized)
        }
    }

    // MARK: - Status Checkers
    func isCameraDenied() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .denied
    }
    func isPhotoLibraryDenied() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus()
        return status == .denied || status == .restricted
    }
} 