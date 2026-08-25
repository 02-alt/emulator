import Foundation

/// Errors a core can raise while loading content.
public enum EmulatorCoreError: Error, Sendable {
    case romNotFound(URL)
    case invalidROM(reason: String)
    case biosRequired
    case stateIncompatible
}

/// The one boundary the rest of the app talks to. A mock core and (later) the real
/// libmgba-backed core both conform to this, so nothing above it knows which is running.
///
/// Threading contract: a core instance is driven from a single dedicated emulation
/// thread. It is intentionally NOT `Sendable`; callers must not touch it concurrently.
public protocol EmulatorCore: AnyObject {
    /// Which system this core emulates.
    static var system: EmulatedSystem { get }

    /// Output framebuffer dimensions (== system native resolution).
    var videoSize: (width: Int, height: Int) { get }

    /// Audio sample rate the core produces, in Hz (stereo, interleaved Int16).
    var audioSampleRate: Int { get }

    /// Load a ROM. Replaces any currently loaded content.
    func loadROM(at url: URL) throws

    /// Optionally supply a BIOS image. GBA can run without one (less accurate).
    func loadBIOS(at url: URL) throws

    /// Reset to power-on state, keeping the loaded ROM.
    func reset()

    /// Advance emulation by exactly one video frame. After this returns, the frame's
    /// video and audio are ready to be drained.
    func runFrame()

    /// Copy the latest RGBA8888 framebuffer into `buffer`, which must hold at least
    /// `videoSize.width * videoSize.height` pixels.
    func copyVideo(into buffer: UnsafeMutablePointer<UInt32>)

    /// Drain up to `maxFrames` stereo sample-frames into `buffer` (2 * Int16 per frame).
    /// Returns the number of sample-frames actually written.
    func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int

    /// Set the currently-held buttons for the next `runFrame`.
    func setButtons(_ buttons: GBAButtons)

    /// Whether the loaded cartridge has a solar/light sensor (Boktai, Lunar Knights). Drives whether
    /// the UI offers a "light" control. Defaults to false for cores/games without one.
    var hasLightSensor: Bool { get }

    /// Feed the simulated ambient light the solar sensor reads, 0 (dark) … 255 (full sun). No-op on
    /// games without a light sensor.
    func setLuminance(_ value: UInt8)

    /// Serialize full machine state (for save states, rewind, and run-ahead).
    func saveState() throws -> Data

    /// Restore machine state previously produced by `saveState()`.
    func loadState(_ data: Data) throws

    /// Persistent cartridge save (battery/SRAM/flash), or nil if the game has none.
    var saveData: Data? { get }

    /// Load persistent cartridge save produced by a previous session.
    func loadSaveData(_ data: Data)
}

public extension EmulatorCore {
    /// Most cores/games have no light sensor, so both members are optional to implement.
    var hasLightSensor: Bool { false }
    func setLuminance(_ value: UInt8) {}

    /// Convenience: pack a pixel the way `copyVideo` emits them — memory byte order R,G,B,A,
    /// matching libmgba's native 32-bit color_t and Metal's `.rgba8Unorm`.
    @inline(__always)
    static func packRGBA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }
}
