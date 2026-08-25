import EmulatorCore
import Foundation
import MGBABridge

/// A real mGBA core: an `EmulatorCore` implemented on top of libmgba via the C bridge. The mCore API
/// is platform-agnostic — one Swift wrapper drives both the Game Boy Advance and the Game Boy /
/// Game Boy Color cores; only which core the bridge creates (and its `system`) differs. Drop-in
/// interchangeable with `MockGBACore` — nothing above the protocol changes.
public class MGBACore: EmulatorCore {
    /// Overridden by each concrete subclass to report which console it emulates.
    public class var system: EmulatedSystem { .gba }

    /// Identifies this exact core build for savestate compatibility (Continuity's version gate).
    /// Derived from the linked libmgba (`projectVersion`) rather than a hand-typed constant, so
    /// macOS and iOS — which build the same mGBA source — always report the same value. A mismatch
    /// here blocks every cross-device resume, so the two platforms must agree exactly.
    public static var coreVersion: String {
        "mgba-\(String(cString: gba_bridge_core_version()))"
    }

    private let handle: OpaquePointer
    public let audioSampleRate: Int

    /// Queried live rather than cached: the GB/GBC core only reports its final output size once a ROM
    /// is loaded (see `bridge_sync_dimensions`), and `loadROM(at:)` runs after this initializer. The
    /// driver reads this after loading, so it always sees the loaded game's true resolution.
    public var videoSize: (width: Int, height: Int) {
        var w: UInt32 = 0
        var h: UInt32 = 0
        gba_bridge_dimensions(handle, &w, &h)
        return (Int(w), Int(h))
    }

    /// - Parameter handle: a live bridge core, already created for the intended platform.
    init(handle: OpaquePointer) {
        self.handle = handle
        audioSampleRate = Int(gba_bridge_sample_rate(handle))
    }

    deinit { gba_bridge_destroy(handle) }

    public func loadROM(at url: URL) throws {
        guard gba_bridge_load_rom(handle, url.path) else {
            throw EmulatorCoreError.invalidROM(reason: "libmgba could not load \(url.lastPathComponent)")
        }
    }

    public func loadBIOS(at url: URL) throws {
        // TODO: optional high-accuracy BIOS support (mgba runs BIOS-less by default).
    }

    public func reset() { gba_bridge_reset(handle) }
    public func runFrame() { gba_bridge_run_frame(handle) }

    public func copyVideo(into buffer: UnsafeMutablePointer<UInt32>) {
        gba_bridge_video(handle, buffer)
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        Int(gba_bridge_read_audio(handle, buffer, Int32(maxFrames)))
    }

    public func setButtons(_ buttons: GBAButtons) {
        gba_bridge_set_keys(handle, buttons.rawValue)
    }

    public var hasLightSensor: Bool { gba_bridge_has_light_sensor(handle) }

    public func setLuminance(_ value: UInt8) { gba_bridge_set_luminance(handle, value) }

    public func saveState() throws -> Data {
        let size = gba_bridge_state_size(handle)
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { raw in
            gba_bridge_save_state(handle, raw.baseAddress, size)
        }
        guard ok else { throw EmulatorCoreError.stateIncompatible }
        return data
    }

    public func loadState(_ data: Data) throws {
        let ok = data.withUnsafeBytes { raw in
            gba_bridge_load_state(handle, raw.baseAddress, data.count)
        }
        guard ok else { throw EmulatorCoreError.stateIncompatible }
    }

    public var saveData: Data? {
        var ptr: UnsafeMutableRawPointer?
        let size = gba_bridge_save_data(handle, &ptr)
        guard size > 0, let ptr else { return nil }
        defer { gba_bridge_free(ptr) }
        return Data(bytes: ptr, count: size)
    }

    public func loadSaveData(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = gba_bridge_load_save_data(handle, raw.baseAddress, data.count)
        }
    }
}

/// The Game Boy Advance core.
public final class GBACore: MGBACore {
    public override class var system: EmulatedSystem { .gba }

    public init() {
        guard let h = gba_bridge_create_system(Int32(BRIDGE_PLATFORM_GBA.rawValue)) else {
            fatalError("libmgba GBA core failed to initialize")
        }
        super.init(handle: h)
    }
}

/// The Game Boy / Game Boy Color core (same mGBA "GB" core handles both).
public final class GBCore: MGBACore {
    public override class var system: EmulatedSystem { .gbc }

    public init() {
        guard let h = gba_bridge_create_system(Int32(BRIDGE_PLATFORM_GB.rawValue)) else {
            fatalError("libmgba Game Boy core failed to initialize")
        }
        super.init(handle: h)
    }
}
