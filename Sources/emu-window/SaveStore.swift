import Foundation

/// Resolves and reads/writes per-game save files under Application Support.
/// Layout:  ~/Library/Application Support/Emulator/saves/<game>/{battery.sav, suspend.state, slotN.state}
///
/// The folder is keyed by the ROM's short SHA-256 so renamed files still map to the same saves.
/// CloudKit sync (later) will mirror this directory.
struct SaveStore {
    let directory: URL

    init(romURL: URL) {
        let key = SaveStore.key(for: romURL)
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Emulator/saves", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
    }

    var batteryURL: URL { directory.appendingPathComponent("battery.sav") }
    var suspendURL: URL { directory.appendingPathComponent("suspend.state") }
    func slotURL(_ n: Int) -> URL { directory.appendingPathComponent("slot\(n).state") }
    /// A PNG thumbnail written alongside a save-state slot, so the states browser can show a preview.
    func slotThumbURL(_ n: Int) -> URL { directory.appendingPathComponent("slot\(n).png") }

    func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool {
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    /// Short content hash: SHA-256 of the ROM, first 16 hex chars, prefixed with a readable stem.
    private static func key(for romURL: URL) -> String {
        let stem = romURL.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: romURL) else { return stem }
        let hash = data.sha256HexPrefix(16)
        return "\(stem)-\(hash)"
    }
}
