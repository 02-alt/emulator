import SwiftUI
import LibraryKit

/// Grouped (label, value) metadata for a game — the iOS port of the macOS `GameDetails`. Same
/// sources: the GBA ROM header (Region / Publisher / Serial — offline), the bundled Libretro DB
/// (Developer / Genre / Release / Players), the file (ROM size) and our library/save records
/// (Added / Playtime / Save). A `nil` value renders as a dim "–".
enum GameDetails {
    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let rows: [(label: String, value: String?)]
    }

    static func groups(for game: Game) -> [Group] {
        let header = game.system == .gba ? GBAHeader.read(from: game.romURL) : nil
        let meta: GameMetadata? = game.system == .gba
            ? LibretroDB.gba.lookup(crc: CRC32.checksum(fileAt: game.romURL), gameCode: header?.gameCode)
            : nil

        let identity: [(String, String?)] = [
            ("System", game.system.displayName),
            ("Region", header?.region),
            ("Publisher", meta?.publisher ?? header?.publisher),   // DB name preferred
            ("Serial", (header?.serial).flatMap { $0.isEmpty ? nil : $0 }),
        ]

        let players = meta?.players.map { $0 == 1 ? "1 player" : "\($0) players" }
        let catalog: [(String, String?)] = [
            ("Developer", meta?.developer),
            ("Genre", meta?.genre),
            ("Release", meta?.releaseYear.map(String.init)),
            ("Players", players),
        ]

        let media: [(String, String?)] = [
            ("ROM Size", romSize(game)),
            ("Save", saveStatus(game)),
        ]

        let df = DateFormatter(); df.dateStyle = .medium
        let session: [(String, String?)] = [
            ("Added", df.string(from: game.addedAt)),
            ("Playtime", game.secondsPlayed > 0 ? playtime(game.secondsPlayed) : nil),
        ]

        return [
            Group(title: "IDENTITY", rows: identity),
            Group(title: "CATALOG", rows: catalog),
            Group(title: "MEDIA", rows: media),
            Group(title: "SESSION", rows: session),
        ]
    }

    private static func romSize(_ game: Game) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: game.romPath))?[.size] as? Int,
              size > 0 else { return nil }
        let mb = Double(size) / (1024 * 1024)
        return mb >= 1 ? String(format: "%.0f MB", mb.rounded()) : "\(size / 1024) KB"
    }

    /// Reads the per-game save folder without creating it (unlike `SavePaths.directory`, which is a
    /// write path). `state.bin` means a resumable save state exists; `battery.sav` is cartridge SRAM.
    private static func saveStatus(_ game: Game) -> String? {
        let dir = AppPaths.appSupport
            .appendingPathComponent("saves", isDirectory: true)
            .appendingPathComponent(game.romHash, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("state.bin").path) { return "Continue available" }
        if fm.fileExists(atPath: dir.appendingPathComponent("battery.sav").path) { return "Battery save" }
        return "None"
    }

    private static func playtime(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60)h \(m % 60)m"
    }
}

/// The details "drawer": a pull-up sheet echoing the Mac's tucked-away metadata panel. Presented at
/// a medium detent (draggable to large), it lists the grouped rows in the Analogue-OS mono voice.
struct GameDetailsSheet: View {
    let game: Game

    /// RetroAchievements progress for this game — distinct states so the panel explains *why* there
    /// are no trophies rather than showing an empty space. Mirrors the macOS shelf's `RAState`.
    private enum RAState {
        case hidden            // not a system RA supports — show nothing
        case notConfigured     // no RA login yet
        case loading
        case notFound          // this ROM isn't a game RA tracks
        case failed            // couldn't reach RA (offline / bad key)
        case loaded(RAGameProgress)
    }

    @State private var ra: RAState = .hidden

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    achievementsSection
                    ForEach(GameDetails.groups(for: game)) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(DS.mono(10, .bold)).foregroundStyle(DS.textTertiary)
                                .kerning(1.5)
                            ForEach(group.rows, id: \.label) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.label)
                                        .font(DS.mono(13)).foregroundStyle(DS.textSecondary)
                                    Spacer(minLength: 16)
                                    Text(row.value ?? "–")
                                        .font(DS.mono(13, .medium))
                                        .foregroundStyle(row.value == nil ? DS.textTertiary : DS.textPrimary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.background)
            .navigationTitle(game.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.background, for: .navigationBar)
            .task(id: game.id) { await loadAchievements() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.background)
    }

    // MARK: - Achievements

    @ViewBuilder
    private var achievementsSection: some View {
        if case .hidden = ra { EmptyView() } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("ACHIEVEMENTS")
                    .font(DS.mono(10, .bold)).foregroundStyle(DS.textTertiary).kerning(1.5)
                achievementsBody
            }
        }
    }

    @ViewBuilder
    private var achievementsBody: some View {
        switch ra {
        case .hidden:
            EmptyView()
        case .notConfigured:
            raStatus("Sign in to RetroAchievements in Settings for trophies")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading achievements…").font(DS.mono(13)).foregroundStyle(DS.textSecondary)
            }
        case .notFound:
            raStatus("No achievements set for this game")
        case .failed:
            raStatus("Couldn't reach RetroAchievements")
        case .loaded(let progress):
            loadedAchievements(progress)
        }
    }

    private func raStatus(_ message: String) -> some View {
        Text(message).font(DS.mono(13)).foregroundStyle(DS.textSecondary)
    }

    private func loadedAchievements(_ p: RAGameProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(p.earned) / \(p.total) trophies")
                    .font(DS.mono(13, .medium)).foregroundStyle(DS.textPrimary)
                Spacer(minLength: 16)
                Text("\(p.earnedPoints) / \(p.points) pts")
                    .font(DS.mono(13)).foregroundStyle(DS.textSecondary)
            }
            ProgressView(value: p.total > 0 ? Double(p.earned) / Double(p.total) : 0).tint(.green)

            ForEach(sortedAchievements(p), id: \.id) { a in
                HStack(spacing: 10) {
                    Image(systemName: a.earned ? "trophy.fill" : "trophy")
                        .font(.system(size: 12))
                        .foregroundStyle(a.earned ? Color.yellow : DS.textTertiary)
                        .frame(width: 18)
                    Text(a.title)
                        .font(DS.mono(12))
                        .foregroundStyle(a.earned ? DS.textPrimary : DS.textSecondary)
                    Spacer(minLength: 12)
                    Text("\(a.points)").font(DS.mono(12)).foregroundStyle(DS.textTertiary)
                }
            }
        }
    }

    /// Earned first, then by point value (harder trophies higher) — the order a player scans for.
    private func sortedAchievements(_ p: RAGameProgress) -> [RAAchievement] {
        p.achievements.sorted { a, b in
            a.earned != b.earned ? a.earned : a.points > b.points
        }
    }

    private func loadAchievements() async {
        guard game.system == .gba else { ra = .hidden; return }
        guard RACredentials.isConfigured else { ra = .notConfigured; return }
        ra = .loading
        switch await RetroAchievements.fetch(forROMAt: game.romURL) {
        case .ok(let progress): ra = .loaded(progress)
        case .notFound: ra = .notFound
        case .failed: ra = .failed
        }
    }
}
