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
}
