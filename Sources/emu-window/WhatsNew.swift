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
            symbol: "opticaldisc",
            title: "PlayStation comes to the shelf",
            detail: "Bring your own PS1 discs and they take their place beside the cartridges — as playable CDs. A one-time setup with your console’s BIOS, a controller in hand, and you’re in. Multi-disc games swap discs on their own."
        ),
        AppAlert.Feature(
            symbol: "sparkles",
            title: "Sharper than 1999",
            detail: "PlayStation 3D is redrawn at a higher internal resolution with the classic polygon wobble smoothed away — the games you remember, only crisper. An optional hardware renderer (Settings ▸ Video) pushes it to 4× on Apple Silicon at full speed; widescreen too."
        ),
        AppAlert.Feature(
            symbol: "memorychip",
            title: "A memory card of its own",
            detail: "Every PlayStation game keeps its own memory card, wearing that game’s cover — with the real save blocks and their little pixel icons, just like the originals."
        ),
        AppAlert.Feature(
            symbol: "trophy",
            title: "Trophies, on disc too",
            detail: "RetroAchievements now recognises your PlayStation games, so the same challenges and progress you know from the cartridges are here as well."
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
