import SwiftUI

/// A transient in-app banner — the iOS counterpart to the macOS `TrophyNotifier` + `TrophyPop`.
/// Post one from anywhere via ``AppNotifier/shared``; it eases down from the top of the screen,
/// holds briefly, then fades away, and never blocks touches to the game or shelf beneath it.
struct InAppNotification: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: Color
    var caption: String     // small uppercase kicker, e.g. "Trophy Unlocked"
    var title: String       // the message line

    /// A soft-gold trophy unlock, matching the macOS banner.
    static func trophy(title: String, points: Int) -> InAppNotification {
        InAppNotification(
            symbol: "trophy.fill",
            tint: Color(red: 0.97, green: 0.82, blue: 0.38),   // soft gold
            caption: "Trophy Unlocked",
            title: points > 0 ? "\(title) · \(points) pts" : title)
    }

    /// A neutral informational banner.
    static func info(_ title: String, symbol: String = "bell.fill", caption: String = "Encore") -> InAppNotification {
        InAppNotification(symbol: symbol, tint: .white, caption: caption, title: title)
    }
}

/// The delivery layer for in-app banners — the iOS mirror of the macOS `TrophyNotifier`. Holds the
/// one banner currently on screen (a new post replaces it) and auto-dismisses after a short hold.
/// The **source** of trophy unlocks (the rcheevos engine that watches game memory) is the follow-up
/// that will call ``trophyUnlocked(title:points:)`` during play; today it's driven by the Settings
/// preview, exactly as on macOS.
@MainActor
@Observable
final class AppNotifier {
    static let shared = AppNotifier()
    private init() {}

    private(set) var current: InAppNotification?
    private var dismissTask: Task<Void, Never>?

    /// Show a banner (replacing any that's already up), with a success haptic when haptics are on.
    func post(_ note: InAppNotification, haptic: Bool = true) {
        current = note
        if haptic && AppSettings.haptics {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    /// Announce a trophy unlock, gated on the user's setting — mirrors `TrophyNotifier.unlocked`.
    func trophyUnlocked(title: String, points: Int) {
        guard AppSettings.trophyNotifications else { return }
        post(.trophy(title: title, points: points))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// The overlay that renders whatever ``AppNotifier/shared`` is currently showing. Placed once, at
/// the top of the app's view tree, above everything else. Empty space passes touches through; only
/// the banner itself is tappable (tap to dismiss).
struct NotificationBannerHost: View {
    @State private var notifier = AppNotifier.shared

    var body: some View {
        VStack(spacing: 0) {
            if let note = notifier.current {
                NotificationBanner(note: note)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .onTapGesture { notifier.dismiss() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: notifier.current)
    }
}

/// The banner card: a small icon, an uppercase kicker, and the message, on a glassy capsule.
private struct NotificationBanner: View {
    let note: InAppNotification

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: note.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(note.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.caption.uppercased())
                    .font(DS.mono(9, .medium))
                    .tracking(0.6)
                    .foregroundStyle(DS.textTertiary)
                Text(note.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.hairline))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
    }
}
