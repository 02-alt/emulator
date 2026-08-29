import Foundation
import EmulatorCore
import GBACore
import LibraryKit

/// Builds the emulator core for a library game. Uses the real libmgba-backed cores — `GBACore` for
/// Game Boy Advance carts, `GBCore` for Game Boy / Game Boy Color — picked from the game's system.
/// If the ROM can't be loaded (missing file, bad dump) it falls back to the ROM-free `MockGBACore`
/// so the play screen still comes up rather than crashing.
enum CoreProvider {
    static func core(for game: Game) -> (core: EmulatorCore, isReal: Bool) {
        let core: EmulatorCore = game.system == .gbc ? GBCore() : GBACore()
        do {
            try core.loadROM(at: resolvedROMURL(for: game))   // GBA runs BIOS-less (slightly less accurate)
            return (core, true)
        } catch {
            return (MockGBACore(), false)
        }
    }

    /// Resolve a game's ROM against the *current* ROM store. LibraryKit persists an absolute
    /// `romPath`, which is stable on macOS but NOT on iOS — the app's sandbox container UUID changes
    /// across reinstalls/updates, so a stored absolute path goes stale. ROMs always live at
    /// `romsDir/<filename>` in the live container, so rebuild the URL there; fall back to the stored
    /// path only if that file is somehow missing.
    static func resolvedROMURL(for game: Game) -> URL {
        let filename = URL(fileURLWithPath: game.romPath).lastPathComponent
        let inStore = AppPaths.romsDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: inStore.path) ? inStore : game.romURL
    }
}

/// Per-game on-disk save location: <App Support>/Emulator/saves/<romHash>/ holding `battery.sav`
/// (cartridge SRAM/flash) and `state.bin` (full save state).
enum SavePaths {
    static func directory(forHash hash: String) -> URL {
        let dir = AppPaths.appSupport
            .appendingPathComponent("saves", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
