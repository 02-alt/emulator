import AppKit
import Foundation
import UserNotifications

/// Delivers a native "trophy unlocked" banner for a RetroAchievement, gated on the user's setting and
/// on notification authorization. This is the **delivery layer** — call ``unlocked(title:points:game:)``
/// from wherever an unlock is detected. Today that's a manual test; the live source (the rcheevos
/// engine that watches game memory and reports unlocks to RetroAchievements) is the follow-up that
/// will call it during play.
///
/// No-op in an unbundled dev build: `UNUserNotificationCenter` needs a real app bundle, so banners only
/// appear in the packaged `Encore.app` (or after `swift build` is wrapped by `scripts/release.sh`).
@MainActor
enum TrophyNotifier {
    /// Whether we're in a real app bundle (a prerequisite for `UNUserNotificationCenter`).
    private static var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Ask for notification permission — called when the user turns the setting on, and before the
    /// first unlock. Safe to call repeatedly.
    static func requestAuthorization() {
        guard bundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Announce a trophy unlock (if enabled): a subtle in-app pop + chime in the app window, plus a
    /// native system banner when running as a bundle (so you see it even with the app in the background).
    static func unlocked(title: String, points: Int, game: String) {
        guard Settings.shared.trophyNotifications else { return }

        // In-app pop + chime — works everywhere (no bundle needed). Prefer the focused window (the
        // play window during a game, or Settings when testing), else the library/play window.
        let host = NSApp.keyWindow ?? NSApp.windows.first { w in
            w.isVisible && (w.contentView is LibraryDashboardView || w.contentView is PlayVoidView)
        }
        TrophyPop.show(in: host, title: title, points: points)
        SoundFX.shared.playTrophy()

        // Native banner (needs a real app bundle).
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "🏆 Trophy unlocked"
        content.subtitle = game
        content.body = points > 0 ? "\(title) · \(points) pts" : title
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Fire a sample banner so the user can grant permission and see how it looks (Settings button).
    static func sendTest() {
        requestAuthorization()
        unlocked(title: "Nice! Got the hang of it", points: 5, game: "RetroAchievements")
    }
}
