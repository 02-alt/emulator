import XCTest
@testable import LibraryKit

final class PSXMemoryCardTest: XCTestCase {
    func testParsesOneSave() {
        var b = [UInt8](repeating: 0, count: 131072)
        // header magic
        b[0] = 0x4D; b[1] = 0x43   // "MC"
        // all directory frames free by default
        for i in 1...15 { b[i*128] = 0xA0 }
        // frame 1: a 1-block save
        let dir = 1*128
        b[dir] = 0x51                              // in use, first block
        b[dir+4] = 0x00; b[dir+5] = 0x20           // size = 0x2000 = 8192
        b[dir+8] = 0xFF; b[dir+9] = 0xFF           // next = last
        let name = Array("BASLUS-00776MGS".utf8)
        for (k, c) in name.enumerated() { b[dir+10+k] = c }
        // data block 1: save header "SC" + title
        let blk = 1*8192
        b[blk] = 0x53; b[blk+1] = 0x43             // "SC"
        let title = Array("METAL GEAR SOLID".utf8)
        for (k, c) in title.enumerated() { b[blk+4+k] = c }

        let saves = PSXMemoryCard.parse(b)
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.title, "METAL GEAR SOLID")
        XCTAssertEqual(saves.first?.blocks, 1)
        XCTAssertEqual(saves.first?.region, "America")
        print("PARSED:", saves.first?.title ?? "-", saves.first?.region ?? "-", "blocks:", saves.first?.blocks ?? 0)
    }
}
