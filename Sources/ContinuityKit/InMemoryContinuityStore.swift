import Foundation

/// A ``ContinuityStore`` backed by a dictionary. For tests, SwiftUI previews, and
/// developing the UI without a provisioned iCloud container. Last-writer-wins per
/// `romHash`, same contract as the CloudKit store.
public actor InMemoryContinuityStore: ContinuityStore {
    private var snapshots: [String: ContinuitySnapshot] = [:]
    private var romOffers: [String: (fileName: String, coverPNG: Data?, data: Data)] = [:]
    private var romBatteries: [String: Data] = [:]

    public init() {}

    public func publish(_ snapshot: ContinuitySnapshot) async throws {
        snapshots[snapshot.metadata.romHash] = snapshot
    }

    public func fetchCard(romHash: String) async throws -> ContinuityCard? {
        guard let snap = snapshots[romHash] else { return nil }
        // Mirror the CloudKit store: hand back metadata + thumbnail, never the state blob.
        return ContinuityCard(metadata: snap.metadata, thumbnailPNG: snap.thumbnailPNG)
    }

    public func fetchState(romHash: String) async throws -> Data? {
        snapshots[romHash]?.state
    }

    public func delete(romHash: String) async throws {
        snapshots[romHash] = nil
    }

    public func allCards() async throws -> [ContinuityCard] {
        snapshots.values.map { ContinuityCard(metadata: $0.metadata, thumbnailPNG: $0.thumbnailPNG) }
    }

    public func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data) async throws {
        romOffers[romHash] = (fileName, coverPNG, data)
    }

    public func fetchROMInfo(romHash: String) async throws -> String? {
        romOffers[romHash]?.fileName
    }

    public func fetchROM(romHash: String) async throws -> Data? {
        romOffers[romHash]?.data
    }

    public func fetchROMCover(romHash: String) async throws -> Data? {
        romOffers[romHash]?.coverPNG
    }

    public func publishROMBattery(romHash: String, data: Data) async throws {
        // Mirror CloudKit: the battery rides an existing offer; no offer → nothing to attach to.
        guard romOffers[romHash] != nil else { return }
        romBatteries[romHash] = data
    }

    public func fetchROMBattery(romHash: String) async throws -> Data? {
        romBatteries[romHash]
    }

    public func clearROM(romHash: String) async throws {
        romOffers[romHash] = nil
        romBatteries[romHash] = nil   // battery is torn down with the offer
    }

    /// Test affordance: how many games currently have a snapshot.
    public var count: Int { snapshots.count }

    /// Test affordance: how many games currently have a ROM offer.
    public var romOfferCount: Int { romOffers.count }
}
