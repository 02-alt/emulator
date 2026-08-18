import Foundation

/// A console this app can emulate. 1.0 ships GBA; the enum is where future consoles land.
public enum EmulatedSystem: String, Sendable, CaseIterable {
    case gba

    /// Native output resolution of the system's screen.
    public var nativeResolution: (width: Int, height: Int) {
        switch self {
        case .gba: return (240, 160)
        }
    }

    /// Nominal refresh rate in Hz. GBA is ~59.7275, not a clean 60.
    public var refreshRate: Double {
        switch self {
        case .gba: return 59.7275
        }
    }

    public var displayName: String {
        switch self {
        case .gba: return "Game Boy Advance"
        }
    }
}
