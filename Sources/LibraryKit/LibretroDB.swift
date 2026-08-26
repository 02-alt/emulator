import Foundation

/// Rich game metadata from the bundled **Libretro** game database (CC BY-SA 4.0). Filled from the
/// compiled `.rdb` (a libretrodb file of MessagePack entries), matched by CRC32 (exact) with a
/// game-code fallback — so even ROM hacks resolve to their base game's catalog info.
public struct GameMetadata: Sendable {
    public var developer: String?
    public var publisher: String?
    public var genre: String?
    public var releaseYear: Int?
    public var players: Int?
    public var franchise: String?
    public var serial: String?   // e.g. "SLES-01370" (PS1); the game code for the handhelds
}

public final class LibretroDB: @unchecked Sendable {
    /// The Game Boy Advance database (lazy-loaded on first lookup).
    public static let gba = LibretroDB(resource: "gba_libretro")
    /// The Sony PlayStation database (matched by title, since PS1 discs have no easy CRC/serial).
    public static let psx = LibretroDB(resource: "psx_libretro")

    private let resource: String
    private var byCRC: [UInt32: GameMetadata] = [:]
    private var byCode: [String: GameMetadata] = [:]   // 4-char ASCII game code, e.g. "BPRE"
    private var byName: [String: GameMetadata] = [:]   // normalized full title (PS1 matches by name)
    private var byBase: [String: GameMetadata] = [:]   // title with region/disc tags stripped → data-bearing entry
    private var loaded = false
    private let lock = NSLock()

    private init(resource: String) { self.resource = resource }

    /// Look up a game's metadata by CRC32 (preferred) or its 4-char game code (fallback).
    public func lookup(crc: UInt32?, gameCode: String?) -> GameMetadata? {
        loadIfNeeded()
        if let crc, let m = byCRC[crc] { return m }
        if let code = gameCode, !code.isEmpty, let m = byCode[code] { return m }
        return nil
    }

    /// Look up by title (PS1). Regional/disc variants ("…(France) (Disc 1)") often carry only a name,
    /// with the catalog data on the primary release — so fall back to the base title (region/disc tags
    /// stripped) for the developer/genre/publisher, keeping this release's own serial when it has one.
    public func lookup(name: String) -> GameMetadata? {
        loadIfNeeded()
        let exact = byName[Self.normalize(name)]
        if let exact, exact.developer != nil || exact.genre != nil || exact.publisher != nil {
            return exact
        }
        if var base = byBase[Self.normalize(Self.baseTitle(name))] {
            if let s = exact?.serial, !s.isEmpty { base.serial = s }   // prefer the exact release's serial
            return base
        }
        return exact
    }

    /// Test hook: build a DB straight from an `.rdb` file, bypassing the resource bundle.
    static func testLoad(_ url: URL) -> LibretroDB {
        let db = LibretroDB(resource: "")
        if let data = try? Data(contentsOf: url) { db.parse([UInt8](data)) }
        db.loaded = true
        return db
    }

    func debugStats() -> (names: Int, crc: Int, code: Int, withDev: Int) {
        loadIfNeeded()
        return (byName.count, byCRC.count, byCode.count,
                byName.values.filter { $0.developer != nil }.count)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title before its first parenthetical/bracket tag — "Metal Gear Solid (France) (Disc 1)"
    /// → "Metal Gear Solid".
    static func baseTitle(_ s: String) -> String {
        if let r = s.range(of: #"\s*[\(\[]"#, options: .regularExpression) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.moduleResources?.url(forResource: resource, withExtension: "rdb"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        parse([UInt8](data))
    }

    /// libretrodb: 8-byte "RARCHDB\0" magic + 8-byte big-endian offset to the trailing index;
    /// entries are consecutive MessagePack maps in between.
    private func parse(_ bytes: [UInt8]) {
        guard bytes.count > 16, Array(bytes[0..<7]) == Array("RARCHDB".utf8) else { return }
        let metaOffset = bytes[8..<16].reduce(0) { ($0 << 8) | Int($1) }
        var reader = MsgReader(bytes)
        reader.index = 16
        while reader.index < metaOffset, reader.index < bytes.count {
            guard let value = reader.read() else { break }
            guard case let .map(pairs) = value else { continue }

            var meta = GameMetadata()
            var crc: UInt32?
            var code: String?
            var name: String?
            for (key, v) in pairs {
                guard case let .string(k) = key else { continue }
                switch k {
                case "developer":   meta.developer = v.stringValue
                case "publisher":   meta.publisher = v.stringValue
                case "genre":       meta.genre = v.stringValue
                case "franchise":   meta.franchise = v.stringValue
                case "releaseyear": meta.releaseYear = v.intValue
                case "users":       meta.players = v.intValue
                case "name":        name = v.stringValue
                case "crc":
                    if case let .binary(d) = v, d.count == 4 {
                        crc = d.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    }
                case "serial":
                    // Binary (handheld 4-char code) or an ASCII string ("SLES-01370" on PS1).
                    if case let .binary(d) = v { code = String(bytes: d, encoding: .ascii) }
                    else if case let .string(s) = v { code = s }
                default: break
                }
            }
            meta.serial = code
            if let crc { byCRC[crc] = meta }
            // Several releases can share a game code (regions/revisions); some carry no metadata.
            // Prefer a data-bearing entry so the serial fallback doesn't land on a blank one.
            if let code, !code.isEmpty {
                let hasData = meta.developer != nil || meta.genre != nil || meta.publisher != nil
                if byCode[code] == nil || hasData { byCode[code] = meta }
            }
            if let name, !name.isEmpty {
                byName[Self.normalize(name)] = meta
                // Index the base title too, preferring a data-bearing release so regional/disc
                // variants (which often carry only a name) still resolve catalog info.
                let base = Self.normalize(Self.baseTitle(name))
                let hasData = meta.developer != nil || meta.genre != nil || meta.publisher != nil
                if hasData || byBase[base] == nil { byBase[base] = meta }
            }
        }
    }
}

// MARK: - Minimal MessagePack reader

private enum MsgValue {
    case null, bool(Bool), int(Int), uint(UInt64), string(String), binary([UInt8])
    case array([MsgValue]), map([(MsgValue, MsgValue)])

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .uint(u): return Int(u)
        default: return nil
        }
    }
}

private struct MsgReader {
    let b: [UInt8]
    var index = 0
    init(_ b: [UInt8]) { self.b = b }

    private mutating func u8() -> Int { defer { index += 1 }; return index < b.count ? Int(b[index]) : 0 }
    private mutating func uN(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n { v = (v << 8) | u8() }
        return v
    }

    mutating func read() -> MsgValue? {
        guard index < b.count else { return nil }
        let c = b[index]; index += 1
        switch c {
        case 0x00...0x7f: return .int(Int(c))
        case 0xe0...0xff: return .int(Int(Int8(bitPattern: c)))
        case 0x80...0x8f: return map(Int(c & 0x0f))
        case 0x90...0x9f: return array(Int(c & 0x0f))
        case 0xa0...0xbf: return str(Int(c & 0x1f))
        case 0xc0:        return .null
        case 0xc2:        return .bool(false)
        case 0xc3:        return .bool(true)
        case 0xc4:        return bin(u8())
        case 0xc5:        return bin(uN(2))
        case 0xc6:        return bin(uN(4))
        case 0xcc:        return .uint(UInt64(u8()))
        case 0xcd:        return .uint(UInt64(uN(2)))
        case 0xce:        return .uint(UInt64(uN(4)))
        case 0xcf:        return .uint(UInt64(uN(8) & Int.max))
        case 0xca:        _ = bytes(4); return .null                          // float32
        case 0xcb:        _ = bytes(8); return .null                          // float64
        case 0xd0:        return .int(Int(Int8(bitPattern: UInt8(u8()))))
        case 0xd1:        return .int(Int(Int16(bitPattern: UInt16(uN(2)))))
        case 0xd2:        return .int(Int(Int32(bitPattern: UInt32(uN(4)))))
        case 0xd3:        return .int(Int(bitPattern: UInt(uN(8))))           // int64
        case 0xc7:        do { let n = u8(); _ = u8(); return bin(n) }        // ext8:  len,type,data
        case 0xc8:        do { let n = uN(2); _ = u8(); return bin(n) }       // ext16
        case 0xc9:        do { let n = uN(4); _ = u8(); return bin(n) }       // ext32
        case 0xd4:        _ = bytes(2); return .null                         // fixext1  (type + 1)
        case 0xd5:        _ = bytes(3); return .null                         // fixext2
        case 0xd6:        _ = bytes(5); return .null                         // fixext4
        case 0xd7:        _ = bytes(9); return .null                         // fixext8
        case 0xd8:        _ = bytes(17); return .null                        // fixext16
        case 0xd9:        return str(u8())
        case 0xda:        return str(uN(2))
        case 0xdb:        return str(uN(4))
        case 0xdc:        return array(uN(2))
        case 0xdd:        return array(uN(4))
        case 0xde:        return map(uN(2))
        case 0xdf:        return map(uN(4))
        default:          return .null
        }
    }

    private mutating func bytes(_ n: Int) -> [UInt8] {
        guard n > 0, index + n <= b.count else { index = b.count; return [] }
        defer { index += n }
        return Array(b[index..<index + n])
    }
    private mutating func str(_ n: Int) -> MsgValue { .string(String(bytes: bytes(n), encoding: .utf8) ?? "") }
    private mutating func bin(_ n: Int) -> MsgValue { .binary(bytes(n)) }
    private mutating func array(_ n: Int) -> MsgValue {
        var a: [MsgValue] = []
        for _ in 0..<n { if let v = read() { a.append(v) } }
        return .array(a)
    }
    private mutating func map(_ n: Int) -> MsgValue {
        var m: [(MsgValue, MsgValue)] = []
        for _ in 0..<n { if let k = read(), let v = read() { m.append((k, v)) } }
        return .map(m)
    }
}

// MARK: - CRC32 (IEEE) for exact database matching

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(fileAt url: URL) -> UInt32? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
