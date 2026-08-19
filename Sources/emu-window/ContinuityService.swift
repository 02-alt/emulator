import AppKit
import Foundation
import Security
import LibraryKit
import GBACore
import ContinuityKit

/// A cross-device session another device left resumable, already matched to a game in this Mac's
/// library. The library surfaces the newest one as a "Continue from iPhone" card.
struct CrossDeviceContinue {
    let game: Game
    let card: ContinuityCard
    /// e.g. "iPhone" — the source device, for the card's eyebrow ("CONTINUE FROM IPHONE").
    var deviceName: String { card.metadata.deviceName }
}

/// A resumable session for a game this Mac does **not** have locally, whose source device has also
/// offered the ROM for transfer. Surfaced as a "Transfer from iPhone" card; accepting it downloads
/// and imports the ROM (ephemerally — see `ContinuityStore`) before resuming.
struct CrossDeviceTransfer {
    let card: ContinuityCard
    /// Original ROM filename (incl. extension) so the import lands with the right system + title.
    let fileName: String
    var deviceName: String { card.metadata.deviceName }
    var romHash: String { card.metadata.romHash }
}

/// The macOS half of Continuity: reads sessions published by other devices (today, the iPhone app)
/// from the shared private CloudKit database and offers the newest one for resume. It does **not**
/// publish yet — that lands with the play-lifecycle wiring — so this is read-only for now, which is
/// enough for the "start on iPhone, continue on Mac" direction.
///
/// Mirrors `apps/ios/EmulatorApp/ContinuityService.swift` (same container, same `coreVersion`) so
/// the two apps see each other's sessions. All CloudKit work is off the main actor; the resolved
/// card is published back on the main actor for the AppKit UI.
@MainActor
final class ContinuityService {
    /// Must match the iOS build exactly or the version gate rejects every cross-device resume.
    static let coreVersion = MGBACore.coreVersion

    /// Shared with the iOS app's iCloud entitlement — same container == same private DB.
    static let cloudContainer = "iCloud.com.buildtoberemembered.encore"

    /// This Mac's name, so sessions it eventually publishes read as "Continue from <Mac>". Also used
    /// to filter our own sessions out of the card (we don't offer to continue where we already are).
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    private let coordinator: ContinuityCoordinator?

    init() {
        // Only construct the CloudKit store when the container is actually granted to this signed
        // build AND iCloud is signed in — CKContainer(identifier:) traps otherwise (see cloudKitUsable).
        // With no usable iCloud there are no remote sessions to read, so the coordinator is nil and
        // the card simply never appears.
        if Self.cloudKitUsable {
            coordinator = ContinuityCoordinator(
                store: CloudKitContinuityStore(containerIdentifier: Self.cloudContainer),
                coreVersion: Self.coreVersion,
                deviceName: Self.deviceName)
        } else {
            coordinator = nil
        }
    }

    /// The newest *other-device*, version-compatible session among the library's games, resolved to a
    /// local `Game`. Returns nil when iCloud is unavailable, nothing's resumable, or the only sessions
    /// are for ROMs this Mac doesn't have. Cheap: fetches cards (metadata + thumbnail) only, never the
    /// savestate. Runs off the main actor.
    func newestResumable(in games: [Game]) async -> CrossDeviceContinue? {
        guard let coordinator else { return nil }
        var best: CrossDeviceContinue?
        for game in games {
            guard let card = try? await coordinator.card(forRomHash: game.romHash),
                  card.isRestorable(byCoreVersion: Self.coreVersion),
                  card.metadata.deviceName != Self.deviceName   // skip our own sessions
            else { continue }
            if best == nil || card.metadata.timestamp > best!.card.metadata.timestamp {
                best = CrossDeviceContinue(game: game, card: card)
            }
        }
        return best
    }

    /// Download the savestate to resume a game, honoring the exact-match core-version gate. Nil if the
    /// session vanished, is incompatible, or iCloud is unavailable. Runs off the main actor.
    func resumeState(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.resumeState(forRomHash: romHash)
    }

    /// Drop a session after it's been resumed here, so it isn't offered again once this Mac holds the
    /// live state. Best-effort — a failure just means the card lingers until the next publish.
    func clear(romHash: String) async {
        try? await coordinator?.clear(romHash: romHash)
    }

    // MARK: - ROM transfer (opt-in, ephemeral)

    /// Whether the user has allowed copying game files between their own devices. Off by default — the
    /// About screen explains it's for games you own, kept only in your private iCloud, and deleted the
    /// moment the other device receives it.
    static let transferDefaultsKey = "continuity.transferEnabled"
    static var transferEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: transferDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: transferDefaultsKey) }
    }

    /// Offer a game's ROM so a device that lacks it can receive and import it — only when the user has
    /// opted in. Called from the immediate publish path (returning to library / quit), not the debounced
    /// one, so the multi-MB upload happens on terminal moments rather than during play. No-op otherwise.
    func offerROMIfEnabled(game: Game) async {
        guard Self.transferEnabled, let coordinator else { return }
        guard let data = try? Data(contentsOf: game.romURL) else { return }
        let fileName = game.romURL.lastPathComponent
        // Ship our cached box art so the receiver shows the exact same cover (ROMs stored under a
        // content-hash filename won't re-match the thumbnail repo on the other device).
        let coverPNG = CoverArtService().cachedCoverURL(hash: game.romHash).flatMap { try? Data(contentsOf: $0) }
        try? await coordinator.publishROM(romHash: game.romHash, fileName: fileName, coverPNG: coverPNG, data: data)
    }

    /// The newest session for a game this Mac doesn't own but whose source device has offered the ROM.
    /// Nil when iCloud is unavailable, nothing's transferable, or every offer is for a game we already
    /// have. Excludes our own device's sessions.
    func newestTransferOffer(excluding owned: [Game]) async -> CrossDeviceTransfer? {
        guard let coordinator else { return nil }
        let ownedHashes = Set(owned.map(\.romHash))
        let cards = (try? await coordinator.allCards()) ?? []
        var best: CrossDeviceTransfer?
        for card in cards where !ownedHashes.contains(card.metadata.romHash)
            && card.metadata.deviceName != Self.deviceName {
            guard let fileName = try? await coordinator.romOffer(forRomHash: card.metadata.romHash)
            else { continue }
            let offer = CrossDeviceTransfer(card: card, fileName: fileName)
            if best == nil || offer.card.metadata.timestamp > best!.card.metadata.timestamp {
                best = offer
            }
        }
        return best
    }

    /// Download the offered ROM bytes for a transfer, or nil if the offer vanished. Runs off the main
    /// actor. The caller imports the ROM, then calls `clearROM` to make the cloud copy ephemeral.
    func downloadROM(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.fetchROM(forRomHash: romHash)
    }

    /// Drop the ROM offer once it's been received here, so it doesn't linger in iCloud.
    func clearROM(romHash: String) async {
        try? await coordinator?.clearROM(romHash: romHash)
    }

    // MARK: - Publishing (this Mac's sessions → other devices)

    /// Publish a session so other devices can continue it. Immediate and awaitable — use on terminal
    /// moments (returning to the library, quitting). No-op without usable iCloud.
    func publish(game: Game, state: Data, thumbnailPNG: Data?, secondsPlayed: Int) async {
        guard let coordinator else { return }
        let metadata = await coordinator.makeMetadata(
            romHash: game.romHash, romTitle: game.displayTitle, secondsPlayed: secondsPlayed)
        try? await coordinator.publish(
            ContinuitySnapshot(metadata: metadata, state: state, thumbnailPNG: thumbnailPNG))
    }

    /// Publish after a short quiet interval, superseding any earlier scheduled publish. Use on bursty
    /// events (the app resigning active) so only the latest snapshot reaches iCloud. Fire-and-forget.
    func schedulePublish(game: Game, state: Data, thumbnailPNG: Data?, secondsPlayed: Int) {
        guard let coordinator else { return }
        Task {
            let metadata = await coordinator.makeMetadata(
                romHash: game.romHash, romTitle: game.displayTitle, secondsPlayed: secondsPlayed)
            await coordinator.schedulePublish(
                ContinuitySnapshot(metadata: metadata, state: state, thumbnailPNG: thumbnailPNG))
        }
    }

    // MARK: - iCloud availability

    /// Whether it's safe to construct the CloudKit store. Requires an iCloud sign-in *and* the
    /// container actually granted to this build. `CKContainer(identifier:)` traps (uncatchable) when
    /// the container isn't in the app's entitlements — the case for unsigned/dev builds — so we check
    /// the granted entitlement first. Unlike iOS, macOS exposes `SecTaskCopyValueForEntitlement`, so
    /// we read the running process's entitlements directly instead of parsing a provisioning profile.
    static var cloudKitUsable: Bool {
        FileManager.default.ubiquityIdentityToken != nil && hasCloudContainerEntitlement
    }

    private static var hasCloudContainerEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        guard let ids = value as? [String] else { return false }
        return ids.contains(cloudContainer)
    }
}
