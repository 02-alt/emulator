import Foundation

/// Fetches GBA box art + screenshots from the public libretro-thumbnails repo and caches them
/// on disk. Best-effort: returns nil on any miss/failure so the UI can draw a placeholder.
public final class CoverArtService: @unchecked Sendable {
    private let coversDir: URL
    private let snapsDir: URL
    private let session: URLSession

    // libretro-thumbnails expects exact No-Intro filenames, which is what a well-named ROM's
    // stem already is — so we match on the original filename stem, not the cleaned title.
    private static let repo =
        "https://raw.githubusercontent.com/libretro-thumbnails/Nintendo_-_Game_Boy_Advance/master/"
    private static let boxarts = repo + "Named_Boxarts/"
    private static let snaps = repo + "Named_Snaps/"

    public init(coversDir: URL = AppPaths.coversDir,
                snapsDir: URL = AppPaths.snapsDir,
                session: URLSession = .shared) {
        self.coversDir = coversDir
        self.snapsDir = snapsDir
        self.session = session
    }

    public func cachedCoverURL(hash: String) -> URL? { cached(in: coversDir, hash: hash) }
    public func cachedSnapURL(hash: String) -> URL? { cached(in: snapsDir, hash: hash) }

    /// Remote box-art URL for a filename stem, or nil if it can't be encoded.
    public func remoteURL(forStem stem: String) -> URL? { remote(base: Self.boxarts, stem: stem) }

    /// Download + cache the box art. nil on miss.
    public func fetchCover(forStem stem: String, hash: String) async -> URL? {
        await fetch(base: Self.boxarts, dir: coversDir, stem: stem, hash: hash)
    }

    /// Download + cache an in-game screenshot. nil on miss.
    public func fetchSnap(forStem stem: String, hash: String) async -> URL? {
        await fetch(base: Self.snaps, dir: snapsDir, stem: stem, hash: hash)
    }

    // MARK: - Internals

    private func cached(in dir: URL, hash: String) -> URL? {
        let url = dir.appendingPathComponent("\(hash).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func remote(base: String, stem: String) -> URL? {
        // libretro replaces &*/:`<>?\| with _ in filenames; then percent-encode.
        let sanitized = stem.replacingOccurrences(of: "&", with: "_")
        guard let encoded = sanitized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: base + encoded + ".png")
    }

    private func fetch(base: String, dir: URL, stem: String, hash: String) async -> URL? {
        if let cached = cached(in: dir, hash: hash) { return cached }
        guard let url = remote(base: base, stem: stem) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
            else { return nil }
            let dest = dir.appendingPathComponent("\(hash).png")
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}
