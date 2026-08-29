import XCTest
@testable import LibraryKit

final class PSXDiscHashTest: XCTestCase {
    func testParseBoot() {
        // Strips cdrom:\ and ;1, keeps case verbatim (rcheevos hashes it as-is).
        XCTAssertEqual(PSXDiscHash.parseBoot("BOOT = cdrom:\\sles_015.06;1\nTCB = 4"), "sles_015.06")
        XCTAssertEqual(PSXDiscHash.parseBoot("BOOT=cdrom:SLUS_007.76;1"), "SLUS_007.76")
    }

    func testHashesRealMGS() throws {
        let cue = URL(fileURLWithPath: NSString(string:
            "~/Library/Application Support/Emulator/roms/Metal Gear Solid (France) (Disc 1)/Metal Gear Solid (France) (Disc 1).cue").expandingTildeInPath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cue.path), "MGS disc not present")
        XCTAssertEqual(PSXDiscHash.bootExecutableName(for: cue), "sles_015.06")
        // rcheevos-exact hash of MGS (France) (Disc 1) — verbatim exe name + header+code.
        XCTAssertEqual(PSXDiscHash.raHash(for: cue), "5dfa249c6e70096c79ad77a74e3a2019")
    }
}
