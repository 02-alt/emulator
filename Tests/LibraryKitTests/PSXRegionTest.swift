import XCTest
@testable import LibraryKit

final class PSXRegionTest: XCTestCase {
    func testRegionFromSerial() {
        // North America
        XCTAssertEqual(PSXRegion.from(serial: "SLUS_007.76"), .america)
        XCTAssertEqual(PSXRegion.from(serial: "SCUS-94900"), .america)
        // Europe (any of the EU maker prefixes)
        XCTAssertEqual(PSXRegion.from(serial: "SLES_015.06"), .europe)
        XCTAssertEqual(PSXRegion.from(serial: "SCES-01290"), .europe)
        // Japan
        XCTAssertEqual(PSXRegion.from(serial: "SCPS-10088"), .japan)
        XCTAssertEqual(PSXRegion.from(serial: "SLPM-86247"), .japan)
        // Case-insensitive
        XCTAssertEqual(PSXRegion.from(serial: "slps_012.34"), .japan)
        // Unknown prefix → nil, never a wrong guess
        XCTAssertNil(PSXRegion.from(serial: "XXXX-00000"))
        XCTAssertNil(PSXRegion.from(serial: ""))
    }

    func testBiosFilenameRoundTrips() {
        // Each region's canonical BIOS maps back to that region.
        for region in PSXRegion.allCases {
            XCTAssertEqual(PSXRegion.of(biosFilename: region.biosFilename), region)
        }
        // A US variant filename still reads as North America.
        XCTAssertEqual(PSXRegion.of(biosFilename: "scph1001.bin"), .america)
        XCTAssertEqual(PSXRegion.of(biosFilename: "SCPH7002.BIN"), .europe)   // case-insensitive
        XCTAssertNil(PSXRegion.of(biosFilename: "not-a-bios.bin"))
    }
}
