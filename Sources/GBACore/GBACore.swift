import EmulatorCore
import Foundation
import MGBABridge

/// The real GBA core: an `EmulatorCore` implemented on top of libmgba via the C bridge.
/// Drop-in interchangeable with `MockGBACore` — nothing above the protocol changes.
public final class GBACore: EmulatorCore {
    public static let system: EmulatedSystem = .gba

    private let handle: OpaquePointer
    public let videoSize: (width: Int, height: Int)
    public let audioSampleRate: Int

    public init() {
        guard let h = gba_bridge_create() else {
            fatalError("libmgba GBA core failed to initialize")
        }
        handle = h
        var w: UInt32 = 0
        var height: UInt32 = 0
        gba_bridge_dimensions(h, &w, &height)
        videoSize = (Int(w), Int(height))
        audioSampleRate = Int(gba_bridge_sample_rate(h))
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
