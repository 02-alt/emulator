import Foundation

/// App-facing entry point over a ``ContinuityStore``. Adds the two policies the raw
/// store deliberately leaves out:
///   • the core-version gate on resume (never hand a stale savestate to `loadState`), and
///   • debounced publishing (pause/close can fire in bursts; we only want the last one).
///
/// One coordinator per running app. `coreVersion` identifies this build's savestate
/// format; `deviceName` labels snapshots this device writes.
public actor ContinuityCoordinator {
    private let store: ContinuityStore
    private let coreVersion: String
    public let deviceName: String

    /// Debounce state: the in-flight delayed publish, cancelled and replaced when a
    /// newer snapshot arrives before it fires.
    private var pendingPublish: Task<Void, Never>?

    public init(store: ContinuityStore, coreVersion: String, deviceName: String) {
        self.store = store
        self.coreVersion = coreVersion
        self.deviceName = deviceName
    }

    /// Build metadata stamped with this coordinator's device + core identity.
    public func makeMetadata(
        romHash: String,
        romTitle: String,
        secondsPlayed: Int,
        timestamp: Date = Date()
    ) -> ContinuityMetadata {
        ContinuityMetadata(
            romHash: romHash,
            romTitle: romTitle,
            timestamp: timestamp,
            deviceName: deviceName,
            secondsPlayed: secondsPlayed,
            coreVersion: coreVersion
        )
    }

    /// The light card to render "Continue where you left off", or nil if there's no
    /// session for this game. Never downloads the savestate.
    public func card(forRomHash romHash: String) async throws -> ContinuityCard? {
        try await store.fetchCard(romHash: romHash)
    }

    /// Download and validate the savestate to resume `romHash`. Throws
    /// ``ContinuityError/incompatibleCoreVersion(snapshotVersion:current:)`` if the
    /// snapshot was written by a different core build — callers should treat that as
    /// "can't continue" rather than risking a crash in `loadState`.
    ///
    /// Returns nil only when no snapshot exists at all.
    public func resumeState(forRomHash romHash: String) async throws -> Data? {
        guard let card = try await store.fetchCard(romHash: romHash) else { return nil }
        guard card.isRestorable(byCoreVersion: coreVersion) else {
            throw ContinuityError.incompatibleCoreVersion(
                snapshotVersion: card.metadata.coreVersion,
                current: coreVersion
            )
        }
        return try await store.fetchState(romHash: romHash)
    }

    /// Publish immediately. Prefer ``schedulePublish(_:debounce:)`` for lifecycle events
    /// that can fire in bursts.
    public func publish(_ snapshot: ContinuitySnapshot) async throws {
        pendingPublish?.cancel()
        pendingPublish = nil
        try await store.publish(snapshot)
    }

    /// Publish after a quiet interval, superseding any earlier scheduled publish. Use on
    /// pause/background where the same game may be toggled several times quickly — only
    /// the final state should reach iCloud. Errors are swallowed (best-effort background
    /// sync); use ``publish(_:)`` when you need to observe failure.
    public func schedulePublish(_ snapshot: ContinuitySnapshot, debounce: Duration = .seconds(2)) {
        pendingPublish?.cancel()
        pendingPublish = Task { [store] in
            do {
                try await Task.sleep(for: debounce)
                try await store.publish(snapshot)
            } catch {
                // Cancelled by a newer snapshot, or a transient publish failure — fine.
            }
        }
    }

    /// Drop the snapshot for a game (e.g. after resuming locally so it isn't offered twice).
    public func clear(romHash: String) async throws {
        try await store.delete(romHash: romHash)
    }
}
