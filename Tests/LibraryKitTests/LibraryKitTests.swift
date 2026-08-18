import XCTest
@testable import LibraryKit

final class LibraryKitTests: XCTestCase {
    private func tempROM(named name: String, bytes: [UInt8] = [0xEA, 0, 0, 0]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).gba")
        try Data(bytes).write(to: url)
        return url
    }

    func testTitleCleaning() {
        XCTAssertEqual(
            ROMImporter.cleanTitle("Pokemon - Emerald Version (USA, Europe)"),
            "Pokemon - Emerald Version")
        XCTAssertEqual(ROMImporter.cleanTitle("Metroid_Fusion [!]"), "Metroid Fusion")
        XCTAssertEqual(ROMImporter.cleanTitle("Advance  Wars"), "Advance Wars")
    }

    func testImportProducesStableHashAndTitle() throws {
        let rom = try tempROM(named: "Some Game (USA)")
        defer { try? FileManager.default.removeItem(at: rom) }

        let a = try ROMImporter.makeGame(from: rom)
        let b = try ROMImporter.makeGame(from: rom)
        XCTAssertEqual(a.romHash, b.romHash, "Hash must be deterministic")
        XCTAssertEqual(a.romHash.count, 16)
        XCTAssertEqual(a.title, "Some Game")
        XCTAssertEqual(a.romFilenameStem, "Some Game (USA)")
    }

    func testStorePersistsAndDeduplicates() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let rom = try tempROM(named: "Dedup Game")
        defer { try? FileManager.default.removeItem(at: rom) }
        let game = try ROMImporter.makeGame(from: rom)

        let store = LibraryStore(fileURL: file)
        store.add(game)
        store.add(game) // same hash → no duplicate
        XCTAssertEqual(store.games.count, 1)

        // Reload from disk → persisted.
        let reloaded = LibraryStore(fileURL: file)
        XCTAssertEqual(reloaded.games.count, 1)
        XCTAssertEqual(reloaded.games.first?.title, "Dedup Game")
    }

    func testNextSlotFillsThenSpillsToNextShelf() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = LibraryStore(fileURL: file)

        for i in 0..<3 {
            store.add(Game(title: "G\(i)", romFilenameStem: "G\(i)", romPath: "/tmp/G\(i)",
                           romHash: "h\(i)", shelfIndex: 0, slotIndex: i))
        }
        // 3 on shelf 0 with capacity 3 → next spills to shelf 1 slot 0.
        let next = store.nextSlot(onShelf: 0, perShelf: 3)
        XCTAssertEqual(next.shelf, 1)
        XCTAssertEqual(next.slot, 0)
    }

    func testPlaytimeAccumulationPersists() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = LibraryStore(fileURL: file)

        var game = Game(title: "G", romFilenameStem: "G", romPath: "/tmp/G", romHash: "h0")
        store.add(game)
        game.secondsPlayed += 125
        store.update(game)

        let reloaded = LibraryStore(fileURL: file)
        XCTAssertEqual(reloaded.games.first?.secondsPlayed, 125)
    }

    func testSnapRemoteURLEncoding() {
        let svc = CoverArtService()
        let url = svc.remoteURL(forStem: "Metroid Fusion (USA)")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("Named_Boxarts"))
    }

    func testCoverRemoteURLEncoding() {
        let svc = CoverArtService()
        let url = svc.remoteURL(forStem: "Mario Kart - Super Circuit (USA)")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.hasSuffix("Mario%20Kart%20-%20Super%20Circuit%20(USA).png"))
        XCTAssertTrue(url!.absoluteString.contains("Named_Boxarts"))
    }
}
