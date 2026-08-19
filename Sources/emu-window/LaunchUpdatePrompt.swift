import AppKit

/// On launch, quietly asks GitHub Releases whether a newer build exists and — if one does — offers it
/// in a themed card over the library. The companion to the manual "Check for Updates" button in
/// Settings; both run the same `UpdateChecker`. Silent on failure and when up to date, so a normal
/// launch shows nothing.
@MainActor
enum LaunchUpdatePrompt {
    /// Check for a newer release and, if found, present the offer over `window`. No-op on dev builds
    /// (no bundle version to compare) and whenever another card is already up, so launch panels never
    /// stack — a deferred offer simply reappears next launch.
    static func checkAndPrompt(in window: NSWindow?) {
        guard let current = UpdateChecker.currentVersion else { return }   // unbundled dev build
        Task { @MainActor in
            guard case let .available(version, url) = await UpdateChecker.check(current: current) else { return }
            guard let host = window?.contentView,
                  !host.subviews.contains(where: { $0 is AppAlert }) else { return }
            AppAlert.present(in: window,
                symbol: "arrow.down.circle",
                title: "Update Available",
                message: "Version \(version) is available — you’re on \(current).",
                actions: [
                    AppAlert.Action(title: "Later", isCancel: true),
                    AppAlert.Action(title: "Download", isDefault: true) {
                        NSWorkspace.shared.open(url)
                    },
                ])
        }
    }
}
