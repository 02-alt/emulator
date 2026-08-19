import Foundation

/// One app release's notes: the version it shipped as, a short human-readable date, a one-line
/// headline, and the bullet-point highlights shown in the What's New panel and the Release Notes
/// history. Add a new entry at the top of ``ReleaseNotes/all`` for each shipped version — the
/// What's New panel then appears automatically on first launch after the update.
struct ReleaseNote: Identifiable {
    let version: String            // matches CFBundleShortVersionString, e.g. "1.0"
    let date: String               // display-only, e.g. "August 2026"
    let headline: String           // one-line summary of the release
    let highlights: [Highlight]

    var id: String { version }

    /// A single change in a release: an SF Symbol, a short title, and a plain-language detail.
    struct Highlight: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }
}

/// The curated catalogue of release notes, newest first.
enum ReleaseNotes {
    static let all: [ReleaseNote] = [
        ReleaseNote(
            version: "1.0",
            date: "August 2026",
            headline: "The first release of Encore GBA.",
            highlights: [
                .init(symbol: "gamecontroller.fill",
                      title: "Play your library",
                      detail: "A cartridge shelf with faithful Game Boy Advance emulation, on-screen controls, and full MFi, Xbox and DualSense controller support."),
                .init(symbol: "bolt.horizontal.fill",
                      title: "Continue anywhere",
                      detail: "Pick a game back up on another of your devices through your own private iCloud — never our servers."),
                .init(symbol: "trophy.fill",
                      title: "RetroAchievements",
                      detail: "Sign in to track trophies and story progress for each game, with an unlock banner the moment you earn one."),
                .init(symbol: "hand.raised.fill",
                      title: "Private by design",
                      detail: "No accounts, no analytics, no tracking. Your games, saves, and screenshots stay on your device."),
            ]),
    ]

    /// The newest release — the one the What's New panel presents.
    static var latest: ReleaseNote? { all.first }
}

/// First-launch gate for the What's New panel: remembers the last version whose notes the user has
/// seen, so the panel appears once per update (and on the very first launch) and never again.
enum WhatsNew {
    private static let key = "whatsnew.lastSeenVersion"
    private static let d = UserDefaults.standard

    /// The running app's marketing version (falls back to the catalogue's latest in dev builds).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ReleaseNotes.latest?.version ?? "1.0"
    }

    /// The release to show on launch, or `nil` if the user has already seen the current version's
    /// notes (or there are none to show).
    static func pending() -> ReleaseNote? {
        guard let latest = ReleaseNotes.latest else { return nil }
        return d.string(forKey: key) == currentVersion ? nil : latest
    }

    /// Remember that the current version's notes have been shown, so they don't reappear.
    static func markSeen() {
        d.set(currentVersion, forKey: key)
    }
}
