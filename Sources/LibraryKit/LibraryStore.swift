import Foundation

/// Persistent list of games, stored as JSON. Deduplicates by ROM hash. Main-thread use.
public final class LibraryStore {
    public private(set) var games: [Game]
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.libraryFile) {
        self.fileURL = fileURL
        self.games = LibraryStore.load(from: fileURL)
    }

    /// Add a game unless one with the same ROM hash already exists. Returns the stored game.
    @discardableResult
    public func add(_ game: Game) -> Game {
        if let existing = games.first(where: { $0.romHash == game.romHash }) { return existing }
        games.append(game)
        save()
        return game
    }

    public func update(_ game: Game) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx] = game
        save()
    }

    public func remove(id: UUID) {
        games.removeAll { $0.id == id }
        save()
    }

    public func game(withHash hash: String) -> Game? {
        games.first { $0.romHash == hash }
    }

    /// Next free slot index on the given shelf (for placing a newly imported game).
    public func nextSlot(onShelf shelf: Int, perShelf: Int) -> (shelf: Int, slot: Int) {
        let used = games.filter { $0.shelfIndex == shelf }.count
        if used < perShelf { return (shelf, used) }
        return nextSlot(onShelf: shelf + 1, perShelf: perShelf)
    }

    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(games).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("LibraryStore save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> [Game] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Game].self, from: data)) ?? []
    }
}
