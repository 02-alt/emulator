import Foundation

/// One saved game on a PlayStation memory card.
public struct PSXSave: Sendable, Identifiable {
    public let id = UUID()
    /// The display title as shown in the console's card manager (Shift-JIS in the save header).
    public let title: String
    /// The save's filename on the card — region prefix + product code + slot name (e.g. "BASLUS-00776…").
    public let filename: String
    /// How many of the card's 15 blocks this save occupies.
    public let blocks: Int
    /// Region letter from the filename: "America" / "Europe" / "Japan", or nil if unknown.
    public let region: String?
    /// The save's 16×16 icon as RGBA8888 pixels (memory byte order R,G,B,A), or nil if unreadable.
    /// This is the little picture the console's card manager shows for each save.
    public let icon: [UInt32]?

    public init(title: String, filename: String, blocks: Int, region: String?, icon: [UInt32]? = nil) {
        self.title = title; self.filename = filename; self.blocks = blocks
        self.region = region; self.icon = icon
    }
}

/// Reads a PlayStation memory-card image (`.mcr`, 128 KiB) into its list of saves. The card has 15
/// usable 8 KiB blocks (block 0 is the directory/filesystem). Each in-use directory entry points at a
/// data block whose header carries the Shift-JIS title the console shows.
public enum PSXMemoryCard {
    public static let blockCount = 15
    private static let frameSize = 128
    private static let blockSize = 8192

    /// Parsed card: the saves plus how full it is.
    public struct Card: Sendable {
        public let saves: [PSXSave]
        public init(saves: [PSXSave]) { self.saves = saves }
        public var blocksUsed: Int { saves.reduce(0) { $0 + $1.blocks } }
        public var blocksFree: Int { max(0, blockCount - blocksUsed) }
        public var isEmpty: Bool { saves.isEmpty }
    }

    /// The card image the core writes for a game: `<saveDir>/<base>.0.mcr` (Beetle's slot-0 card,
    /// keyed by the loaded content's base filename). `base` is the ROM/m3u filename stem.
    public static func url(saveDir: URL, base: String) -> URL {
        saveDir.appendingPathComponent("\(base).0.mcr")
    }

    /// Parse the card at `url`, or an empty card if it doesn't exist yet / can't be read.
    public static func read(_ url: URL) -> Card {
        guard let data = try? Data(contentsOf: url), data.count >= blockSize * 16 else {
            return Card(saves: [])
        }
        return Card(saves: parse([UInt8](data)))
    }

    static func parse(_ b: [UInt8]) -> [PSXSave] {
        var saves: [PSXSave] = []
        for i in 1...blockCount {
            let dir = i * frameSize                      // directory frame for block i (within block 0)
            guard dir + frameSize <= b.count else { break }
            // Allocation state: 0x51 = in use, first block of a save (0x52/0x53 = linked middle/last,
            // 0xA0 = free). We only start a save at its first block.
            guard b[dir] == 0x51 else { continue }

            let size = u32(b, dir + 4)
            let blocks = max(1, Int(size) / blockSize)
            let filename = ascii(b, dir + 10, 20)
            let region = regionName(filename)

            // Title lives in the data block's save header ("SC" magic, then 64 bytes Shift-JIS).
            let blockOff = i * blockSize
            var title = "Saved game"
            var icon: [UInt32]?
            if blockOff + 4 + 64 <= b.count, b[blockOff] == 0x53, b[blockOff + 1] == 0x43 {
                title = shiftJIS(Array(b[(blockOff + 4)..<(blockOff + 4 + 64)])) ?? title
                icon = parseIcon(b, blockOff)
            }
            saves.append(PSXSave(title: title, filename: filename, blocks: blocks, region: region, icon: icon))
        }
        return saves
    }

    /// The first icon frame from a save's data block: a 16-color palette (16-bit BGR555 at 0x60)
    /// applied to a 16×16, 4-bits-per-pixel image (at 0x80, low nibble = left pixel).
    private static func parseIcon(_ b: [UInt8], _ off: Int) -> [UInt32]? {
        let palOff = off + 0x60, frameOff = off + 0x80
        guard frameOff + 128 <= b.count else { return nil }
        var pal = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let v = UInt16(b[palOff + i * 2]) | (UInt16(b[palOff + i * 2 + 1]) << 8)
            func chan(_ s: UInt16) -> UInt32 { UInt32((v >> s) & 0x1F) * 255 / 31 }
            // 1-5-5-5: bits 0-4 R, 5-9 G, 10-14 B; index 0 = transparent (nothing drawn).
            let a: UInt32 = (i == 0 && v == 0) ? 0 : 255
            pal[i] = chan(0) | (chan(5) << 8) | (chan(10) << 16) | (a << 24)
        }
        var px = [UInt32](repeating: 0, count: 256)
        for i in 0..<128 {
            let byte = b[frameOff + i]
            px[i * 2] = pal[Int(byte & 0x0F)]        // low nibble = left pixel
            px[i * 2 + 1] = pal[Int(byte >> 4)]
        }
        return px
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func ascii(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
        guard o + n <= b.count else { return "" }
        let bytes = Array(b[o..<(o + n)]).prefix { $0 >= 0x20 && $0 < 0x7f }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func shiftJIS(_ bytes: [UInt8]) -> String? {
        let trimmed = Array(bytes.prefix { $0 != 0 })
        guard !trimmed.isEmpty,
              let s = String(bytes: trimmed, encoding: .shiftJIS) ?? String(bytes: trimmed, encoding: .ascii)
        else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// Region from the filename's two-letter prefix: B?=Sony format, then A/E/I = region.
    private static func regionName(_ filename: String) -> String? {
        guard filename.count >= 2 else { return nil }
        switch filename[filename.index(filename.startIndex, offsetBy: 1)] {
        case "A": return "America"
        case "E": return "Europe"
        case "I": return "Japan"
        default:  return nil
        }
    }
}
