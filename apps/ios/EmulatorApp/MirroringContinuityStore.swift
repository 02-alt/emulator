import Foundation
import ContinuityKit

/// A `ContinuityStore` that mirrors a fast local store and iCloud (CloudKit):
///   • **publish** writes local first (instant, always works), then best-effort to CloudKit;
///   • **reads** prefer the *newer* of the two, so a session from another device wins when iCloud
///     has fresher data, and local answers immediately when iCloud is signed out / offline.
///
/// This keeps single-device resume snappy and reliable while adding true cross-device continuity
/// wherever iCloud is available — with no UI changes.
struct MirroringContinuityStore: ContinuityStore {
    let local: LocalContinuityStore
    let cloud: CloudKitContinuityStore

    func publish(_ snapshot: ContinuitySnapshot) async throws {
        try await local.publish(snapshot)          // must succeed — the instant local copy
        try? await cloud.publish(snapshot)          // best-effort — offline / signed-out is fine
    }

    func fetchCard(romHash: String) async throws -> ContinuityCard? {
        let localCard = try? await local.fetchCard(romHash: romHash)
        let cloudCard = try? await cloud.fetchCard(romHash: romHash)
        switch (localCard, cloudCard) {
        case let (l?, c?): return c.metadata.timestamp >= l.metadata.timestamp ? c : l
        case let (l?, nil): return l
        case let (nil, c?): return c
        default: return nil
        }
    }

    func fetchState(romHash: String) async throws -> Data? {
        // Prefer whichever source holds the newer card, so a cross-device resume pulls the right blob.
        let localCard = try? await local.fetchCard(romHash: romHash)
        let cloudCard = try? await cloud.fetchCard(romHash: romHash)
        let cloudNewer = (cloudCard?.metadata.timestamp ?? .distantPast)
            >= (localCard?.metadata.timestamp ?? .distantPast)
        if cloudNewer, let state = try? await cloud.fetchState(romHash: romHash) { return state }
        return try await local.fetchState(romHash: romHash)
    }

    func delete(romHash: String) async throws {
        try? await local.delete(romHash: romHash)
        try? await cloud.delete(romHash: romHash)
    }
}
