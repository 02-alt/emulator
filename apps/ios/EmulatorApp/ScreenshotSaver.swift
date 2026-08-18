import Foundation
import Photos

/// Saves a PNG screenshot into the user's photo library (add-only). Requests permission on first use.
enum ScreenshotSaver {
    /// `completion` is called on the main thread with success.
    static func save(_ pngData: Data, completion: @escaping (Bool) -> Void) {
        func write() {
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData, options: nil)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            }
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            write()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                if newStatus == .authorized || newStatus == .limited { write() }
                else { DispatchQueue.main.async { completion(false) } }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}
