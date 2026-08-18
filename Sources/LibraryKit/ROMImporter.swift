import Foundation

/// Turns a ROM file on disk into a `Game`: hashes it for identity and derives a clean title.
public enum ROMImporter {
    /// GBA cartridges.
    public static let supportedExtensions: Set<String> = ["gba"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func makeGame(from url: URL, shelfIndex: Int = 0, slotIndex: Int = 0) throws -> Game {
        let stem = url.deletingPathExtension().lastPathComponent
        return Game(
            title: cleanTitle(stem),
            romFilenameStem: stem,
            romPath: url.path,
            romHash: try identityHash(for: url),
            shelfIndex: shelfIndex,
            slotIndex: slotIndex)
    }

    /// Identity hash. GBA carts are small, so hash the whole file.
    private static func identityHash(for url: URL) throws -> String {
        try Data(contentsOf: url).sha256Hex(prefix: 16)
    }

    /// "Pokemon - Emerald Version (USA, Europe)" → "Pokemon - Emerald Version".
    /// Strips (…)/[…] tags, turns underscores into spaces, collapses whitespace.
    public static func cleanTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(
            of: #"[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "_", with: " ")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
