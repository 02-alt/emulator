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

    func allCards() async throws -> [ContinuityCard] {
        let localCards = (try? await local.allCards()) ?? []
        let cloudCards = (try? await cloud.allCards()) ?? []
        // Merge by romHash, keeping the newer card so a cross-device session wins over a stale local one.
        var byHash: [String: ContinuityCard] = [:]
        for card in localCards + cloudCards {
            let hash = card.metadata.romHash
            if let existing = byHash[hash], existing.metadata.timestamp >= card.metadata.timestamp {
                continue
            }
            byHash[hash] = card
        }
        return Array(byHash.values)
    }

    func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data) async throws {
        try await publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: nil)
    }

    func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data, targetDevice: String?) async throws {
        try await local.publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: targetDevice)  // instant local copy
        try? await cloud.publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: targetDevice)  // best-effort to iCloud
    }

    func fetchROMTarget(romHash: String) async throws -> String? {
        // The transfer source is another device, so the offer lives in iCloud; fall back to local.
        if let target = try? await cloud.fetchROMTarget(romHash: romHash) { return target }
        return try await local.fetchROMTarget(romHash: romHash)
    }

    func fetchROMInfo(romHash: String) async throws -> String? {
        // The transfer source is another device, so the offer lives in iCloud; fall back to local.
        if let info = try? await cloud.fetchROMInfo(romHash: romHash) { return info }
        return try await local.fetchROMInfo(romHash: romHash)
    }

    func fetchROM(romHash: String) async throws -> Data? {
        if let rom = try? await cloud.fetchROM(romHash: romHash) { return rom }
        return try await local.fetchROM(romHash: romHash)
    }

    func fetchROMCover(romHash: String) async throws -> Data? {
        if let cover = try? await cloud.fetchROMCover(romHash: romHash) { return cover }
        return try await local.fetchROMCover(romHash: romHash)
    }

    func clearROM(romHash: String) async throws {
        try? await local.clearROM(romHash: romHash)
        try? await cloud.clearROM(romHash: romHash)
    }
}
