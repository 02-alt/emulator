import Foundation
import Observation
import UIKit
import LibraryKit
import ContinuityKit
import GBACore

/// App-facing Continuity: wraps `ContinuityKit.ContinuityCoordinator` and surfaces the single newest
/// resumable session as `banner` for the library to show "Continue where you left off".
///
/// Backed by `LocalContinuityStore` today (single-device, persistent). For true cross-device resume,
/// construct the coordinator with `CloudKitContinuityStore(containerIdentifier:)` and add the iCloud
/// capability — nothing else here changes.
@MainActor
@Observable
final class ContinuityService {
    /// Identifies this build's savestate format, derived from the linked libmgba so it matches the
    /// macOS app byte-for-byte (see `MGBACore.coreVersion`). Snapshots from a different build are
    /// refused rather than crashing `loadState`.
    static let coreVersion = MGBACore.coreVersion

    /// The app's CloudKit container (must match the iCloud entitlement in EmulatorApp.entitlements).
    static let cloudContainer = "iCloud.com.buildtoberemembered.encore"

    /// Whether it's safe to construct the CloudKit store. `CKContainer(identifier:)` *traps* (an
    /// uncatchable SIGTRAP) when the container isn't provisioned in the signed app — which is always
    /// the case for unsigned simulator builds, and also for device builds signed with a free/personal
    /// provisioning profile that silently strips the iCloud capability even though the container is
    /// listed in EmulatorApp.entitlements. So we require ALL of: a real device, a signed-in iCloud
    /// account, and the container actually granted in the running app's entitlements. Otherwise the
    /// local store carries single-device resume.
    static var cloudKitUsable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return FileManager.default.ubiquityIdentityToken != nil && hasCloudContainerEntitlement
        #endif
    }

    /// Whether our iCloud container is actually *granted* to this build, read from the embedded
    /// provisioning profile. A free/personal profile drops the iCloud capability at signing even though
    /// the container is listed in EmulatorApp.entitlements, so the container we'd hand to
    /// `CKContainer(identifier:)` isn't really present and constructing it would trap. Checking the
    /// granted entitlement first is the only reliable way to avoid that uncatchable crash on device.
    ///
    /// (iOS has no public API to read your own entitlements — `SecTaskCopyValueForEntitlement` is
    /// macOS-only — so we parse `embedded.mobileprovision`. App Store / TestFlight builds ship without
    /// that file; those are properly provisioned by definition, so absence means "trust it".)
    private static var hasCloudContainerEntitlement: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return true   // no embedded profile → distribution build, provisioned by definition
        }
        // The profile is a CMS blob wrapping a plaintext XML plist; slice the plist out and parse it.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<plist"), let end = text.range(of: "</plist>") else {
            return false
        }
        guard let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let profile = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let ids = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return ids.contains(cloudContainer)
    }

    private let coordinator: ContinuityCoordinator

    /// The newest resumable session across the library, or nil. Drives auto-resume and is the head
    /// of `recentSessions`.
    private(set) var banner: ContinuityCard?

    /// The most recent resumable sessions across the whole library, newest first, cross-device merged
    /// (a session from another device wins when iCloud has fresher data). Drives the "Continue Playing"
    /// strip so a game paused on the phone *and* one paused on the Mac are both one tap away.
    private(set) var recentSessions: [ContinuityCard] = []

    /// How many sessions the Continue strip shows before it stops growing.
    private static let recentLimit = 8

    /// A label for where a session was last played, or nil when it was this very device — used to tag
    /// a cross-device card ("MacBook Pro · 5m ago") so you know which hardware you're resuming from.
    func sourceLabel(for card: ContinuityCard) -> String? {
        card.metadata.deviceName == UIDevice.current.name ? nil : card.metadata.deviceName
    }

    init() {
        // Local + iCloud mirror where iCloud is usable, else local-only. We gate on the iCloud
        // sign-in token because `CKContainer(identifier:)` *traps* (not a catchable error) when the
        // container isn't in the app's entitlements — which is the case on the simulator / unsigned
        // builds. So we only construct the CloudKit store when iCloud is actually available; the
        // local half always carries single-device resume.
        let local = LocalContinuityStore()
        let store: ContinuityStore
        if Self.cloudKitUsable {
            store = MirroringContinuityStore(
                local: local,
                cloud: CloudKitContinuityStore(containerIdentifier: Self.cloudContainer,
                                               deviceName: UIDevice.current.name))
        } else {
            store = local
        }
        coordinator = ContinuityCoordinator(
            store: store,
            coreVersion: Self.coreVersion,
            deviceName: UIDevice.current.name)
    }

    /// Publish a session for a game. Called when a game backgrounds or is quit — terminal events, so
    /// we publish immediately (not debounced) and update `banner` right away so returning to the
    /// library shows Continue without waiting on a re-fetch.
    func publish(game: Game, state: Data, thumbnailPNG: Data?, secondsPlayed: Int = 0) async {
        let metadata = await coordinator.makeMetadata(
            romHash: game.romHash, romTitle: game.displayTitle, secondsPlayed: secondsPlayed)
        try? await coordinator.publish(
            ContinuitySnapshot(metadata: metadata, state: state, thumbnailPNG: thumbnailPNG))
        let card = ContinuityCard(metadata: metadata, thumbnailPNG: thumbnailPNG)
        banner = card
        // Float this game to the head of the strip immediately, without waiting on a re-fetch.
        recentSessions.removeAll { $0.metadata.romHash == card.metadata.romHash }
        recentSessions.insert(card, at: 0)
        recentSessions = Array(recentSessions.prefix(Self.recentLimit))
    }

    /// The savestate to resume a game, honoring the core-version gate. Nil if none / incompatible.
    func resumeState(romHash: String) async -> Data? {
        try? await coordinator.resumeState(forRomHash: romHash)
    }

    /// Recompute the Continue strip: every resumable card among the library's games, newest first
    /// (cross-device merged by the store). `banner` is the head of that list.
    func refreshBanner(for games: [Game]) async {
        var cards: [ContinuityCard] = []
        for game in games {
            if let card = try? await coordinator.card(forRomHash: game.romHash) {
                cards.append(card)
            }
        }
        cards.sort { $0.metadata.timestamp > $1.metadata.timestamp }
        recentSessions = Array(cards.prefix(Self.recentLimit))
        banner = cards.first
    }

    func clear(romHash: String) async {
        try? await coordinator.clear(romHash: romHash)
        recentSessions.removeAll { $0.metadata.romHash == romHash }
        if banner?.metadata.romHash == romHash { banner = recentSessions.first }
    }

    // MARK: - ROM transfer (opt-in, ephemeral)

    /// Every game shared to this device that it doesn't already have, newest first — so the UI can
    /// offer to receive them as a **pack** in one tap. See About ▸ Handoff for the opt-in and privacy.
    private(set) var pendingTransfers: [(card: ContinuityCard, fileName: String)] = []

    /// The newest pending transfer, for callers that handle one at a time.
    var transferOffer: (card: ContinuityCard, fileName: String)? { pendingTransfers.first }

    /// Offers the user waved away this run (keyed by game + offer time), so a dismissed pack stays gone
    /// — but a *newer* send for the same game (newer timestamp → new key) surfaces again. Not persisted.
    private var dismissedTransfers = Set<String>()
    private func transferKey(_ romHash: String, _ timestamp: Date) -> String {
        "\(romHash)|\(timestamp.timeIntervalSince1970)"
    }

    /// Dismiss the whole pending pack (long-press ▸ Dismiss) — hides every current offer without
    /// downloading, and remembers them so they don't reappear until re-sent.
    func dismissPendingTransfers() {
        for item in pendingTransfers {
            dismissedTransfers.insert(transferKey(item.card.metadata.romHash, item.card.metadata.timestamp))
        }
        pendingTransfers = []
    }

    /// Offer a game's ROM so another of the user's devices lacking it can receive and import it — only
    /// when the user opted in. Called from the publish path (a terminal moment). No-op otherwise.
    func offerROMIfEnabled(game: Game) async {
        guard AppSettings.transferEnabled else { return }
        await offerROM(game: game)
    }

    /// A clean, filesystem-safe "<title>.<ext>" filename for an outgoing ROM offer, so the receiver
    /// shows the real game title (not a content hash) and imports with a tidy name. Falls back to the
    /// on-disk filename if the title is empty or has no usable extension.
    static func offerFileName(for game: Game) -> String {
        let ext = game.romURL.pathExtension
        let safe = game.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty || ext.isEmpty) ? game.romURL.lastPathComponent : "\(safe).\(ext)"
    }

    /// Actively offer a game's ROM to the user's other devices now — the "Send to My Devices" gesture.
    /// `targetDevice` addresses one device by name (from ``sendTargets()``); nil broadcasts to all.
    /// Ungated (the caller is responsible for consent/ownership); returns whether the offer was made.
    @discardableResult
    func offerROM(game: Game, targetDevice: String? = nil) async -> Bool {
        guard let data = try? Data(contentsOf: game.romURL) else { return false }
        // Send a clean, title-based filename (ROMs are stored under a content-hash name, so the raw
        // filename is a hash — the receiver would show that hash as the game's title). The extension is
        // preserved: it drives the receiver's GBA/GBC system detection.
        let fileName = Self.offerFileName(for: game)
        // Include our cached box art so the receiver shows matching cover without re-matching a
        // (possibly cleaned/region-less) title against the thumbnail repo.
        let coverPNG = try? Data(contentsOf: AppPaths.coversDir.appendingPathComponent("\(game.romHash).png"))
        do {
            try await coordinator.publishROM(
                romHash: game.romHash, fileName: fileName, coverPNG: coverPNG, data: data, targetDevice: targetDevice)
            // Ride the player's cartridge save along with the game so the receiver continues their
            // progress rather than a blank save. Best-effort — a missing/failed battery just means a
            // fresh cartridge on the other end, exactly as before.
            let batteryURL = SavePaths.directory(forHash: game.romHash).appendingPathComponent("battery.sav")
            if let battery = try? Data(contentsOf: batteryURL), !battery.isEmpty {
                try? await coordinator.publishROMBattery(romHash: game.romHash, data: battery)
            }
            return true
        } catch {
            NSLog("[Encore] Send failed — cloudKitUsable=\(Self.cloudKitUsable) error=\(error)")
            return false
        }
    }

    /// The user's other devices (by name) that can be a send target — those that have published a
    /// session. Empty until another device shows up, in which case "Send" is a plain broadcast.
    func sendTargets() async -> [String] {
        (try? await coordinator.otherDeviceNames()) ?? []
    }

    /// Recompute `pendingTransfers`: every game shared to this device that it doesn't already have,
    /// newest first, discovered directly from ROM offers (no companion snapshot needed). Cheap — never
    /// downloads the ROM bytes.
    func refreshTransferOffer(for games: [Game]) async {
        let ownedHashes = Set(games.map(\.romHash))
        let ownedTitles = Set(games.map { $0.displayTitle.lowercased().trimmingCharacters(in: .whitespaces) })
        let offers = (try? await coordinator.romOffers()) ?? []   // newest-first, addressed to us
        // Collapse into a single de-duplicated pack: one entry per game, keyed by ROM hash *and* by
        // title. Skips games we already own (by hash or title), and shows the same game offered more
        // than once (across separate sends, or two dumps of one title) only once — newest wins.
        var seenHash = Set<String>()
        var seenTitle = Set<String>()
        pendingTransfers = offers.compactMap { offer -> (card: ContinuityCard, fileName: String)? in
            // Drop offers this device can't play (e.g. a PS1 disc sent from the Mac) — iOS has no
            // PlayStation core, so accepting one would only land an unplayable game on the phone.
            guard GameSystem.isPlayableOnIOS(extension: (offer.fileName as NSString).pathExtension)
            else { return nil }
            guard !ownedHashes.contains(offer.romHash) else { return nil }
            guard !dismissedTransfers.contains(transferKey(offer.romHash, offer.timestamp)) else { return nil }
            let title = (offer.fileName as NSString).deletingPathExtension
            let titleKey = title.lowercased().trimmingCharacters(in: .whitespaces)
            guard !ownedTitles.contains(titleKey) else { return nil }   // already have this game by title
            guard seenHash.insert(offer.romHash).inserted,
                  titleKey.isEmpty || seenTitle.insert(titleKey).inserted else { return nil }
            let card = ContinuityCard(metadata: ContinuityMetadata(
                romHash: offer.romHash, romTitle: title, timestamp: offer.timestamp,
                deviceName: offer.deviceName, secondsPlayed: 0, coreVersion: Self.coreVersion))
            return (card, offer.fileName)
        }
    }

    /// Download the offered ROM bytes for a transfer, or nil if the offer vanished.
    func downloadROM(romHash: String) async -> Data? {
        try? await coordinator.fetchROM(forRomHash: romHash)
    }

    /// Download the sender's box art for a transfer, or nil if none was included.
    func downloadROMCover(romHash: String) async -> Data? {
        try? await coordinator.fetchROMCover(forRomHash: romHash)
    }

    /// Download the sender's cartridge save for a transfer, or nil if none rode along.
    func downloadROMBattery(romHash: String) async -> Data? {
        try? await coordinator.fetchROMBattery(forRomHash: romHash)
    }

    /// Drop the ROM offer once it's been received here, so the cloud copy stays ephemeral.
    func clearROM(romHash: String) async {
        try? await coordinator.clearROM(romHash: romHash)
        pendingTransfers.removeAll { $0.card.metadata.romHash == romHash }
    }
}
