import Foundation

/// A console this app can emulate. 1.0 ships GBA; the enum is where future consoles land.
public enum EmulatedSystem: String, Sendable, CaseIterable {
    case gba
    case gbc
    case ps1

    /// Native output resolution of the system's screen. The PS1 renders at a size that changes per
    /// frame (256..640 wide, interlacing); the value here is its most common mode and a nominal
    /// aspect reference — live cores report their real per-frame size via `videoSize`.
    public var nativeResolution: (width: Int, height: Int) {
        switch self {
        case .gba: return (240, 160)
        case .gbc: return (160, 144)
        case .ps1: return (320, 240)
        }
    }

    /// Nominal refresh rate in Hz. GBA/GBC run at ~59.7275; the PS1 is ~59.94 (NTSC).
    public var refreshRate: Double {
        switch self {
        case .gba, .gbc: return 59.7275
        case .ps1: return 59.94
        }
    }

    public var displayName: String {
        switch self {
        case .gba: return "Game Boy Advance"
        case .gbc: return "Game Boy Color"
        case .ps1: return "PlayStation"
        }
    }
}
