import AppKit
import LibraryKit

/// Assembles the library detail panel's metadata rows for a game, grouped for display.
///
/// Sources: the GBA ROM header (Region / Publisher / Serial — free, offline), the file itself
/// (ROM size), our save store (Save status), and our own library record (Added / Playtime).
/// The deeper rows — Developer / Genre / Release — stay `nil` ("-") until a metadata database or
/// online source is wired up. `nil` renders as a dim "-"; a string renders as real data.
enum GameDetails {
    /// Groups of (label, value) rows; `nil` value → "-". Read the ROM/save files here (once per
    /// selection), NOT during drawing, since the detail panel redraws every crossfade frame.
    static func groups(for game: Game) -> [[(String, String?)]] {
        let header = game.system == .gba ? GBAHeader.read(from: game.romURL) : nil
        // Rich catalog metadata from the bundled Libretro DB: GBA by CRC32/game-code, PS1 by title
        // (discs have no easy CRC/serial to match).
        let meta: GameMetadata?
        switch game.system {
        case .gba: meta = LibretroDB.gba.lookup(crc: CRC32.checksum(fileAt: game.romURL), gameCode: header?.gameCode)
        case .ps1: meta = LibretroDB.psx.lookup(name: game.romFilenameStem)
        case .gbc: meta = nil
        }

        var identity: [(String, String?)] = [("System", game.system.displayName)]
        // Region: the GBA header, else derived from the PS1 filename's region tag.
        let region = header?.region ?? (game.system == .ps1 ? psxRegion(game.romFilenameStem) : nil)
        identity.append(("Region", region))
        identity.append(("Publisher", meta?.publisher ?? header?.publisher))   // DB name preferred
        let serial = (header?.serial).flatMap { $0.isEmpty ? nil : $0 } ?? meta?.serial
        identity.append(("Serial", serial))

        let players = meta?.players.map { $0 == 1 ? "1 player" : "\($0) players" }
        let catalog: [(String, String?)] = [
            ("Developer", meta?.developer),
            ("Genre", meta?.genre),
            ("Release", meta?.releaseYear.map(String.init)),
            ("Players", players),
        ]

        let media: [(String, String?)] = [("ROM Size", romSize(game)), ("Save", saveStatus(game))]

        let df = DateFormatter(); df.dateStyle = .medium
        let session: [(String, String?)] = [
            ("Added", df.string(from: game.addedAt)),
            ("Playtime", game.secondsPlayed > 0 ? playtime(game.secondsPlayed) : nil),
        ]

        return [identity, catalog, media, session]
    }

    /// PS1 region from the filename's Redump tag (No PS1 header to read offline).
    private static func psxRegion(_ stem: String) -> String? {
        let s = stem.lowercased()
        let table: [(String, String)] = [
            ("(usa", "USA"), ("(us)", "USA"), ("(europe", "Europe"), ("(france", "France"),
            ("(germany", "Germany"), ("(spain", "Spain"), ("(italy", "Italy"), ("(japan", "Japan"),
            ("(asia", "Asia"), ("(australia", "Australia"), ("(korea", "Korea"), ("(world", "World"),
        ]
        return table.first { s.contains($0.0) }?.1
    }

    private static func romSize(_ game: Game) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: game.romPath))?[.size] as? Int,
              size > 0 else { return nil }
        let mb = Double(size) / (1024 * 1024)
        return mb >= 1 ? String(format: "%.0f MB", mb.rounded()) : "\(size / 1024) KB"
    }

    private static func saveStatus(_ game: Game) -> String? {
        let store = SaveStore(romURL: game.romURL)
        if store.exists(store.suspendURL) || store.exists(store.slotURL(0)) { return "Continue available" }
        if store.exists(store.batteryURL) { return "Battery save" }
        return "None"
    }

    private static func playtime(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(m % 60)m"
    }
}
