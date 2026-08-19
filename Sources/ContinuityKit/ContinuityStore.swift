import Foundation

/// Errors surfaced by a continuity store or coordinator.
public enum ContinuityError: Error, Sendable {
    /// iCloud account is unavailable (signed out, restricted, or network down).
    case cloudUnavailable(underlying: String)
    /// A snapshot exists, but it was written by a different core build and cannot be
    /// safely restored. Carries the offending version so the UI can explain it.
    case incompatibleCoreVersion(snapshotVersion: String, current: String)
    /// The store contract was violated (e.g. a record missing its state asset).
    case malformedRecord(reason: String)
}

/// The persistence boundary for continuity. One live snapshot per `romHash`
/// (last-writer-wins): publishing again overwrites the previous session for that game.
///
/// Intentionally free of any UI, core, or CloudKit type so it can be backed by
/// CloudKit in the app and by an in-memory fake in tests. Reads are split so the
/// UI can render a card cheaply and only pull the heavy savestate on demand.
public protocol ContinuityStore: Sendable {
    /// Upsert the latest session for `snapshot.metadata.romHash`.
    func publish(_ snapshot: ContinuitySnapshot) async throws

    /// Fetch the light card (metadata + thumbnail) for a game, or nil if none exists.
    /// Must NOT download the savestate payload.
    func fetchCard(romHash: String) async throws -> ContinuityCard?

    /// Download the full savestate for a game, or nil if none exists.
    func fetchState(romHash: String) async throws -> Data?

    /// Remove the snapshot for a game (e.g. after a successful local resume, or on the
    /// user clearing continuity).
    func delete(romHash: String) async throws

    /// Every session currently stored, as light cards (no savestate). Lets a device discover
    /// sessions for games it doesn't have locally — the case that drives an offer-to-transfer.
    /// Order is unspecified; callers sort by `metadata.timestamp` if they need "newest".
    func allCards() async throws -> [ContinuityCard]

    // MARK: ROM transfer (opt-in, ephemeral)
    //
    // A ROM offer lives in its own record, separate from the frequent savestate publishes, so
    // state sync stays cheap and the (heavy, copyright-sensitive) ROM can be uploaded once and
    // torn down independently. The receiver deletes the offer as soon as it has imported the ROM,
    // making the cloud copy transient. Everything stays in the user's *own* private database.

    /// Offer a game's ROM bytes for transfer to another of the user's devices that lacks it.
    /// Idempotent per `romHash`. `fileName` carries the original name (incl. extension) so the
    /// receiver can import it with the right system and a clean title. `coverPNG` is the sender's
    /// cached box art (optional) so the receiver shows the exact same art without re-matching.
    func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data) async throws

    /// The offered ROM's filename if a transfer is available for this game, else nil. Cheap —
    /// must NOT download the ROM bytes.
    func fetchROMInfo(romHash: String) async throws -> String?

    /// Download the offered ROM bytes, or nil if no offer exists.
    func fetchROM(romHash: String) async throws -> Data?

    /// Download the offered box art (small), or nil if none was included with the offer.
    func fetchROMCover(romHash: String) async throws -> Data?

    /// Delete the ROM offer (bytes + filename). Called by the receiver right after import so the
    /// copy is ephemeral, or by the sender to withdraw an offer.
    func clearROM(romHash: String) async throws

    // MARK: Targeted transfer (optional)
    //
    // A send can be addressed to one specific device (by its `deviceName`) instead of broadcast to
    // all of them. Additive: stores that don't override the two members below fall back to broadcast,
    // so the existing (untargeted) path is unaffected.

    /// Offer a ROM addressed to a specific device by name; `targetDevice: nil` broadcasts to every
    /// device (the historical behaviour). Idempotent per `romHash`.
    func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data, targetDevice: String?) async throws

    /// The device a ROM offer is addressed to, or nil for a broadcast offer / when no offer exists.
    func fetchROMTarget(romHash: String) async throws -> String?
}

public extension ContinuityStore {
    /// Default: ignore the target and broadcast — keeps stores that predate targeting compiling and
    /// behaving exactly as before.
    func publishROM(romHash: String, fileName: String, coverPNG: Data?, data: Data, targetDevice: String?) async throws {
        try await publishROM(romHash: romHash, fileName: fileName, coverPNG: coverPNG, data: data)
    }

    /// Default: offers are broadcast (no addressee).
    func fetchROMTarget(romHash: String) async throws -> String? { nil }
}
