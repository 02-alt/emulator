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
                store: CloudKitContinuityStore(containerIdentifier: Self.cloudContainer,
                                               deviceName: Self.deviceName),
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
    /// Returns true only when a **new** offer was uploaded — so the caller can confirm "sent" exactly
    /// once. Returns false when transfer is off, iCloud is unusable, the ROM was already offered (we skip
    /// the multi-MB re-upload), or the upload failed.
    @discardableResult
    func offerROMIfEnabled(game: Game) async -> Bool {
        guard Self.transferEnabled, let coordinator else { return false }
        // Already offered? Skip the re-upload and the duplicate "sent" confirmation.
        if (try? await coordinator.romOffer(forRomHash: game.romHash)) != nil { return false }
        return await offerROM(game: game)
    }

    /// Actively offer a game's ROM to the user's other devices now — backs the "Send to My Devices"
    /// right-click. `targetDevice` addresses one device by name (from ``otherDeviceNames()``); nil
    /// broadcasts. Ungated (the caller handles ownership consent); returns whether the offer reached
    /// iCloud (false when iCloud is unavailable or the ROM can't be read).
    @discardableResult
    func offerROM(game: Game, targetDevice: String? = nil) async -> Bool {
        guard let coordinator else { return false }
        guard let data = try? Data(contentsOf: game.romURL) else { return false }
        // Send a clean, title-based filename (ROMs are stored under a content-hash name, so the raw
        // filename is a hash — the receiver would otherwise show that hash as the game's title). The
        // extension is preserved: it drives the receiver's GBA/GBC system detection.
        let ext = game.romURL.pathExtension
        let safeTitle = game.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeTitle.isEmpty || ext.isEmpty) ? game.romURL.lastPathComponent : "\(safeTitle).\(ext)"
        // Ship our cached box art so the receiver shows the exact same cover (ROMs stored under a
        // content-hash filename won't re-match the thumbnail repo on the other device).
        let coverPNG = CoverArtService().cachedCoverURL(hash: game.romHash).flatMap { try? Data(contentsOf: $0) }
        do {
            try await coordinator.publishROM(
                romHash: game.romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: targetDevice)
            // Ride the player's cartridge save along with the game so the receiver continues their
            // progress rather than a blank save. Best-effort — a missing/failed battery just means a
            // fresh cartridge on the other end.
            let batteryURL = SaveStore(romURL: game.romURL).batteryURL
            if let battery = try? Data(contentsOf: batteryURL), !battery.isEmpty {
                try? await coordinator.publishROMBattery(romHash: game.romHash, data: battery)
            }
            return true
        } catch {
            return false
        }
    }

    /// Offer just a game's save (e.g. a PS1 `.mcr`) — a standalone, tiny transfer for games whose ROM
    /// is too large to send. The caller supplies the save bytes (it owns the on-disk path logic).
    /// Returns whether the offer reached iCloud.
    @discardableResult
    func offerSave(game: Game, data: Data, targetDevice: String? = nil) async -> Bool {
        guard let coordinator else { return false }
        let coverPNG = CoverArtService().cachedCoverURL(hash: game.romHash).flatMap { try? Data(contentsOf: $0) }
        do {
            try await coordinator.publishSave(
                romHash: game.romHash, gameTitle: game.displayTitle, coverPNG: coverPNG,
                data: data, targetDevice: targetDevice)
            return true
        } catch {
            return false
        }
    }

    /// The newest save offer for a game this device *owns* (the mirror of ``newestTransferOffer`` — a
    /// save arrives for a game you already have, to update its memory card). Nil when none. Our own
    /// device's offers are already excluded by the coordinator.
    func newestSaveOffer(owned games: [Game]) async -> (game: Game, offer: SaveOffer)? {
        guard let coordinator else { return nil }
        let byHash = Dictionary(games.map { ($0.romHash, $0) }, uniquingKeysWith: { a, _ in a })
        let offers = (try? await coordinator.saveOffers()) ?? []
        for offer in offers where byHash[offer.romHash] != nil {
            return (byHash[offer.romHash]!, offer)
        }
        return nil
    }

    func downloadSave(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.fetchSave(forRomHash: romHash)
    }

    func clearSave(romHash: String) async {
        try? await coordinator?.clearSave(romHash: romHash)
    }

    /// The user's other devices (by name) that can be a send target — those that have published a
    /// session. Empty until another device shows up, in which case "Send" is a plain broadcast.
    func otherDeviceNames() async -> [String] {
        guard let coordinator else { return [] }
        return (try? await coordinator.otherDeviceNames()) ?? []
    }

    /// The newest session for a game this Mac doesn't own but whose source device has offered the ROM.
    /// Nil when iCloud is unavailable, nothing's transferable, or every offer is for a game we already
    /// have. Excludes our own device's sessions.
    func newestTransferOffer(excluding owned: [Game]) async -> CrossDeviceTransfer? {
        guard let coordinator else { return nil }
        let ownedHashes = Set(owned.map(\.romHash))
        // Discover ROM offers directly (newest-first, addressed to us or broadcast, our own excluded), so
        // a game shared to this Mac surfaces even when the sender never played it — no snapshot needed.
        let offers = (try? await coordinator.romOffers()) ?? []
        guard let offer = offers.first(where: { !ownedHashes.contains($0.romHash) }) else { return nil }
        return CrossDeviceTransfer(card: Self.card(from: offer), fileName: offer.fileName)
    }

    /// Synthesize a display card from a bare ROM offer (title from the filename), for the "Transfer
    /// from <device>" surface when no session snapshot rode along.
    private static func card(from offer: ROMOffer) -> ContinuityCard {
        let title = (offer.fileName as NSString).deletingPathExtension
        return ContinuityCard(metadata: ContinuityMetadata(
            romHash: offer.romHash, romTitle: title, timestamp: offer.timestamp,
            deviceName: offer.deviceName, secondsPlayed: 0, coreVersion: Self.coreVersion))
    }

    /// Download the offered ROM bytes for a transfer, or nil if the offer vanished. Runs off the main
    /// actor. The caller imports the ROM, then calls `clearROM` to make the cloud copy ephemeral.
    func downloadROM(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.fetchROM(forRomHash: romHash)
    }

    /// Download the offered box art for a transfer (small), or nil if none rode along. Lets the receiver
    /// show the exact cover the sender had and drive the arrival animation. Runs off the main actor.
    func downloadROMCover(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.fetchROMCover(forRomHash: romHash)
    }

    /// Download the offered cartridge save for a transfer, or nil if none rode along. Runs off the main
    /// actor. Fetch before `clearROM` — clearing deletes the whole offer record.
    func downloadROMBattery(romHash: String) async -> Data? {
        guard let coordinator else { return nil }
        return try? await coordinator.fetchROMBattery(forRomHash: romHash)
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
