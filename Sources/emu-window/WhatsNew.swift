import AppKit

/// The "What's new" card shown once, on the first launch after an update — the opening panel modelled
/// on the companion RSS reader. It lists the highlights of the running build as a themed card over the
/// library (same chrome as `AppAlert`), then gets out of the way.
///
/// How it works: `UserDefaults` remembers the last version whose notes were seen
/// (`lastSeenWhatsNewVersion`). On launch, if that differs from the running version, the card appears
/// and the marker advances — so it shows exactly once per build, and **any** version bump re-triggers
/// it. A genuine fresh install (no marker yet) records the version silently; a brand-new player hasn't
/// "updated" to anything.
///
/// To ship notes for a release: bump the app's version as usual, then rewrite `items` to describe what
/// changed. Nothing else to wire.
@MainActor
enum WhatsNew {
    /// The build these notes describe — the running app version, so a version bump alone re-shows them.
    /// `nil` on an unbundled dev build (no `CFBundleShortVersionString`), where the card stays dormant.
    static var version: String? { UpdateChecker.currentVersion }

    private static let lastSeenKey = "lastSeenWhatsNewVersion"

    /// The highlights of the latest update. Keep it short — three or four lines.
    static let items: [AppAlert.Feature] = [
        AppAlert.Feature(
            symbol: "iphone.and.arrow.forward",
            title: "Send games across devices",
            detail: "Send a game — or a whole pack at once — to your other devices through your own private iCloud. It arrives ready to play, saves and all, then the copy is deleted."
        ),
        AppAlert.Feature(
            symbol: "arrow.down.circle",
            title: "Incoming games, made clear",
            detail: "A distinct blue “Receive” card shows a game waiting to be brought over — separate from your Continue prompts, so you always know what’s a new game versus a resume."
        ),
        AppAlert.Feature(
            symbol: "sparkles",
            title: "A little more delight",
            detail: "Cartridges launch toward the cloud when you send and drop away when you delete — each with its own sound."
        ),
    ]

    /// Show the notes once per build over `window`. Returns whether the card was actually presented, so
    /// the caller can avoid stacking a second launch panel on top of it.
    @discardableResult
    static func maybeShow(in window: NSWindow?) -> Bool {
        guard let version else { return false }   // dev build — nothing to show
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: lastSeenKey)
        defaults.set(version, forKey: lastSeenKey)   // advance the marker either way

        // nil marker = fresh install (skip); same version = already seen; empty notes = nothing to say.
        guard let last, last != version, !items.isEmpty else { return false }

        return present(in: window)
    }

    /// Show the notes on demand — the same card `maybeShow` presents on launch, but ignoring the
    /// once-per-build marker. Wired to the "Release Notes" button in Settings ▸ About so the highlights
    /// are always re-readable. No-op (returns false) on a dev build with no version to describe.
    @discardableResult
    static func present(in window: NSWindow?) -> Bool {
        guard let version else { return false }
        return AppAlert.present(in: window,
            symbol: nil,
            title: "What’s New",
            message: "Version \(version)",
            features: items,
            actions: [AppAlert.Action(title: "Continue", isDefault: true, isCancel: true)])
    }
}
