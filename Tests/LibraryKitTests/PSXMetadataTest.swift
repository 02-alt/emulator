import XCTest
@testable import LibraryKit

final class PSXMetadataTest: XCTestCase {
    private func db() -> LibretroDB {
        // Resolve the bundled rdb from the source tree (resources don't load in the test bundle).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LibraryKit/Resources/psx_libretro.rdb")
        return LibretroDB.testLoad(url)
    }
    func testParsesAndLooksUp() {
        let d = db()
        let s = d.debugStats()
        print("PSX_STATS names=\(s.names) crc=\(s.crc) code=\(s.code) withDev=\(s.withDev)")
        XCTAssertGreaterThan(s.names, 5000, "should parse thousands of titles")
        let zd = d.lookup(name: "Zero Divide 2 - The Secret Wish (Spain)")
        print("ZD2:", zd?.developer ?? "-", "|", zd?.genre ?? "-", "|", zd?.publisher ?? "-", "|", zd?.serial ?? "-")
        let mgs = d.lookup(name: "Metal Gear Solid (France) (Disc 1)")
        print("MGS:", mgs?.developer ?? "-", "|", mgs?.genre ?? "-", "|", mgs?.serial ?? "-")
    }
}
