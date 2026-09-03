import CryptoKit
import Foundation
import LibraryKit
import PSXCore

/// Validates and installs the user's PlayStation BIOS into `AppPaths.psxSystemDir`, and reports
/// whether one is present. The BIOS is copyrighted, so it's never bundled — the user brings their
/// own dump (from their own console) once, and the PS1 core reads it from the system directory.
enum PSXBios {

    /// Every genuine PS1 BIOS image is exactly 512 KiB.
    static let expectedByteCount = 512 * 1024

    /// Known-good BIOS images keyed by MD5 → the region-canonical filename Beetle PSX looks for and
    /// the region it belongs to. A recognized dump installs under its canonical name so the core's
    /// region auto-detect works. An MD5 we don't recognize can't be region-identified from the bytes,
    /// so onboarding asks the user which region it is (see `PSXBiosOnboarding`).
    static let knownBIOS: [String: (name: String, region: PSXRegion)] = [
        // v3.0 (the most common dumps)
        "8dd7d5296a650fac7319bce665a6a53c": ("scph5500.bin", .japan),
        "490f666e1afb15b7362b406ed1cea246": ("scph5501.bin", .america),
        "32736f17079d0b2b7024407c39bd3050": ("scph5502.bin", .europe),
        // v2.x
        "924e392ed05558ffdb115408c263dccf": ("scph1001.bin", .america),
        "239665b1a3dade1b5a52c06338011044": ("scph1000.bin", .japan),
        // v4.x
        "1e68c231d0896b7eadcad1d7d8e76129": ("scph7001.bin", .america),
        "b9d9a0286c33dc6b7237bb13cd46fdee": ("scph7002.bin", .europe),
        "6e3735ff4c7dc899ee98981385f6f3d0": ("scph101.bin", .america),
    ]

    enum ValidationError: LocalizedError {
        case unreadable
        case wrongSize(Int)
        case notABIOS

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file couldn’t be read."
            case .wrongSize(let n):
                let kb = n / 1024
                return "That file is \(kb) KB, but a PlayStation BIOS is exactly 512 KB. This looks like the wrong file."
            case .notABIOS:
                return "That’s a 512 KB file, but it isn’t a PlayStation BIOS — the console signature is missing."
            }
        }
    }

    /// True once at least one usable BIOS has been installed.
    static var isInstalled: Bool { PSXCore.hasBIOS(in: AppPaths.psxSystemDir) }

    /// Which regions currently have a BIOS installed, derived from the canonical filenames present.
    static var installedRegions: Set<PSXRegion> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.psxSystemDir.path)) ?? []
        return Set(names.compactMap { PSXRegion.of(biosFilename: $0) })
    }

    /// Regions with no BIOS yet — what onboarding still invites the user to add.
    static var missingRegions: [PSXRegion] {
        let have = installedRegions
        return PSXRegion.allCases.filter { !have.contains($0) }
    }

    /// Human-readable summary of what's installed, for the settings/onboarding UI.
    static var installedDescription: String? {
        let dir = AppPaths.psxSystemDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let bios = names.filter { PSXCore.biosNames.contains($0.lowercased()) }.sorted()
        return bios.isEmpty ? nil : bios.joined(separator: ", ")
    }

    /// A validated BIOS file, ready to install — with its region when the dump is recognized by MD5.
    struct Validated {
        let data: Data
        let known: (name: String, region: PSXRegion)?   // nil when the MD5 isn't in `knownBIOS`
    }

    /// Validate that the file at `url` is a genuine 512 KB PS1 BIOS. Does not write anything — the
    /// caller installs it once the region is settled (known by MD5, or picked by the user).
    static func validate(_ url: URL) throws -> Validated {
        guard let data = try? Data(contentsOf: url) else { throw ValidationError.unreadable }
        guard data.count == expectedByteCount else { throw ValidationError.wrongSize(data.count) }
        guard looksLikeBIOS(data) else { throw ValidationError.notABIOS }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Validated(data: data, known: knownBIOS[md5])
    }

    /// Install a validated BIOS under a region-canonical filename so the core's region auto-detect
    /// finds it. A recognized dump uses its own canonical name/region; an unrecognized one uses the
    /// `region` the user picked. Returns the installed filename.
    @discardableResult
    static func install(_ validated: Validated, as region: PSXRegion) throws -> String {
        let filename = validated.known?.name ?? region.biosFilename
        let dir = AppPaths.psxSystemDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try validated.data.write(to: dest)
        return filename
    }

    /// A genuine PS1 BIOS carries the ASCII "Sony Computer Entertainment" copyright string in its ROM.
    /// Checking for it rejects random same-sized files without needing an exhaustive hash list.
    private static func looksLikeBIOS(_ data: Data) -> Bool {
        let needle = Array("Sony Computer Entertainment".utf8)
        return data.range(of: Data(needle)) != nil
    }
}
