import Foundation
import LibraryKit
import ContinuityKit

/// A persistent, on-disk `ContinuityStore` — the same contract as `CloudKitContinuityStore`, but
/// backed by the local filesystem. Used now so the whole Continuity UX works and survives app
/// launches on a single device without provisioning an iCloud container; swapping in
/// `CloudKitContinuityStore` (plus the iCloud capability) turns it into real cross-device resume
/// with no other code changes.
///
/// Layout: <App Support>/Emulator/continuity/<romHash>/{meta.json, state.bin, thumb.png}.
actor LocalContinuityStore: ContinuityStore {
    private let root: URL

    init(root: URL = AppPaths.appSupport.appendingPathComponent("continuity", isDirectory: true)) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func dir(_ hash: String) -> URL {
        root.appendingPathComponent(hash, isDirectory: true)
    }

    func publish(_ snapshot: ContinuitySnapshot) async throws {
        let dir = dir(snapshot.metadata.romHash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot.metadata).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        try snapshot.state.write(to: dir.appendingPathComponent("state.bin"), options: .atomic)
        let thumbURL = dir.appendingPathComponent("thumb.png")
        if let thumb = snapshot.thumbnailPNG {
            try thumb.write(to: thumbURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: thumbURL)
        }
    }

    func fetchCard(romHash: String) async throws -> ContinuityCard? {
        let metaURL = dir(romHash).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let metadata = try? JSONDecoder().decode(ContinuityMetadata.self, from: data)
        else { return nil }
        let thumb = try? Data(contentsOf: dir(romHash).appendingPathComponent("thumb.png"))
        return ContinuityCard(metadata: metadata, thumbnailPNG: thumb)
    }

    func fetchState(romHash: String) async throws -> Data? {
        try? Data(contentsOf: dir(romHash).appendingPathComponent("state.bin"))
    }

    func delete(romHash: String) async throws {
        try? FileManager.default.removeItem(at: dir(romHash))
    }
}
