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
        case .ps1: return ["Sony_-_PlayStation"]
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
        // Serve a cache hit only if it's a real image — an older build could have cached a symlink's
        // text target (see below); ignore/replace such a file rather than hand back garbage.
        if !force, let cached = cached(in: dir, hash: hash), Self.isImageFile(cached) { return cached }
        for repo in Self.repos(for: system) {
            let base = Self.base(repo: repo, folder: folder)
            guard let data = await download(base: base, name: stem, hops: 3) else { continue }
            let dest = dir.appendingPathComponent("\(hash).png")
            do { try data.write(to: dest, options: .atomic); return dest } catch { continue }
        }
        return nil
    }

    /// Download one boxart, following libretro-thumbnails **symlinks**: regional duplicates are stored
    /// as symlinks, and raw.githubusercontent serves the link's target *filename* as `text/plain`
    /// rather than the image. When the body isn't a real image but names another `.png`, re-fetch that
    /// target (bounded by `hops`).
    private func download(base: String, name: String, hops: Int) async -> Data? {
        guard let url = remote(base: base, stem: name) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
        else { return nil }
        if Self.isImageData(data) { return data }
        if hops > 0, let target = Self.symlinkTarget(data) {
            return await download(base: base, name: target, hops: hops - 1)
        }
        return nil
    }

    /// PNG / JPEG magic bytes — a real image, not a symlink pointer or an error page.
    private static func isImageData(_ data: Data) -> Bool {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]      // ‰PNG
        let jpg: [UInt8] = [0xFF, 0xD8, 0xFF]            // JPEG SOI
        let head = [UInt8](data.prefix(4))
        return head.starts(with: png) || head.starts(with: jpg)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4)) ?? Data()
        return isImageData(head)
    }

    /// If `data` is a symlink target that raw.githubusercontent served as text — a single short line
    /// naming a `.png` — return the target's stem (extension stripped, ready for `remote()`).
    private static func symlinkTarget(_ data: Data) -> String? {
        guard data.count < 512, let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("\n"), line.lowercased().hasSuffix(".png") else { return nil }
        return (line as NSString).deletingPathExtension
    }
}
