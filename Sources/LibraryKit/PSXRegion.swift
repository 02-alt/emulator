import Foundation

/// A PlayStation disc's release region — the three that map to a distinct console BIOS. Beetle PSX
/// auto-selects its BIOS by the disc's detected region, so covering all three lets every regional
/// game boot on its intended BIOS. Region-checking / anti-piracy titles need the exact match; most
/// others boot on whatever BIOS is present, but timing and a few checks want the right one.
public enum PSXRegion: String, CaseIterable, Sendable {
    case japan = "Japan"
    case america = "North America"
    case europe = "Europe"

    /// The region-canonical BIOS filename Beetle PSX looks for when it detects this region.
    public var biosFilename: String {
        switch self {
        case .japan:   return "scph5500.bin"
        case .america: return "scph5501.bin"
        case .europe:  return "scph5502.bin"
        }
    }

    /// A flag emoji for compact coverage UI.
    public var flag: String {
        switch self {
        case .japan:   return "🇯🇵"
        case .america: return "🇺🇸"
        case .europe:  return "🇪🇺"
        }
    }

    public var displayName: String { rawValue }

    /// The region of a PlayStation disc **serial / boot-executable name** (e.g. "SLES_015.06" →
    /// `.europe`). The serial's maker+region prefix is authoritative, unlike a filename tag which the
    /// user can rename to anything.
    public static func from(serial: String) -> PSXRegion? {
        let s = serial.uppercased()
        // US: SCUS/SLUS. EU: SCES/SLES/SCED/SLED. JP: SCPS/SLPS/SLPM/SIPS/PAPX/PCPX/SCZS.
        let prefixes: [(String, PSXRegion)] = [
            ("SCUS", .america), ("SLUS", .america),
            ("SCES", .europe), ("SLES", .europe), ("SCED", .europe), ("SLED", .europe),
            ("SCPS", .japan), ("SLPS", .japan), ("SLPM", .japan), ("SIPS", .japan),
            ("PAPX", .japan), ("PCPX", .japan), ("SCZS", .japan),
        ]
        return prefixes.first { s.hasPrefix($0.0) }?.1
    }

    /// Detect a disc image's region by reading its boot-executable serial from the ISO filesystem.
    /// Returns nil for formats we can't open (.chd/.pbp) or an unrecognized serial — callers should
    /// treat nil as "region unknown", not "region mismatch".
    public static func detect(disc url: URL) -> PSXRegion? {
        PSXDiscHash.bootExecutableName(for: url).flatMap { from(serial: $0) }
    }

    /// Map a canonical BIOS filename back to its region (for reporting which regions are installed).
    public static func of(biosFilename name: String) -> PSXRegion? {
        switch name.lowercased() {
        case "scph5500.bin", "scph1000.bin", "scph3000.bin", "scph3500.bin", "scph5000.bin", "scph7000.bin":
            return .japan
        case "scph5501.bin", "scph1001.bin", "scph7001.bin", "scph7003.bin", "scph101.bin":
            return .america
        case "scph5502.bin", "scph5552.bin", "scph7002.bin", "scph102a.bin", "scph102b.bin", "scph102.bin":
            return .europe
        default:
            return nil
        }
    }
}
