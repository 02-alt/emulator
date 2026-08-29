import CryptoKit
import Foundation

/// Computes the RetroAchievements identity hash for a PlayStation disc. RA doesn't hash the whole
/// image (too variable) — it locates the disc's **boot executable** (via `SYSTEM.CNF`) and hashes its
/// name followed by its header + code, exactly as rcheevos does, so the same game matches regardless
/// of dump padding. Supports `.cue`/`.bin` (the common case); `.chd`/`.pbp` are not yet handled.
public enum PSXDiscHash {
    private static let logicalSectorSize = 2048

    /// The disc's boot-executable name (from SYSTEM.CNF), e.g. "SLES_015.06" — the identity RA hashes.
    public static func bootExecutableName(for url: URL) -> String? {
        guard let track = Track(cueOrBin: url), let syscnf = track.readFile(named: "SYSTEM.CNF")
        else { return nil }
        return parseBoot(String(decoding: syscnf, as: UTF8.self))
    }

    /// The RA hash (32-char lowercase hex) for the disc at `url`, or nil if it can't be read/parsed.
    public static func raHash(for url: URL) -> String? {
        guard let track = Track(cueOrBin: url) else { return nil }

        // The primary executable's path lives in SYSTEM.CNF: `BOOT = cdrom:\SLUS_007.76;1`.
        guard let syscnf = track.readFile(named: "SYSTEM.CNF"),
              let bootName = parseBoot(String(decoding: syscnf, as: UTF8.self))
        else {
            // Some early discs boot PSX.EXE directly with no SYSTEM.CNF.
            if let exe = track.readFile(named: "PSX.EXE") { return hash(name: "PSX.EXE", exe: exe) }
            return nil
        }
        guard let exe = track.readFile(named: bootName) else { return nil }
        return hash(name: bootName, exe: exe)
    }

    /// `MD5(exe_name_ascii + exe[0 ..< 0x800 + t_size])`, where `t_size` is the PS-X EXE header's
    /// text-segment size — matching rcheevos so padding beyond the real code is ignored.
    private static func hash(name: String, exe: [UInt8]) -> String {
        var md5 = Insecure.MD5()
        md5.update(data: Data(name.utf8))
        var count = exe.count
        if exe.count >= 0x800, Array(exe[0..<8]) == Array("PS-X EXE".utf8) {
            let tSize = Int(u32(exe, 0x1C))
            count = min(exe.count, 0x800 + tSize)
        }
        md5.update(data: Data(exe[0..<count]))
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Extract the executable name from a `BOOT = cdrom:\NAME;1` line (path + version stripped).
    static func parseBoot(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.uppercased().hasPrefix("BOOT"), let eq = l.firstIndex(of: "=") else { continue }
            var value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let range = value.range(of: #"cdrom:\\?"#, options: [.regularExpression, .caseInsensitive]) {
                value = String(value[range.upperBound...])
            }
            value = value.components(separatedBy: ";").first ?? value       // drop ";1"
            value = value.replacingOccurrences(of: "\\", with: "/")          // any subdir → forward
            let name = value.components(separatedBy: "/").last ?? value       // filename only
            // Hashed verbatim (rcheevos does not case-fold); the file lookup is case-insensitive.
            return name.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    // MARK: - Track (a single .bin data track + its ISO9660 filesystem)

    private struct Track {
        let handle: FileHandle
        let rawSectorSize: Int   // 2352 (raw) or 2048 (iso)
        let dataOffset: Int      // bytes into each raw sector where the 2048 user data starts

        init?(cueOrBin url: URL) {
            var binURL = url
            var raw = 2352
            var offset = 24         // Mode2/Form1 default (12 sync + 4 header + 8 subheader)
            if url.pathExtension.lowercased() == "cue" {
                guard let cue = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let dir = url.deletingLastPathComponent()
                guard let (file, mode) = PSXDiscHash.firstDataTrack(cue) else { return nil }
                binURL = dir.appendingPathComponent(file)
                (raw, offset) = PSXDiscHash.geometry(for: mode)
            } else if ["iso", "img"].contains(url.pathExtension.lowercased()) {
                raw = 2048; offset = 0
            }
            guard let h = try? FileHandle(forReadingFrom: binURL) else { return nil }
            handle = h; rawSectorSize = raw; dataOffset = offset
        }

        /// The 2048-byte user data of logical sector `lba`.
        func sector(_ lba: Int) -> [UInt8]? {
            let pos = UInt64(lba * rawSectorSize + dataOffset)
            try? handle.seek(toOffset: pos)
            guard let d = try? handle.read(upToCount: logicalSectorSize), d.count == logicalSectorSize else { return nil }
            return [UInt8](d)
        }

        /// Read a file from the ISO9660 root directory by name (case-insensitive, ";1" ignored).
        func readFile(named name: String) -> [UInt8]? {
            guard let pvd = sector(16), pvd.count > 190,
                  Array(pvd[1..<6]) == Array("CD001".utf8) else { return nil }
            let rootLBA = Int(PSXDiscHash.u32(pvd, 156 + 2))
            let rootSize = Int(PSXDiscHash.u32(pvd, 156 + 10))
            guard let entry = findEntry(name: name, dirLBA: rootLBA, dirSize: rootSize) else { return nil }
            return readExtent(lba: entry.lba, size: entry.size)
        }

        private func findEntry(name: String, dirLBA: Int, dirSize: Int) -> (lba: Int, size: Int)? {
            let want = name.uppercased()
            let sectors = (dirSize + logicalSectorSize - 1) / logicalSectorSize
            for s in 0..<sectors {
                guard let data = sector(dirLBA + s) else { break }
                var i = 0
                while i < data.count {
                    let len = Int(data[i])
                    if len == 0 { break }   // rest of this sector is padding
                    if i + len <= data.count, i + 33 < data.count {
                        let nameLen = Int(data[i + 32])
                        let nameBytes = Array(data[(i + 33)..<(i + 33 + nameLen)])
                        var entryName = String(bytes: nameBytes, encoding: .ascii) ?? ""
                        entryName = entryName.components(separatedBy: ";").first ?? entryName
                        if entryName.uppercased() == want {
                            return (Int(PSXDiscHash.u32(data, i + 2)), Int(PSXDiscHash.u32(data, i + 10)))
                        }
                    }
                    i += len
                }
            }
            return nil
        }

        private func readExtent(lba: Int, size: Int) -> [UInt8]? {
            var out = [UInt8]()
            out.reserveCapacity(size)
            var remaining = size
            var s = lba
            while remaining > 0 {
                guard let data = sector(s) else { return out.isEmpty ? nil : out }
                out.append(contentsOf: data.prefix(remaining))
                remaining -= min(remaining, logicalSectorSize)
                s += 1
            }
            return out
        }
    }

    /// First data track's file + mode from a .cue sheet.
    static func firstDataTrack(_ cue: String) -> (file: String, mode: String)? {
        var currentFile: String?
        for line in cue.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("FILE"),
               let q1 = l.firstIndex(of: "\""), let q2 = l[l.index(after: q1)...].firstIndex(of: "\"") {
                currentFile = String(l[l.index(after: q1)..<q2])
            } else if l.uppercased().hasPrefix("TRACK"), let file = currentFile {
                // "TRACK 01 MODE2/2352" — the first data (non-AUDIO) track holds the filesystem.
                let mode = l.uppercased()
                if mode.contains("MODE") { return (file, mode) }
            }
        }
        return nil
    }

    /// Raw sector size + user-data offset for a .cue track mode.
    static func geometry(for mode: String) -> (raw: Int, offset: Int) {
        if mode.contains("2352") {
            return mode.contains("MODE1") ? (2352, 16) : (2352, 24)   // MODE1 header 16, MODE2 header 24
        }
        return (2048, 0)                                              // MODE1/2048 or plain ISO
    }
}
