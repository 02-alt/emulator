import Foundation

/// A ``ContinuityStore`` backed by a dictionary. For tests, SwiftUI previews, and
/// developing the UI without a provisioned iCloud container. Last-writer-wins per
/// `romHash`, same contract as the CloudKit store.
public actor InMemoryContinuityStore: ContinuityStore {
    private var snapshots: [String: ContinuitySnapshot] = [:]

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

    /// Test affordance: how many games currently have a snapshot.
    public var count: Int { snapshots.count }
}
