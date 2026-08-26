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

    /// Known-good BIOS images keyed by MD5 → the region-canonical filename Beetle PSX looks for. A
    /// recognized dump is installed under its canonical name so the core's region auto-detect works;
    /// an unrecognized-but-valid dump keeps the user's own filename.
    static let knownBIOS: [String: (name: String, region: String)] = [
        "8dd7d5296a650fac7319bce665a6a53c": ("scph5500.bin", "Japan"),
        "490f666e1afb15b7362b406ed1cea246": ("scph5501.bin", "North America"),
        "32736f17079d0b2b7024407c39bd3050": ("scph5502.bin", "Europe"),
        "924e392ed05558ffdb115408c263dccf": ("scph1001.bin", "North America"),
        "239665b1a3dade1b5a52c06338011044": ("scph1000.bin", "Japan"),
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

    /// True once a usable BIOS has been installed.
    static var isInstalled: Bool { PSXCore.hasBIOS(in: AppPaths.psxSystemDir) }

    /// Human-readable summary of what's installed, for the settings/onboarding UI.
    static var installedDescription: String? {
        let dir = AppPaths.psxSystemDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let bios = names.filter { PSXCore.biosNames.contains($0.lowercased()) }.sorted()
        return bios.isEmpty ? nil : bios.joined(separator: ", ")
    }

    /// Validate the file at `url` is a real PS1 BIOS, then copy it into the system directory under a
    /// region-canonical name when recognized (else its own name). Returns the installed filename.
    @discardableResult
    static func install(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw ValidationError.unreadable }
        guard data.count == expectedByteCount else { throw ValidationError.wrongSize(data.count) }
        guard looksLikeBIOS(data) else { throw ValidationError.notABIOS }

        // A recognized dump installs under its region-canonical name so the core's region
        // auto-detect works. An unrecognized-but-valid dump can't be region-identified, so install
        // it under the common NA name — a name both our detection and the core will find (PS1 BIOSes
        // boot games near-interchangeably across regions).
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = knownBIOS[md5]?.name ?? "scph5501.bin"

        let dir = AppPaths.psxSystemDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest)
        return filename
    }

    /// A genuine PS1 BIOS carries the ASCII "Sony Computer Entertainment" copyright string in its ROM.
    /// Checking for it rejects random same-sized files without needing an exhaustive hash list.
    private static func looksLikeBIOS(_ data: Data) -> Bool {
        let needle = Array("Sony Computer Entertainment".utf8)
        return data.range(of: Data(needle)) != nil
    }
}
