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

    /// Every stored session as light cards (no savestate), newest first. Lets a device discover
    /// sessions for games it doesn't have locally — the input to an offer-to-transfer.
    public func allCards() async throws -> [ContinuityCard] {
        try await store.allCards().sorted { $0.metadata.timestamp > $1.metadata.timestamp }
    }

    // MARK: ROM transfer (opt-in, ephemeral)

    /// Offer a game's ROM so another of the user's devices that lacks it can receive and import it.
    /// `coverPNG` is the sender's cached box art (optional) so the receiver shows matching art.
    public func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data) async throws {
        try await publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: nil)
    }

    /// Offer a ROM addressed to one device by name (`targetDevice`), or broadcast to all when nil.
    public func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data, targetDevice: String?) async throws {
        try await store.publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: targetDevice)
    }

    /// The offered ROM's filename for this game, or nil if no transfer is available *to this device*.
    /// A targeted offer is visible only to its addressee; broadcast offers are visible to everyone.
    public func romOffer(forRomHash romHash: String) async throws -> String? {
        guard let name = try await store.fetchROMInfo(romHash: romHash) else { return nil }
        if let target = try await store.fetchROMTarget(romHash: romHash), target != deviceName {
            return nil
        }
        return name
    }

    /// Distinct device names that have published a session *or* a ROM offer, excluding this device —
    /// the addressable targets for a "Send to →" menu, newest-active first. Derived from existing
    /// records, so targeting needs no separate presence registry. Folding in offer devices means a
    /// device that only ever *shared* a ROM (never played) is still a reachable target.
    public func otherDeviceNames() async throws -> [String] {
        async let cardsTask = store.allCards()
        async let offersTask = store.allROMOffers()
        let cards = (try? await cardsTask) ?? []
        let offers = (try? await offersTask) ?? []
        let dated: [(name: String, when: Date)] =
            cards.map { ($0.metadata.deviceName, $0.metadata.timestamp) }
            + offers.map { ($0.deviceName, $0.timestamp) }
        var seen = Set<String>()
        var names: [String] = []
        for entry in dated.sorted(by: { $0.when > $1.when })
        where !entry.name.isEmpty && entry.name != deviceName && seen.insert(entry.name).inserted {
            names.append(entry.name)
        }
        return names
    }

    /// ROM offers visible to *this* device — broadcasts plus offers addressed to us, newest first, with
    /// our own offers excluded. Backs direct offer-discovery so a shared game surfaces even when the
    /// sender never played it (no companion snapshot). Cheap — metadata only, never the ROM bytes.
    public func romOffers() async throws -> [ROMOffer] {
        try await store.allROMOffers()
            .filter { $0.deviceName != deviceName && ($0.targetDevice == nil || $0.targetDevice == deviceName) }
            .sorted { $0.timestamp > $1.timestamp }
    }


    /// Download the offered ROM bytes, or nil if none.
    public func fetchROM(forRomHash romHash: String) async throws -> Data? {
        try await store.fetchROM(romHash: romHash)
    }

    /// Download the offered box art, or nil if none was included.
    public func fetchROMCover(forRomHash romHash: String) async throws -> Data? {
        try await store.fetchROMCover(romHash: romHash)
    }

    /// Attach the game's battery save to the ROM offer just published, so the receiver continues the
    /// player's progress instead of a blank cartridge. Call right after ``publishROM``.
    public func publishROMBattery(romHash: String, data: Data) async throws {
        try await store.publishROMBattery(romHash: romHash, data: data)
    }

    /// Download the battery save that rode along with a ROM offer, or nil if none.
    public func fetchROMBattery(forRomHash romHash: String) async throws -> Data? {
        try await store.fetchROMBattery(romHash: romHash)
    }

    /// Delete the ROM offer — called by the receiver right after import to keep the copy ephemeral.
    public func clearROM(romHash: String) async throws {
        try await store.clearROM(romHash: romHash)
    }
}
