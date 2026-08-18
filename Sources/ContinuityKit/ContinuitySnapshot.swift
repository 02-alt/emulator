import Foundation

/// Everything needed to describe "where you left off" in one game, on one device,
/// so another device signed into the same iCloud account can offer to continue.
///
/// The identity key is `romHash` — the same sha256 prefix `LibraryKit.Game` uses.
/// Because a given ROM hashes identically on every device, no pairing or manual
/// linking is needed: hash matches → same game.
///
/// A snapshot is split conceptually into three weights:
///   • `ContinuityMetadata` — tiny, always fetched (title, when, which device, version).
///   • `thumbnailPNG`       — small, fetched to render the "Continue" card.
///   • `state`              — potentially multi-MB, fetched only when the user taps Continue.
/// The store honors that split so showing a card doesn't pull the whole savestate.
public struct ContinuitySnapshot: Codable, Sendable, Equatable {
    public var metadata: ContinuityMetadata
    /// A savestate produced by `EmulatorCore.saveState()`. Restored via `loadState(_:)`.
    public var state: Data
    /// Last visible frame, PNG-encoded, for the "Continue" card. Small.
    public var thumbnailPNG: Data?

    public init(metadata: ContinuityMetadata, state: Data, thumbnailPNG: Data? = nil) {
        self.metadata = metadata
        self.state = state
        self.thumbnailPNG = thumbnailPNG
    }
}

/// The cheap-to-fetch part of a snapshot. Safe to list/scan without paying for the
/// savestate download.
public struct ContinuityMetadata: Codable, Sendable, Equatable {
    /// sha256 hex prefix — the cross-device game identity (matches `Game.romHash`).
    public var romHash: String
    /// Display title, so the card reads right even if the other device lacks box art.
    public var romTitle: String
    /// When the snapshot was captured (used for "2m ago" and last-writer-wins ordering).
    public var timestamp: Date
    /// e.g. "Austin's iPhone" — shown on the card ("Continue from iPhone").
    public var deviceName: String
    /// Total play time at capture, so the receiving device can keep the counter honest.
    public var secondsPlayed: Int
    /// Identifies the exact core build that produced `state`. A savestate is only valid
    /// against the build that wrote it; a mismatch here means "do not restore".
    /// See ``ContinuityMetadata/isRestorable(byCoreVersion:)``.
    public var coreVersion: String

    public init(
        romHash: String,
        romTitle: String,
        timestamp: Date = Date(),
        deviceName: String,
        secondsPlayed: Int,
        coreVersion: String
    ) {
        self.romHash = romHash
        self.romTitle = romTitle
        self.timestamp = timestamp
        self.deviceName = deviceName
        self.secondsPlayed = secondsPlayed
        self.coreVersion = coreVersion
    }

    /// Whether a snapshot written by this metadata's core can be safely restored by a
    /// core reporting `current`. Savestates are not portable across core builds, so this
    /// is an exact-match gate — the single guard that keeps a stale state from crashing
    /// `loadState`. Callers that get `false` should still *show* the card (it proves a
    /// session exists) but disable Continue and explain the version is out of date.
    public func isRestorable(byCoreVersion current: String) -> Bool {
        coreVersion == current
    }
}

/// What the "Continue where you left off" card needs: metadata + the small thumbnail,
/// without the heavy savestate. Returned by ``ContinuityStore/fetchCard(romHash:)``.
public struct ContinuityCard: Sendable, Equatable {
    public var metadata: ContinuityMetadata
    public var thumbnailPNG: Data?

    public init(metadata: ContinuityMetadata, thumbnailPNG: Data? = nil) {
        self.metadata = metadata
        self.thumbnailPNG = thumbnailPNG
    }

    public func isRestorable(byCoreVersion current: String) -> Bool {
        metadata.isRestorable(byCoreVersion: current)
    }
}
