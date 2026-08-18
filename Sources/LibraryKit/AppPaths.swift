import Foundation

/// Shared on-disk locations under Application Support.
public enum AppPaths {
    /// ~/Library/Application Support/Emulator
    public static var appSupport: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Emulator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static var libraryFile: URL { appSupport.appendingPathComponent("library.json") }
    /// Imported ROMs are copied here so the library never breaks if the originals move/delete.
    public static var romsDir: URL { subdir("roms") }
    public static var coversDir: URL { subdir("covers") }
    public static var snapsDir: URL { subdir("snaps") }
    public static var screenshotsDir: URL { subdir("screenshots") }

    private static func subdir(_ name: String) -> URL {
        let url = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
