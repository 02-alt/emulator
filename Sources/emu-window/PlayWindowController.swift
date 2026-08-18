import AppKit
import EmulatorCore
import GBACore
import LibraryKit
import MetalKit

/// Per-game overrides a session applies over the global ``Settings`` at launch. Each `nil` means
/// "inherit the app default". Built by the library from a ``Game``'s stored per-game settings.
struct GameOverrides {
    var filter: Settings.DisplayFilter?
    var speed: Double?
    var swapAB: Bool?

    /// True when nothing is overridden — the session then behaves exactly as before.
    var isEmpty: Bool { filter == nil && speed == nil && swapAB == nil }
}

/// One play session: owns the core/driver/audio/controllers/render surface for a single ROM (or the
/// mock) and handles save persistence. It is **host-agnostic** — its ``view`` is embedded either in
/// the Library window (in place of the shelf dashboard) or in a standalone window (for a direct
/// `--rom` / `--mock` launch). The host is responsible for calling ``saveAndStop()`` when it tears
/// the session down.
@MainActor
final class PlaySession: NSObject {
    private let driver: EmulationDriver
    private let audio: AudioOutput
    private let controllers: GameControllerManager
    private let renderer: Renderer
    private let metalView: EmulatorMetalView
    private let void: PlayVoidView
    private let saveStore: SaveStore?
    private var batteryTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var settingsOverlay: SettingsOverlayView?
    private var pip: PiPWindowController?
    private let overrides: GameOverrides
    private var didTeardown = false

    let displayTitle: String
    private let isRealROM: Bool
    private let sessionStart = Date()
    /// True when the audio engine failed to start — the host surfaces a non-blocking notice.
    private(set) var audioStartFailed = false

    /// The view a host embeds to show the game.
    var view: NSView { void }
    /// Ensure the player is in edge-to-edge Fill mode (the default presentation).
    func enterFill() { void.enterFillIfNeeded() }
    /// The view that should be made first responder for keyboard input.
    var keyView: NSView { metalView }
    /// The game screen's rounded panel, in the host content view's coordinates — the launch cinematic
    /// morphs the boot-clip screen into this rect so the GBA intro becomes the game seamlessly.
    var gameScreenFrame: CGRect { void.convert(metalView.bounds, from: metalView) }

    /// Reports seconds played this session (real ROMs only), for library playtime tracking.
    var onPlaytime: ((Int) -> Void)?
    /// The player asked to leave the game (Back button / Esc). The host returns to the library or
    /// closes the standalone window.
    var onExit: (() -> Void)?

    /// - Parameters:
    ///   - romURL: a real ROM, or nil to run the mock core.
    ///   - overrides: per-game settings applied over the global ``Settings`` (defaults to none).
    init(romURL: URL?, title: String, overrides: GameOverrides = GameOverrides()) {
        self.displayTitle = title
        self.isRealROM = romURL != nil
        self.overrides = overrides
        let core: EmulatorCore
        var store: SaveStore?
        if let romURL {
            let gba = GBACore()
            var loaded = false
            do { try gba.loadROM(at: romURL); loaded = true }
            catch { NSLog("Failed to load ROM \(romURL.path): \(error)") }
            if loaded {
                let s = SaveStore(romURL: romURL)
                if let battery = s.read(s.batteryURL) {
                    gba.loadSaveData(battery)
                    NSLog("Loaded battery save (\(battery.count) bytes)")
                }
                if Settings.shared.autoResume, let suspend = s.read(s.suspendURL) {
                    do { try gba.loadState(suspend); NSLog("Auto-resumed from suspend state") }
                    catch { NSLog("Suspend state incompatible — starting fresh") }
                }
                store = s
                core = gba
            } else {
                // A corrupt/unreadable ROM must never crash the app. The library pre-validates with
                // `canOpen(_:)` and shows an alert, so this is only a last resort (e.g. the file
                // changed between the check and the load) — run the mock core rather than die.
                core = MockGBACore()
            }
        } else {
            core = MockGBACore()
        }
        self.saveStore = store

        let driver = EmulationDriver(core: core)
        self.driver = driver
        let audio = AudioOutput(ring: driver.ring, sampleRate: driver.sampleRate)
        do { try audio.start() } catch { NSLog("Audio failed to start: \(error)"); audioStartFailed = true }
        audio.setVolume(Settings.shared.volume)
        driver.setRewindEnabled(Settings.shared.rewindEnabled)
        driver.setSwapAB(overrides.swapAB ?? Settings.shared.swapAB)
        self.audio = audio
        self.controllers = GameControllerManager(driver: driver)

        let view = EmulatorMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.driver = driver
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        self.renderer = Renderer(driver: driver, view: view)
        self.metalView = view
        view.delegate = renderer

        // Strip the app-name prefix so the void status line shows just the game's title.
        let cleanTitle = title.components(separatedBy: " — ").last ?? title
        let void = PlayVoidView(title: cleanTitle, metalView: view)
        self.void = void

        super.init()

        view.onSave = { [weak self] in self?.quickSave() }
        view.onLoad = { [weak self] in self?.quickLoad() }
        view.onScreenshot = { [weak self] in self?.saveScreenshot() }
        view.onOpenSettings = { [weak self] in self?.toggleSettings() }
        // Keyboard parity for the controller guide (Tab opens; arrows/Return/Esc navigate).
        view.guideIsOpen = { [weak void] in void?.isGuideOpen ?? false }
        view.onToggleGuide = { [weak void] in void?.toggleGuide() }
        view.onGuideMove = { [weak void] next in void?.guideMove(next) }
        view.onGuideAdjust = { [weak void] increase in void?.guideAdjust(increase) }
        view.onGuideActivate = { [weak void] in void?.guideActivate() }
        view.onGuideClose = { [weak void] in void?.guideBack() }
        // Esc: in immersive full screen, drop back to windowed first; otherwise leave the game.
        view.onExit = { [weak self] in
            guard let self else { return }
            if self.void.exitImmersiveIfActive() { return }
            self.onExit?()
        }
        void.onOpenSettings = { [weak self] in self?.toggleSettings() }
        void.onExit = { [weak self] in self?.onExit?() }
        void.onTogglePiP = { [weak self] in self?.togglePiP() }

        // Controller "guide": the pad's Home button (or L3+R3) opens a paused, pad-navigable overlay.
        controllers.isGuideOpen = { [weak void] in void?.isGuideOpen ?? false }
        controllers.onGuideToggle = { [weak void] in void?.toggleGuide() }
        controllers.onGuideMove = { [weak void] next in void?.guideMove(next) }
        controllers.onGuideAdjust = { [weak void] increase in void?.guideAdjust(increase) }
        controllers.onGuideActivate = { [weak void] in void?.guideActivate() }
        controllers.onGuideClose = { [weak void] in void?.guideBack() }

        // Per-game overrides over the global defaults: pin the display filter for this surface, and
        // launch at the game's preferred speed (reflected on the toolbar toggle).
        renderer.filterOverride = overrides.filter
        if let speed = overrides.speed { void.setSpeedDisplay(speed) }
        driver.start()

        // Apply Settings changes to this live session (volume + rewind capture) without a restart. The
        // per-game A/B swap wins over the global one so a settings change elsewhere can't clobber it.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audio.setVolume(Settings.shared.volume)
                self.driver.setRewindEnabled(Settings.shared.rewindEnabled)
                self.driver.setSwapAB(self.overrides.swapAB ?? Settings.shared.swapAB)
            }
        }

        if store != nil {
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushBattery() }
            }
        }
    }

    /// Save state + battery and stop the engine. Idempotent; safe to call on exit or app quit.
    func saveAndStop() {
        guard !didTeardown else { return }
        didTeardown = true
        // Stop rendering FIRST so the Metal view can't call the renderer (which reads the driver)
        // while we tear the driver/core down. The PiP mini-window shares the driver, so close it too.
        pip?.close()
        pip = nil
        metalView.isPaused = true
        metalView.delegate = nil
        batteryTimer?.invalidate()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let store = saveStore {
            if let battery = driver.cloneSaveData() { store.write(battery, to: store.batteryURL) }
            // Only persist a suspend state when Auto-Resume is on — otherwise leave none so the next
            // launch boots fresh (and don't strand a stale one from a previous session).
            if Settings.shared.autoResume {
                if let state = driver.saveState() { store.write(state, to: store.suspendURL) }
            } else {
                store.remove(store.suspendURL)
            }
        }
        driver.stop()
        audio.stop()

        if isRealROM {
            onPlaytime?(Int(Date().timeIntervalSince(sessionStart)))
        }
    }

    // MARK: - Picture in Picture

    /// Float (or close) a small always-on-top mini-window mirroring this game. It shares the driver, so
    /// it stays fully playable; opening it doesn't pause or change the main window.
    private func togglePiP() {
        if let pip {
            pip.close()   // its onClose resets `pip` and the toolbar button below
            return
        }
        let controller = PiPWindowController(driver: driver, title: displayTitle)
        controller.onClose = { [weak self] in
            self?.pip = nil
            self?.void.setPiPActive(false)
        }
        pip = controller
        void.setPiPActive(true)
    }

    // MARK: - In-window Settings

    /// Show (or hide) the Settings overlay **inside the play view** — no separate window. The game
    /// keeps running behind a dimmed scrim; dismissing restores keyboard focus to the emulator.
    private func toggleSettings() {
        if let overlay = settingsOverlay { overlay.dismiss(); return }
        let overlay = SettingsOverlayView(frame: void.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClose = { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            guard let self else { return }
            self.settingsOverlay = nil
            self.void.window?.makeFirstResponder(self.metalView)
        }
        void.addSubview(overlay)
        void.window?.makeFirstResponder(overlay)
        settingsOverlay = overlay
    }

    // MARK: - Screenshot

    private func saveScreenshot() {
        let w = driver.width, h = driver.height
        var buffer = [UInt32](repeating: 0, count: w * h)
        buffer.withUnsafeMutableBufferPointer { driver.copyLatestFrame(into: $0.baseAddress!) }
        guard let png = PlaySession.pngData(rgba: buffer, width: w, height: h) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = displayTitle.replacingOccurrences(of: "/", with: "-")
        let url = AppPaths.screenshotsDir.appendingPathComponent("\(safe) \(stamp).png")
        do { try png.write(to: url); NSLog("Screenshot saved: \(url.lastPathComponent)") }
        catch { NSLog("Screenshot failed: \(error)") }
    }

    /// Encode an RGBA8888 (memory order R,G,B,A) framebuffer as PNG data, top-row-first.
    private static func pngData(rgba: [UInt32], width: Int, height: Int) -> Data? {
        let bytes = rgba.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    // MARK: - Hotkey actions
    private func quickSave() {
        guard let store = saveStore, let data = driver.saveState() else { return }
        if store.write(data, to: store.slotURL(0)) {
            NSLog("Quicksave → slot 0 (\(data.count) bytes)")
            Toast.show(in: view.window, "Saved", style: .success)
        } else {
            NSLog("Quicksave failed to write")
            Toast.show(in: view.window, "Couldn’t save — your disk may be full or read-only.", style: .error)
        }
    }

    private func quickLoad() {
        guard let store = saveStore, let data = store.read(store.slotURL(0)) else {
            Toast.show(in: view.window, "No quicksave to load yet.")
            return
        }
        if driver.loadState(data) {
            NSLog("Quickload ← slot 0")
            Toast.show(in: view.window, "Loaded", style: .success)
        } else {
            NSLog("Quickload failed (incompatible state)")
            Toast.show(in: view.window, "This quicksave doesn’t match the game.", style: .error)
        }
    }

    /// Whether the emulator core can actually load this ROM — lets a launch fail with a friendly alert
    /// instead of crashing (or silently falling back to the mock core) on a corrupt or truncated file.
    static func canOpen(_ romURL: URL) -> Bool {
        let probe = GBACore()
        do { try probe.loadROM(at: romURL); return true } catch { return false }
    }

    private func flushBattery() {
        guard let store = saveStore, let battery = driver.cloneSaveData() else { return }
        store.write(battery, to: store.batteryURL)
    }
}

// MARK: - Standalone window host

/// Hosts a ``PlaySession`` in its own window — used only for a **direct** launch (`--rom` / `--mock`)
/// where there's no Library window to embed the game into. Library launches embed the session inline
/// instead (see ``LibraryWindowController``).
@MainActor
final class PlayWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let session: PlaySession
    private var didClose = false

    /// Called after the window closes and state is saved.
    var onClose: (() -> Void)?
    /// Reports seconds played this session (real ROMs only).
    var onPlaytime: ((Int) -> Void)? {
        get { session.onPlaytime }
        set { session.onPlaytime = newValue }
    }

    init(romURL: URL?, title: String) {
        session = PlaySession(romURL: romURL, title: title)
        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 620)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = title
        // We keep a strong `let window`, so ARC owns it — don't let AppKit also release it on close
        // (that double-release corrupts the heap and crashes later).
        window.isReleasedWhenClosed = false
        window.backgroundColor = PlayVoidView.backgroundTop   // blend the titlebar into the player
        window.appearance = NSAppearance(named: .darkAqua)
        // Disable AppKit's automatic open/close window animations — their transform-animation object
        // (`_NSWindowTransformAnimation`) crashes on teardown with this Metal-backed window.
        window.animationBehavior = .none
        window.titlebarAppearsTransparent = true
        window.contentView = session.view
        // Lock to the GBA's 3:2 so the game fills the window edge-to-edge with no letterbox bars.
        window.contentAspectRatio = NSSize(width: 3, height: 2)
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(contentRect.size)
        window.center()
        window.delegate = self

        session.onExit = { [weak self] in self?.window.performClose(nil) }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.keyView)
        DispatchQueue.main.async { [weak session] in session?.enterFill() }
    }

    func saveAndStop() { session.saveAndStop() }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        session.saveAndStop()
        onClose?()
    }
}
