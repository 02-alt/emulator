import Foundation

/// Fetches box art + screenshots from the public libretro-thumbnails repos and caches them on disk.
/// The repo is chosen per system (GBA vs Game Boy / Color); Game Boy games try the Color repo then
/// the original Game Boy repo, since our `.gbc` system covers both. Best-effort: returns nil on any
/// miss/failure so the UI can draw a placeholder.
public final class CoverArtService: @unchecked Sendable {
    private let coversDir: URL
    private let snapsDir: URL
    private let session: URLSession

    /// libretro-thumbnails repo name(s) to try for a system, in order (first hit wins). Names come
    /// straight from github.com/libretro-thumbnails.
    private static func repos(for system: GameSystem) -> [String] {
        switch system {
        case .gba: return ["Nintendo_-_Game_Boy_Advance"]
        case .gbc: return ["Nintendo_-_Game_Boy_Color", "Nintendo_-_Game_Boy"]
        }
    }

    /// The raw base URL for a repo's `Named_Boxarts` / `Named_Snaps` folder.
    private static func base(repo: String, folder: String) -> String {
        "https://raw.githubusercontent.com/libretro-thumbnails/\(repo)/master/\(folder)/"
    }

    public init(coversDir: URL = AppPaths.coversDir,
                snapsDir: URL = AppPaths.snapsDir,
                session: URLSession = .shared) {
        self.coversDir = coversDir
        self.snapsDir = snapsDir
        self.session = session
    }

    public func cachedCoverURL(hash: String) -> URL? { cached(in: coversDir, hash: hash) }
    public func cachedSnapURL(hash: String) -> URL? { cached(in: snapsDir, hash: hash) }

    /// Remote box-art URL for a filename stem (first repo for the system), or nil if it can't be encoded.
    public func remoteURL(forStem stem: String, system: GameSystem = .gba) -> URL? {
        Self.repos(for: system).first
            .map { Self.base(repo: $0, folder: "Named_Boxarts") }
            .flatMap { remote(base: $0, stem: stem) }
    }

    /// Download + cache the box art. nil on miss. `force` re-downloads even if a cache file exists —
    /// used by the manual "find cover online" action so a retry isn't short-circuited by a stale file.
    public func fetchCover(forStem stem: String, hash: String,
                           system: GameSystem = .gba, force: Bool = false) async -> URL? {
        await fetch(folder: "Named_Boxarts", dir: coversDir,
                    stem: stem, hash: hash, system: system, force: force)
    }

    /// Download + cache an in-game screenshot. nil on miss.
    public func fetchSnap(forStem stem: String, hash: String, system: GameSystem = .gba) async -> URL? {
        await fetch(folder: "Named_Snaps", dir: snapsDir,
                    stem: stem, hash: hash, system: system, force: false)
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

    private func fetch(folder: String, dir: URL, stem: String, hash: String,
                       system: GameSystem, force: Bool) async -> URL? {
        if !force, let cached = cached(in: dir, hash: hash) { return cached }
        for repo in Self.repos(for: system) {
            guard let url = remote(base: Self.base(repo: repo, folder: folder), stem: stem) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
                else { continue }
                let dest = dir.appendingPathComponent("\(hash).png")
                try data.write(to: dest, options: .atomic)
                return dest
            } catch {
                continue
            }
        }
        return nil
    }
}
