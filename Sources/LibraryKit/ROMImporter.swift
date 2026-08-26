import Foundation

/// Turns a ROM file on disk into a `Game`: hashes it for identity and derives a clean title.
public enum ROMImporter {
    /// Every ROM extension we can import, across all supported systems (GBA, Game Boy / Color).
    public static let supportedExtensions: Set<String> =
        Set(GameSystem.allCases.flatMap { $0.fileExtensions })

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

    /// Files at or above this size are hashed by a bounded prefix + size rather than in full, so a
    /// multi-hundred-MB PS1 disc image isn't read entirely into memory just to get an identity.
    private static let boundedHashThreshold = 32 * 1024 * 1024   // 32 MB
    private static let boundedHashPrefix    = 8 * 1024 * 1024     // first 8 MB

    /// Identity hash. Small carts (GBA/GB) are hashed whole; large disc images (PS1 .chd/.bin) are
    /// hashed by their first 8 MB combined with their exact byte size — stable per file, cheap to
    /// compute, and collision-safe enough for library identity.
    private static func identityHash(for url: URL) throws -> String {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size < boundedHashThreshold {
            return try Data(contentsOf: url).sha256Hex(prefix: 16)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = (try handle.read(upToCount: boundedHashPrefix)) ?? Data()
        withUnsafeBytes(of: UInt64(size).littleEndian) { data.append(contentsOf: $0) }
        return data.sha256Hex(prefix: 16)
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
