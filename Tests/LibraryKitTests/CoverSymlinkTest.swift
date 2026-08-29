import XCTest
@testable import LibraryKit

final class CoverSymlinkTest: XCTestCase {
    /// Live: the PS1 boxart for MGS (France) is a libretro symlink to the Europe image. The service
    /// must follow it and cache a real PNG, not the 29-byte text pointer.
    func testFollowsPS1Symlink() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("covtest-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CoverArtService(coversDir: dir, snapsDir: dir)
        let url = await svc.fetchCover(forStem: "Metal Gear Solid (France) (Disc 1)",
                                       hash: "mgstest", system: .ps1, force: true)
        let u = try XCTUnwrap(url, "should resolve the symlink to a real cover")
        let head = try FileHandle(forReadingFrom: u).read(upToCount: 4) ?? Data()
        XCTAssertEqual([UInt8](head), [0x89, 0x50, 0x4E, 0x47], "cached file must be a real PNG")
        let size = try Data(contentsOf: u).count
        XCTAssertGreaterThan(size, 10_000, "PNG, not a 29-byte pointer")
    }
}
