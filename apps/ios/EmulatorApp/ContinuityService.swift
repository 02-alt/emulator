import Foundation
import Observation
import UIKit
import LibraryKit
import ContinuityKit

/// App-facing Continuity: wraps `ContinuityKit.ContinuityCoordinator` and surfaces the single newest
/// resumable session as `banner` for the library to show "Continue where you left off".
///
/// Backed by `LocalContinuityStore` today (single-device, persistent). For true cross-device resume,
/// construct the coordinator with `CloudKitContinuityStore(containerIdentifier:)` and add the iCloud
/// capability — nothing else here changes.
@MainActor
@Observable
final class ContinuityService {
    /// Identifies this build's savestate format. Bump when the core (or its state layout) changes so
    /// stale snapshots from an old build are refused rather than crashing `loadState`.
    static let coreVersion = "mgba-0.10.5"

    /// The app's CloudKit container (must match the iCloud entitlement in EmulatorApp.entitlements).
    static let cloudContainer = "iCloud.com.comalada.gbaemulator"

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

    /// The newest resumable session across the library, or nil. Drives the Continue banner.
    private(set) var banner: ContinuityCard?

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
                cloud: CloudKitContinuityStore(containerIdentifier: Self.cloudContainer))
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
        banner = ContinuityCard(metadata: metadata, thumbnailPNG: thumbnailPNG)
    }

    /// The savestate to resume a game, honoring the core-version gate. Nil if none / incompatible.
    func resumeState(romHash: String) async -> Data? {
        try? await coordinator.resumeState(forRomHash: romHash)
    }

    /// Recompute the banner: the most recent card among the library's games.
    func refreshBanner(for games: [Game]) async {
        var newest: ContinuityCard?
        for game in games {
            if let card = try? await coordinator.card(forRomHash: game.romHash),
               newest == nil || card.metadata.timestamp > newest!.metadata.timestamp {
                newest = card
            }
        }
        banner = newest
    }

    func clear(romHash: String) async {
        try? await coordinator.clear(romHash: romHash)
        if banner?.metadata.romHash == romHash { banner = nil }
    }
}
