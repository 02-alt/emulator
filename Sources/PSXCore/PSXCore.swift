import EmulatorCore
import Foundation
import LibretroBridge

/// PlayStation 1 core: an `EmulatorCore` implemented on the Beetle PSX libretro core, driven through
/// the generic `LibretroBridge` host. Drop-in interchangeable with `GBACore`/`MockGBACore` — nothing
/// above the protocol knows it's libretro underneath.
///
/// Unlike the GBA, the PS1 changes framebuffer size per frame (256..640 wide, interlacing), so
/// `videoSize` reflects the last rendered frame and callers must re-read it each frame. It also
/// can't boot without a console BIOS placed in `systemDir`; `loadROM` throws `.biosRequired` when
/// none is present so the UI can run its BIOS onboarding.
public final class PSXCore: EmulatorCore {
    public static var system: EmulatedSystem { .ps1 }

    /// Native upper bound on the frame the PS1 emits at 1× — generous enough to cover every mode plus
    /// overscan borders (~700 wide / 576 tall interlaced). The real ceiling scales with
    /// `internalScale`, since a higher internal resolution multiplies both dimensions.
    public static let nativeMaxResolution = (width: 768, height: 576)

    private let handle: OpaquePointer
    private let systemDir: URL
    public private(set) var audioSampleRate: Int

    /// The video refresh rate the loaded disc actually runs at, per the core — **~59.94 Hz for NTSC,
    /// ~50 Hz for PAL** (European/French discs). A PAL game running at 50 fps is at 100% speed, not
    /// slow; the UI clocks "full speed" against this, not a fixed 60.
    public var nominalRefreshRate: Double {
        let f = libretro_bridge_fps(handle)
        return f > 1 ? f : Self.system.refreshRate
    }

    /// Internal render scale for 3D (1 = native, 2 = 2×, …). The software renderer honors this at a
    /// CPU cost; 2× sharpens polygons noticeably while staying playable on Apple Silicon. Applied at
    /// `loadROM` via the core's `internal_resolution` option.
    public var internalScale: Int = 2

    /// Whether this core is the Vulkan hardware renderer (loads the _hw dylib; enables GPU upscaling,
    /// texture filtering, widescreen at low cost). Set at init.
    public let hardware: Bool

    /// Render 3D anamorphically at 16:9 (the widescreen hack). 2D elements may stretch. Applied at
    /// `loadROM`; the host also widens the display aspect to match.
    public var widescreen: Bool = false

    public var videoSize: (width: Int, height: Int) {
        var w: UInt32 = 0
        var h: UInt32 = 0
        libretro_bridge_dimensions(handle, &w, &h)
        // Before the first frame the core hasn't reported a size; hand back the scaled max so callers
        // that size a buffer up front never under-allocate for a later, larger (upscaled) frame.
        if w == 0 || h == 0 {
            return (Self.nativeMaxResolution.width * internalScale,
                    Self.nativeMaxResolution.height * internalScale)
        }
        return (Int(w), Int(h))
    }

    /// - Parameters:
    ///   - corePath: the Beetle PSX libretro dylib. Defaults to the bundled/vendored core.
    ///   - systemDir: directory the core reads the PS1 BIOS from (scph5500/5501/5502.bin).
    ///   - saveDir: directory the core may write memory-card / save files into.
    public init(corePath: URL? = nil, systemDir: URL, saveDir: URL, hardware: Bool = false) throws {
        self.hardware = hardware
        let core = corePath ?? Self.defaultCorePath(hardware: hardware)
        guard FileManager.default.isReadableFile(atPath: core.path) else {
            throw EmulatorCoreError.invalidROM(reason: "PS1 core not found at \(core.path)")
        }
        try? FileManager.default.createDirectory(at: systemDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)

        guard let h = libretro_bridge_create(core.path, systemDir.path, saveDir.path) else {
            throw EmulatorCoreError.invalidROM(reason: "Beetle PSX core failed to initialize")
        }
        self.handle = h
        self.systemDir = systemDir
        self.audioSampleRate = Int(libretro_bridge_sample_rate(h).rounded())
    }

    deinit { libretro_bridge_destroy(handle) }

    public func loadROM(at url: URL) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw EmulatorCoreError.romNotFound(url)
        }
        guard Self.hasBIOS(in: systemDir) else {
            throw EmulatorCoreError.biosRequired
        }
        applyEnhancements()
        // Bound copyVideo to exactly the buffer the frontend allocates from `videoSize` (the scaled
        // max). PS1 resolution is dynamic, and the HW renderer can briefly report a frame over the max
        // at high internal scale; without this cap that frame's copy overruns the buffer and crashes.
        let maxW = Self.nativeMaxResolution.width * internalScale
        let maxH = Self.nativeMaxResolution.height * internalScale
        libretro_bridge_set_max_video_pixels(handle, UInt32(maxW * maxH))
        guard libretro_bridge_load_game(handle, url.path) else {
            throw EmulatorCoreError.invalidROM(reason: "Beetle PSX could not load \(url.lastPathComponent)")
        }
        audioSampleRate = Int(libretro_bridge_sample_rate(handle).rounded())
        // Default both ports to DualShock (analog) so games that need the sticks work.
        libretro_bridge_set_controller(handle, 0, Retro.deviceDualShock)
        libretro_bridge_set_controller(handle, 1, Retro.deviceDualShock)
    }

    /// The PS1 BIOS isn't handed to the core through a call — it's read from `systemDir` at load
    /// time. This copies the user-picked image in under a canonical name so a later `loadROM` finds
    /// it. Onboarding (which validates the image first) calls this once.
    public func loadBIOS(at url: URL) throws {
        let dest = systemDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try FileManager.default.copyItem(at: url, to: dest)
    }

    /// Turn on the visual enhancements the software renderer supports. PGXP "memory only" gives 3D
    /// geometry subpixel precision (kills the classic PS1 polygon wobble) for almost no cost; the
    /// internal-resolution scale sharpens 3D; dithering follows the internal resolution so it stays
    /// clean when upscaled.
    private func applyEnhancements() {
        let scale = ["1x(native)", "2x", "4x", "8x", "16x"]
        let res = scale[min(max(internalScale - 1, 0), scale.count - 1)]
        // The hardware core namespaces its options under beetle_psx_hw_.
        let p = hardware ? "beetle_psx_hw_" : "beetle_psx_"
        func opt(_ key: String, _ value: String) { libretro_bridge_set_option(handle, p + key, value) }
        if hardware {
            opt("renderer", "hardware_vk")
            // The Vulkan RHI keeps its own visible-scanline registers that default to 0 (the software
            // core instead initialises these in code). They're only populated from the option system,
            // and our bridge answers GET_VARIABLE with NULL for anything we don't override — so without
            // these the reported frame height collapses to ~1px (display_height = last - initial + 1,
            // e.g. 0-0+1 → 8px after 480i doubling ×4 upscale). Feed the core's own declared defaults.
            opt("initial_scanline", "0")
            opt("last_scanline", "239")
            opt("initial_scanline_pal", "0")
            opt("last_scanline_pal", "287")
        }
        opt("pgxp_mode", "memory only")
        opt("internal_resolution", res)
        opt("dither_mode", "internal resolution")
        opt("widescreen_hack", widescreen ? "enabled" : "disabled")
    }

    // MARK: - Multi-disc

    /// Number of discs in the loaded content (from a `.m3u`). 0/1 means single-disc — no swapping.
    public var discCount: Int { Int(libretro_bridge_disc_count(handle)) }
    /// The currently-inserted disc (0-based).
    public var currentDisc: Int { Int(libretro_bridge_disc_index(handle)) }
    /// Eject, swap to `index`, and re-insert. Use when a game asks you to change discs.
    public func setDisc(_ index: Int) { _ = libretro_bridge_set_disc(handle, UInt32(index)) }

    public func reset() { libretro_bridge_reset(handle) }
    public func runFrame() { libretro_bridge_run_frame(handle) }

    public func copyVideo(into buffer: UnsafeMutablePointer<UInt32>) {
        libretro_bridge_video(handle, buffer)
    }

    public func readAudio(into buffer: UnsafeMutablePointer<Int16>, maxFrames: Int) -> Int {
        Int(libretro_bridge_read_audio(handle, buffer, Int32(maxFrames)))
    }

    /// GBA-key path (protocol requirement / headless runner): a subset of the full input.
    public func setButtons(_ buttons: GBAButtons) { setInput(PadInput(gba: buttons)) }

    /// Full DualShock mapping: face shapes, d-pad, both shoulder pairs, thumb-clicks, and both
    /// analog sticks. PS1 face layout follows the RetroPad convention — south=✕, east=○, west=▢,
    /// north=△.
    public func setInput(_ input: PadInput) {
        let b = input.buttons
        var mask: UInt16 = 0
        func set(_ flag: PadButtons, _ id: UInt16) { if b.contains(flag) { mask |= (1 << id) } }
        set(.south, Retro.idB)          // ✕ cross
        set(.east, Retro.idA)           // ○ circle
        set(.west, Retro.idY)           // ▢ square
        set(.north, Retro.idX)          // △ triangle
        set(.up, Retro.idUp)
        set(.down, Retro.idDown)
        set(.left, Retro.idLeft)
        set(.right, Retro.idRight)
        set(.l1, Retro.idL)
        set(.r1, Retro.idR)
        set(.l2, Retro.idL2)
        set(.r2, Retro.idR2)
        set(.l3, Retro.idL3)
        set(.r3, Retro.idR3)
        set(.start, Retro.idStart)
        set(.select, Retro.idSelect)
        libretro_bridge_set_joypad(handle, 0, mask)

        // libretro analog: +Y is down, so flip our +Y-is-up convention. Index 0 = left stick,
        // 1 = right; axis 0 = X, 1 = Y.
        libretro_bridge_set_analog(handle, 0, 0, 0, input.leftX)
        libretro_bridge_set_analog(handle, 0, 0, 1, Int16(clamping: -Int(input.leftY)))
        libretro_bridge_set_analog(handle, 0, 1, 0, input.rightX)
        libretro_bridge_set_analog(handle, 0, 1, 1, Int16(clamping: -Int(input.rightY)))
    }

    public func saveState() throws -> Data {
        let size = libretro_bridge_state_size(handle)
        guard size > 0 else { throw EmulatorCoreError.stateIncompatible }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { raw in
            libretro_bridge_save_state(handle, raw.baseAddress, size)
        }
        guard ok else { throw EmulatorCoreError.stateIncompatible }
        return data
    }

    public func loadState(_ data: Data) throws {
        let ok = data.withUnsafeBytes { raw in
            libretro_bridge_load_state(handle, raw.baseAddress, data.count)
        }
        guard ok else { throw EmulatorCoreError.stateIncompatible }
    }

    public var saveData: Data? {
        let size = libretro_bridge_save_ram_size(handle)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let ok = data.withUnsafeMutableBytes { raw in
            libretro_bridge_get_save_ram(handle, raw.baseAddress)
        }
        return ok ? data : nil
    }

    public func loadSaveData(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = libretro_bridge_set_save_ram(handle, raw.baseAddress, data.count)
        }
    }

    // MARK: - BIOS discovery

    /// PS1 region BIOS filenames Beetle PSX looks for. Any one present is enough to boot most games.
    public static let biosNames = ["scph5500.bin", "scph5501.bin", "scph5502.bin",
                                   "scph1001.bin", "scph7001.bin", "scph101.bin"]

    public static func hasBIOS(in dir: URL) -> Bool {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let lower = Set(names.map { $0.lowercased() })
        return biosNames.contains { lower.contains($0) }
    }

    // MARK: - Core location

    /// Where the bundled PS1 core lives. Overridable via `EMU_PSX_CORE` for headless/dev runs; else
    /// the app bundle's Resources; else the vendored dev build.
    public static func defaultCorePath(hardware: Bool = false) -> URL {
        let name = hardware ? "mednafen_psx_hw_libretro" : "mednafen_psx_libretro"
        if !hardware, let env = ProcessInfo.processInfo.environment["EMU_PSX_CORE"] {
            return URL(fileURLWithPath: env)
        }
        if hardware, let env = ProcessInfo.processInfo.environment["EMU_PSX_HW_CORE"] {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.url(forResource: name, withExtension: "dylib") {
            return res
        }
        // Dev fallback: the vendored build output, relative to the package root.
        return URL(fileURLWithPath: "vendor/beetle-psx-libretro/\(name).dylib")
    }
}

/// libretro constants we need Swift-side, mirrored from libretro.h (which the bridge module keeps
/// internal). Values are part of the stable libretro ABI.
private enum Retro {
    // RETRO_DEVICE_ID_JOYPAD_*
    static let idB: UInt16 = 0, idY: UInt16 = 1, idSelect: UInt16 = 2, idStart: UInt16 = 3
    static let idUp: UInt16 = 4, idDown: UInt16 = 5, idLeft: UInt16 = 6, idRight: UInt16 = 7
    static let idA: UInt16 = 8, idX: UInt16 = 9, idL: UInt16 = 10, idR: UInt16 = 11
    static let idL2: UInt16 = 12, idR2: UInt16 = 13, idL3: UInt16 = 14, idR3: UInt16 = 15
    // RETRO_DEVICE_DUALSHOCK == (1 << 8) | RETRO_DEVICE_JOYPAD(1)
    static let deviceDualShock: UInt32 = (1 << 8) | 1
}
