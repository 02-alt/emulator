import Foundation
import Observation
import UIKit
import LibraryKit

/// The app's library state: a thin, observable wrapper over LibraryKit's `LibraryStore` (the same
/// AppKit-free model + JSON persistence the macOS app uses). Handles ROM import (copy into the app's
/// ROM store, dedupe by content hash) and last-played bookkeeping.
@MainActor
@Observable
final class LibraryModel {
    private let store = LibraryStore()
    private let coverService = CoverArtService()
    private(set) var games: [Game] = []
    /// romHash → cached box-art file URL. Reactive: rows read this and refresh as art arrives.
    private(set) var covers: [String: URL] = [:]

    init() {
        reanchorROMPaths()   // repair paths left stale by an app-container UUID change (see below)
        importFromDocuments()
        reload()
    }

    /// Repair stale ROM paths. A `Game.romPath` is saved as an absolute path, and on iOS the Data
    /// container's UUID changes when the app is reinstalled — so a path saved by a previous install
    /// (`…/Application/<oldUUID>/…/roms/Game.gba`) no longer resolves, even though the ROM file itself
    /// persists in the *current* container's romsDir. Re-anchor each game to the current romsDir by
    /// filename so the ROM is always found (fixes Send/Continue/play silently failing after a reinstall).
    private func reanchorROMPaths() {
        let romsDir = AppPaths.romsDir
        var changed = false
        for game in store.games {
            let current = romsDir.appendingPathComponent(game.romURL.lastPathComponent).path
            guard game.romPath != current,
                  FileManager.default.fileExists(atPath: current) else { continue }
            var g = game
            g.romPath = current
            store.update(g)
            changed = true
        }
        if changed { store.save() }
    }

    /// Auto-import any playable ROM sitting in the app's Documents directory (where Files shows the app
    /// under "On My iPhone"), then remove the loose copy — so dropping ROMs into the app folder just
    /// works, and re-drops dedupe by content hash. Covers every iOS-playable extension (GBA + Game Boy
    /// / Color), not just `.gba` — a dropped `.gbc`/`.gb` used to be silently ignored.
    private func importFromDocuments() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil)) ?? []
        for url in items where GameSystem.iosPlayableExtensions.contains(url.pathExtension.lowercased()) {
            if (try? importROM(from: url)) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Most-recently-played first, then most-recently-added.
    private func reload() {
        games = store.games.sorted {
            ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt)
        }
        refreshCovers()
    }

    /// Populate `covers` from the on-disk cache immediately, then fetch any that are missing from
    /// the public libretro-thumbnails repo (best-effort; well-named ROMs match, others stay blank).
    /// Games the player has switched to the default label (a `.nocover` marker) are skipped entirely,
    /// so they keep their stylized monogram cart instead of pulling art back down.
    private func refreshCovers() {
        for game in games where covers[game.romHash] == nil && !usesDefaultCover(game) {
            if let cached = coverService.cachedCoverURL(hash: game.romHash) {
                covers[game.romHash] = cached
            }
        }
        Task { await fetchMissingCovers() }
    }

    private func fetchMissingCovers() async {
        for game in games where covers[game.romHash] == nil && !usesDefaultCover(game) {
            if let url = await coverService.fetchCover(
                forStem: game.romFilenameStem, hash: game.romHash, system: game.system) {
                covers[game.romHash] = url
            }
        }
    }

    // MARK: - Default (stylized) cover

    /// The marker file that pins a game to its default stylized cart label. Its presence means "don't
    /// show or fetch box art for this game" — the cart falls back to the monogram label the cartridge
    /// view draws when it has no cover.
    private func defaultCoverMarker(hash: String) -> URL {
        AppPaths.coversDir.appendingPathComponent("\(hash).nocover")
    }

    /// Whether this game is pinned to the default stylized label.
    func usesDefaultCover(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: defaultCoverMarker(hash: game.romHash).path)
    }

    /// Pin a game to its default stylized cart label: drop any downloaded/custom art and mark it so the
    /// auto-fetch leaves it alone. Reversible via `restoreDownloadedCover`.
    func useDefaultCover(for game: Game) {
        try? FileManager.default.createDirectory(at: AppPaths.coversDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: AppPaths.coversDir.appendingPathComponent("\(game.romHash).png"))
        FileManager.default.createFile(atPath: defaultCoverMarker(hash: game.romHash).path, contents: nil)
        covers[game.romHash] = nil
    }

    /// Undo `useDefaultCover`: clear the marker and re-fetch the downloaded box art (if any exists).
    func restoreDownloadedCover(for game: Game) {
        try? FileManager.default.removeItem(at: defaultCoverMarker(hash: game.romHash))
        Task { await fetchMissingCovers() }
    }

    /// Import a `.gba` the user picked in Files. Copies it into the app's ROM store so the library
    /// never breaks if the original moves, then adds a `Game` (skipping exact-content duplicates).
    @discardableResult
    func importROM(from pickedURL: URL) throws -> Game {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let dest = AppPaths.romsDir.appendingPathComponent(pickedURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        }

        let game = try ROMImporter.makeGame(from: dest)
        if let existing = store.game(withHash: game.romHash) {
            reload()
            return existing
        }
        let added = store.add(game)
        store.save()
        reload()
        return added
    }

    /// Persist edits to a game (per-game settings, etc.).
    func update(_ game: Game) {
        store.update(game)
        store.save()
        reload()
    }

    /// Set a custom cover for a game from picked image data (e.g. Photos). Downscales to a modest
    /// JPEG and writes it to the cover cache location (`coversDir/<hash>.png`) so it persists and is
    /// picked up on relaunch, then refreshes the reactive `covers` map.
    func setCover(fromImageData data: Data, for game: Game) {
        guard let image = UIImage(data: data) else { return }
        let target: CGFloat = 512
        let scale = min(1, target / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        // A chosen image overrides a prior "use default" choice.
        try? FileManager.default.removeItem(at: defaultCoverMarker(hash: game.romHash))
        let url = AppPaths.coversDir.appendingPathComponent("\(game.romHash).png")
        try? jpeg.write(to: url, options: .atomic)
        // nil → url forces the row/cart to reload the image even though the path is unchanged.
        covers[game.romHash] = nil
        DispatchQueue.main.async { self.covers[game.romHash] = url }
    }

    func markPlayed(_ game: Game) {
        var g = game
        g.lastPlayedAt = Date()
        store.update(g)
        store.save()
        reload()
    }

    func delete(_ game: Game) {
        store.remove(id: game.id)
        store.save()
        reload()
    }
}

/// `Game` is `Equatable` in LibraryKit but not `Hashable`; SwiftUI navigation (`NavigationLink(value:)`,
/// `navigationDestination(for:)`) needs `Hashable`. Identity is the stable `id`, so key on that.
/// A manual witness (not synthesis) is fine to add from this module.
extension Game: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
