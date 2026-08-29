import AppKit
import Sparkle

/// In-app auto-update (Sparkle). Downloads and installs new releases in place — no browser, no manual
/// drag — from the appcast feed declared in Info.plist (`SUFeedURL`), verified with the EdDSA public
/// key (`SUPublicEDKey`). One shared controller drives both the scheduled background checks and the
/// manual "Check for Updates…" action.
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    private var started = false

    private override init() {
        // Start lazily: an unbundled `swift run` dev build has no feed URL / public key, and starting
        // Sparkle then would pop an error alert. We only start once we know this is a configured bundle.
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    /// True when this build can auto-update: a bundled app with a feed URL configured in Info.plist.
    var isSupported: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// Begin scheduled background checks. Call once at launch; no-op on unbundled dev builds.
    func startIfSupported() {
        guard isSupported, !started else { return }
        controller.startUpdater()
        started = true
    }

    /// Manual "Check for Updates…": starts the updater if needed, then runs Sparkle's user-initiated
    /// flow (progress → release notes → install & relaunch), including a "you're up to date" result.
    func checkForUpdates() {
        guard isSupported else { return }
        startIfSupported()
        controller.checkForUpdates(nil)
    }

    /// Whether a manual check can run right now (for enabling the menu item / button).
    var canCheckForUpdates: Bool { isSupported && controller.updater.canCheckForUpdates }
}
