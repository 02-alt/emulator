import EmulatorCore
import XCTest
@testable import GBACore

/// Integration tests against the real libmgba core using a generated minimal GBA ROM
/// (entry = branch-to-self, valid header byte 0xB2 = 0x96).
final class GBACoreTests: XCTestCase {
    private func makeTestROM() throws -> URL {
        var rom = [UInt8](repeating: 0, count: 1024)
        rom[0] = 0xFE; rom[1] = 0xFF; rom[2] = 0xFF; rom[3] = 0xEA // ARM "b ." (loop forever)
        rom[0xB2] = 0x96                                            // recognized as a cartridge
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gbacore-test-\(UUID().uuidString).gba")
        try Data(rom).write(to: url)
        return url
    }

    func testLoadsAndRunsAtGBAResolution() throws {
        let core = GBACore()
        let rom = try makeTestROM()
        defer { try? FileManager.default.removeItem(at: rom) }
        try core.loadROM(at: rom)
        XCTAssertEqual(core.videoSize.width, 240)
        XCTAssertEqual(core.videoSize.height, 160)
        for _ in 0..<10 { core.runFrame() } // must not crash
    }

    func testSaveStateRestoresExactly() throws {
        let core = GBACore()
        let rom = try makeTestROM()
        defer { try? FileManager.default.removeItem(at: rom) }
        try core.loadROM(at: rom)

        for _ in 0..<30 { core.runFrame() }
        let snapshot = try core.saveState()
        XCTAssertGreaterThan(snapshot.count, 0)

        for _ in 0..<30 { core.runFrame() }   // diverge
        try core.loadState(snapshot)           // rewind to snapshot
        let restored = try core.saveState()

        XCTAssertEqual(snapshot, restored, "Loading a state must restore identical machine state")
    }

    func testSaveDataRoundTripDoesNotCrash() throws {
        let core = GBACore()
        let rom = try makeTestROM()
        defer { try? FileManager.default.removeItem(at: rom) }
        try core.loadROM(at: rom)
        for _ in 0..<10 { core.runFrame() }

        // A ROM with no declared save type yields nil; either way this must be crash-safe.
        if let battery = core.saveData {
            core.loadSaveData(battery)
        }
    }
}
