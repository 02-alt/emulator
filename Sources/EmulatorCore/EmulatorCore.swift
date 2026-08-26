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

    /// The video refresh rate the loaded content actually runs at (frames/sec). Fixed per system for
    /// the handhelds, but the PS1 differs by region — ~59.94 Hz NTSC vs ~50 Hz PAL — so "% of full
    /// speed" must be measured against this, not a hardcoded 60. Defaults to the system's nominal rate.
    var nominalRefreshRate: Double { get }

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

    /// Set the currently-held buttons for the next `runFrame`. GBA-shaped; kept for the GBA cores
    /// and the headless runner. New code drives cores through `setInput` instead.
    func setButtons(_ buttons: GBAButtons)

    /// Set the full system-agnostic controller state (buttons + analog sticks) for the next
    /// `runFrame`. The default projects it onto `setButtons`, so GBA-only cores need do nothing;
    /// cores with more inputs (PS1) override this to consume all of it.
    func setInput(_ input: PadInput)

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

    /// Number of discs in the loaded content (multi-disc PS1 games). 0/1 = single-disc, no switching.
    var discCount: Int { get }
    /// Swap to disc `index` (eject → insert), for a game that asks you to change discs mid-play.
    func setDisc(_ index: Int)

    /// Persistent cartridge save (battery/SRAM/flash), or nil if the game has none.
    var saveData: Data? { get }

    /// Load persistent cartridge save produced by a previous session.
    func loadSaveData(_ data: Data)
}

public extension EmulatorCore {
    /// Most cores/games have no light sensor, so both members are optional to implement.
    var hasLightSensor: Bool { false }
    func setLuminance(_ value: UInt8) {}

    /// Default: a core that only understands GBA keys sees the GBA projection of the full input.
    func setInput(_ input: PadInput) { setButtons(input.gbaButtons) }

    /// Default: the system's fixed nominal rate. Cores whose content varies by region (PS1) override.
    var nominalRefreshRate: Double { Self.system.refreshRate }

    /// Default: single-disc systems have no disc switching.
    var discCount: Int { 0 }
    func setDisc(_ index: Int) {}

    /// Convenience: pack a pixel the way `copyVideo` emits them — memory byte order R,G,B,A,
    /// matching libmgba's native 32-bit color_t and Metal's `.rgba8Unorm`.
    @inline(__always)
    static func packRGBA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
        UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (UInt32(a) << 24)
    }
}
