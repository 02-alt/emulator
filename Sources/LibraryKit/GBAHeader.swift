import Foundation

/// Parsed fields from a Game Boy Advance ROM's 192-byte header — a free, offline source of
/// Region / Publisher / Serial for the library detail panel. No network, no database.
///
/// Header layout: title at 0xA0 (12 bytes), game code at 0xAC (4 bytes, e.g. "BPRE"), maker code
/// at 0xB0 (2 bytes, e.g. "01"). The game code's 4th letter is the region; the maker code maps to
/// a licensee (publisher) via the standard Nintendo licensee table.
public struct GBAHeader: Sendable {
    public let internalTitle: String
    public let gameCode: String     // e.g. "BPRE"
    public let makerCode: String    // e.g. "01"

    /// AGB is the GBA product prefix on serials (e.g. "AGB-BPRE").
    public var serial: String { gameCode.isEmpty ? "" : "AGB-\(gameCode)" }

    public var region: String? {
        guard let last = gameCode.last else { return nil }
        return GBAHeader.regions[last]
    }

    public var publisher: String? {
        guard !makerCode.isEmpty else { return nil }
        return GBAHeader.publishers[makerCode] ?? makerCode   // fall back to the raw code
    }

    /// Read and validate a GBA header from a ROM file. Returns nil if the file isn't a plausible
    /// GBA image (too short, or the fixed 0x96 header-format byte at 0xB2 is wrong).
    public static func read(from url: URL) -> GBAHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 0xC0), data.count >= 0xC0 else { return nil }
        guard data[0xB2] == 0x96 else { return nil }   // fixed GBA header-format byte

        func text(_ start: Int, _ len: Int) -> String {
            let bytes = data.subdata(in: start..<(start + len)).filter { $0 >= 0x20 && $0 < 0x7F }
            return String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        return GBAHeader(internalTitle: text(0xA0, 12),
                         gameCode: text(0xAC, 4),
                         makerCode: text(0xB0, 2))
    }

    // MARK: - Lookups

    private static let regions: [Character: String] = [
        "J": "Japan", "E": "USA", "P": "Europe", "D": "Germany", "F": "France",
        "I": "Italy", "S": "Spain", "K": "Korea", "H": "Netherlands", "X": "Europe",
    ]

    /// A curated subset of the Nintendo licensee (maker) codes seen on GBA carts. Unknown codes
    /// fall back to the raw two characters.
    private static let publishers: [String: String] = [
        "01": "Nintendo", "08": "Capcom", "13": "Electronic Arts", "18": "Hudson Soft",
        "20": "Destination Software", "28": "Kemco", "32": "Bandai", "34": "Konami",
        "37": "Taito", "39": "Banpresto", "41": "Ubisoft", "42": "Atlus", "47": "Bullet-Proof",
        "49": "Irem", "51": "Acclaim", "52": "Activision", "54": "Konami", "56": "LJN",
        "5D": "Midway", "5F": "Infogrames", "60": "Titus", "64": "LucasArts", "69": "Electronic Arts",
        "6F": "Electro Brain", "70": "Infogrames", "71": "Interplay", "75": "SCi", "78": "THQ",
        "79": "Accolade", "7D": "Universal Interactive", "8P": "Sega", "99": "Pack-In-Video",
        "9B": "Tecmo", "9C": "Imagineer", "A4": "Konami", "A7": "Takara", "AF": "Namco",
        "B0": "Acclaim", "B2": "Bandai", "B4": "Enix", "BB": "Sunsoft", "BF": "Sammy",
        "C0": "Taito", "C3": "Square Enix", "C5": "Data East", "C8": "Koei", "D9": "Banpresto",
        "DA": "Tomy", "DB": "LJN", "E5": "Epoch", "E7": "Athena", "E8": "Asmik", "E9": "Natsume",
        "EB": "Atlus", "EC": "Epic/Sony", "FF": "LJN",
    ]
}
