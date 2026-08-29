import LibraryKit

/// Which consoles *this* (iOS) build can actually run. iOS ships only the mGBA core (GBA + Game Boy /
/// Color); the PlayStation core is macOS-only. The shared `GameSystem` enum still carries `.ps1` so the
/// two apps share one library/transfer format, so the iOS app has to filter PS1 out at its edges —
/// the Files importer and incoming Continuity offers — or an unplayable disc lands on the phone.
extension GameSystem {
    /// The systems the iOS app can boot. Everything else is filtered at import / offer time.
    static let iosPlayable: [GameSystem] = [.gba, .gbc]

    var isPlayableOnIOS: Bool { Self.iosPlayable.contains(self) }

    /// Lowercased file extensions for the iOS-playable systems.
    static let iosPlayableExtensions: Set<String> = Set(iosPlayable.flatMap(\.fileExtensions))

    /// Whether a file extension maps to a system iOS can run.
    static func isPlayableOnIOS(extension ext: String) -> Bool {
        iosPlayableExtensions.contains(ext.lowercased())
    }
}
