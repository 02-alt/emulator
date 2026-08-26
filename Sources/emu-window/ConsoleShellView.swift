import AppKit
import EmulatorCore

/// The in-game play surface. It borrows Apple Music's *language* — a soft dark canvas, the game as a
/// large **rounded panel**, and quiet **glass** chrome tucked into the corners — but not its layout:
/// there's no song-player transport, "now-playing" title, or scrubbing clock (the game's name lives
/// in the window title bar, and a game has no timeline). Instead the real emulator actions sit in one
/// compact glass **toolbar** at the bottom — back + volume in the top corners, and save/load · speed ·
/// capture/controls/settings grouped in the bar. The on-screen gamepad is revealed on demand for
/// mouse play, alongside the keyboard/gamepad.
final class PlayVoidView: NSView, NSPopoverDelegate {
    let metalView: EmulatorMetalView
    var onOpenSettings: (() -> Void)?   // settings + ⌘, → app Settings
    var onExit: (() -> Void)?           // back + Esc → the shelf
    var onTogglePiP: (() -> Void)?      // pip button → float a mini game window

    // Save-states browser (the Load toolbar button opens it; F5/F9 stay quick save/load of slot 0).
    var provideSlots: ((Int) -> [SaveSlot])?
    var onSlotSave: ((Int) -> Void)?
    var onSlotLoad: ((Int) -> Void)?
    var onSlotDelete: ((Int) -> Void)?
    private var statesPopover: NSPopover?
    private let stateSlotCount = 6

    /// The soft player background — exposed so the host window's titlebar can blend with it.
    static let backgroundTop = NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.21, alpha: 1)
    static let backgroundBottom = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)

    private let screenAspect: CGFloat = 3.0 / 2.0   // GBA native 240×160
    private let gradient = CAGradientLayer()

    // Corner chrome — the controls that act on the *window/display*, grouped in the top-right.
    private var backBtn: PlayerIconButton!
    private var pipBtn: PlayerIconButton!
    private var immersiveBtn: PlayerIconButton!
    private var fullscreenBtn: PlayerIconButton!
    private let volumeIcon = NSImageView()
    private var volumeSlider: SlimSlider!

    // Fill mode ("game fills the window"): all chrome hidden, the game edge-to-edge within the current
    // window frame. The chrome reappears on mouse movement and auto-hides again after a beat, like a
    // video player. Independent of native full screen (the Full Screen button composes on top).
    private var immersive = false
    private var chromeHideTimer: Timer?
    private var moveTracking: NSTrackingArea?

    // Controller "guide" overlay: the console-style dashboard opened with the pad's Home button (or
    // L3+R3). The game pauses (and dims), the chrome stays up, and a focus ring lets the pad step
    // through the on-screen buttons and activate them.
    private var guideOpen = false
    private var guideIndex = 0
    private let guideDim = CALayer()   // dims the paused game (sits over the Metal content)

    // Bottom glass toolbar
    private var toolbarGlass: NSView!
    private var saveBtn, loadBtn, speedBtn, shotBtn, padToggleBtn, ambienceBtn, settingsBtn: PlayerIconButton!
    /// Solar-sensor toggle (Boktai / Lunar Knights). Present only when the cart has a light sensor;
    /// installed after build via ``installLightControl()``.
    private var lightBtn: PlayerIconButton?
    /// Fired when the player taps the light toggle; the session flips the luminance and calls back
    /// ``setLightState(on:)`` to update the icon.
    var onToggleLight: (() -> Void)?
    /// Disc-swap control for multi-disc PS1 games. Present only when there's more than one disc;
    /// installed after build via ``installDiscControl(count:)``.
    private var discBtn: PlayerIconButton?
    private var discCount = 0
    private var currentDisc = 0
    /// Fired with the new disc index when the player swaps discs.
    var onSwapDisc: ((Int) -> Void)?
    private let sep1 = PlayVoidView.makeSeparator()
    private let sep2 = PlayVoidView.makeSeparator()

    private let speeds: [Double] = [1.0, 1.5, 2.0]
    private var speedIndex = 0

    // The background-sound picker, anchored to the ambience button. The monitor closes it on clicks
    // that land in another app or on the desktop (which `.transient` alone doesn't catch).
    private var ambiencePopover: NSPopover?
    private var ambienceMonitor: Any?

    // On-screen GBA pad (hidden until toggled).
    private var padButtons: [(view: ControlButton, id: String)] = []
    private var padVisible = false
    private var touchPressed: GBAButtons = []

    /// A caption that pops up next to the hovered button to explain it.
    private let hint = HintBadge()

    /// The optional performance HUD (FPS · speed · draw rate), pinned to a corner. Hidden unless the
    /// player turns it on in Settings; `PlaySession` samples the driver/renderer and pushes values in.
    private let statsBadge = StatsBadge()
    private var statsCorner: Settings.StatsCorner = .topLeft

    init(title: String, metalView: EmulatorMetalView) {
        self.metalView = metalView
        super.init(frame: .zero)
        wantsLayer = true

        gradient.colors = [Self.backgroundTop.cgColor, Self.backgroundBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)

        // The game screen becomes the rounded hero panel.
        metalView.wantsLayer = true
        metalView.layer?.cornerRadius = DS.Radius.tile
        metalView.layer?.masksToBounds = true
        metalView.layer?.borderWidth = 1
        metalView.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(metalView)

        // A dim overlay layered directly over the game (a sublayer of the Metal layer, so it composites
        // above the frames without touching their alpha) — faded in while the guide pauses the game.
        guideDim.backgroundColor = NSColor.black.cgColor
        guideDim.opacity = 0
        metalView.layer?.addSublayer(guideDim)

        buildCorners()
        buildToolbar()
        buildPad()

        statsBadge.isHidden = true
        addSubview(statsBadge)

        hint.isHidden = true
        addSubview(hint)   // on top of everything
        wireHints()
    }

    /// Route every icon button's hover through the hint caption.
    private func wireHints() {
        let buttons: [PlayerIconButton] = [backBtn, fullscreenBtn, immersiveBtn, saveBtn, loadBtn,
                                           speedBtn, shotBtn, padToggleBtn, pipBtn, ambienceBtn, settingsBtn]
        for b in buttons {
            b.onHoverChanged = { [weak self] button, entered in
                self?.showHint(entered ? button : nil)
            }
        }
    }

    /// Show the caption above (or below, near the top edge) the hovered button; hide it on exit.
    private func showHint(_ button: PlayerIconButton?) {
        guard let button else { hint.isHidden = true; return }
        hint.setText(button.hintText)
        let size = hint.intrinsicContentSize
        var x = button.frame.midX - size.width / 2
        x = max(8, min(bounds.width - size.width - 8, x))
        // Bottom-half buttons (the toolbar) show the caption above them; top-half buttons (the
        // corner controls) show it below — always pointing into the open space.
        let y = button.frame.midY < bounds.height / 2
            ? button.frame.maxY + 6
            : button.frame.minY - 6 - size.height
        hint.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        hint.isHidden = false
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { false }   // bottom-left origin

    /// If the session is torn down while Fill mode is on (e.g. the Back button, which exits straight to
    /// the host rather than through ``exitImmersive``), restore the native titlebar on the way out so a
    /// reused window (the Library) doesn't keep a hidden titlebar on the shelf.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && immersive { setWindowTitlebarHidden(false) }
    }

    /// Fill is the default state: whenever we land in a real window, present edge-to-edge (chrome
    /// hidden, game under the titlebar). The launch flow re-parents this view (an intro overlay
    /// presents the game, then hands it to the final window), so `viewDidMoveToWindow` can fire more
    /// than once — we must re-assert the *window-level* Fill setup (hidden titlebar) on the new window
    /// each time, not just enter Fill once. Entering when not yet immersive covers the plain path.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if immersive {
            setWindowTitlebarHidden(true)          // re-apply to the window we just moved to
            window?.acceptsMouseMovedEvents = true
        } else {
            enterImmersive()
        }
    }

    // MARK: - Build

    private func buildCorners() {
        backBtn = PlayerIconButton(symbol: "chevron.left", tooltip: "Back to Library", style: .disc,
                                   behavior: .tap { [weak self] in self?.onExit?() })
        // Window/display controls, clustered top-right: PiP · Fill · Full Screen — all act on the
        // window rather than on gameplay, so they live apart from the bottom action bar.
        pipBtn = PlayerIconButton(symbol: "pip.enter", tooltip: "Picture in Picture", style: .disc,
                                  behavior: .tap { [weak self] in self?.onTogglePiP?() })
        immersiveBtn = PlayerIconButton(symbol: "rectangle.inset.filled",
                                        tooltip: "Fill Window with Game", style: .disc,
                                        behavior: .tap { [weak self] in self?.toggleImmersive() })
        fullscreenBtn = PlayerIconButton(symbol: "arrow.up.left.and.arrow.down.right",
                                         tooltip: "Toggle Full Screen", style: .disc,
                                         behavior: .tap { [weak self] in self?.window?.toggleFullScreen(nil) })
        addSubview(backBtn)
        addSubview(pipBtn)
        addSubview(immersiveBtn)
        addSubview(fullscreenBtn)

        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")?
            .withSymbolConfiguration(cfg)
        volumeIcon.contentTintColor = NSColor(white: 1, alpha: 0.75)
        volumeIcon.imageScaling = .scaleNone
        addSubview(volumeIcon)

        volumeSlider = SlimSlider(value: Settings.shared.volume, width: 96)
        volumeSlider.onChange = { Settings.shared.volume = $0 }   // the live session applies it via Settings.didChange
        addSubview(volumeSlider)
    }

    private func buildToolbar() {
        // A translucent glass capsule behind the action row.
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 24
            g.style = .regular
            toolbarGlass = g
        } else {
            let b = NSVisualEffectView()
            b.material = .hudWindow
            b.blendingMode = .withinWindow
            b.state = .active
            b.wantsLayer = true
            b.layer?.cornerRadius = 24
            b.layer?.masksToBounds = true
            toolbarGlass = b
        }
        addSubview(toolbarGlass)
        addSubview(sep1)
        addSubview(sep2)

        // Uniform, bare icons — save/load state · a speed toggle · capture/controls/settings.
        saveBtn = barButton("tray.and.arrow.down.fill", "Save State (F5)") { [weak self] in self?.metalView.onSave?() }
        saveBtn.setImage(floppyDiskImage(pointSize: 15, arrow: .down))   // floppy, arrow = save/write
        loadBtn = barButton("square.stack.3d.up.fill", "Save States") { [weak self] in self?.toggleStatesPanel() }
        speedBtn = PlayerIconButton(symbol: "", tooltip: "Playback Speed", style: .bare, diameter: 44,
                                    behavior: .tap { [weak self] in self?.cycleSpeed() })
        speedBtn.setTitle("1×")
        shotBtn = barButton("camera.fill", "Screenshot (P)") { [weak self] in self?.metalView.onScreenshot?() }
        padToggleBtn = barButton("gamecontroller.fill", "On-Screen Controls") { [weak self] in self?.togglePad() }
        let scene = Settings.shared.ambientScene
        ambienceBtn = PlayerIconButton(symbol: Self.ambienceSymbol(scene),
                                       tooltip: "Background Sound: \(scene.title)", style: .bare, diameter: 32,
                                       behavior: .tap { [weak self] in self?.toggleAmbiencePanel() })
        ambienceBtn.setDim(scene == .off)
        settingsBtn = barButton("gearshape.fill", "Settings (⌘,)") { [weak self] in self?.onOpenSettings?() }

        [saveBtn, loadBtn, speedBtn, shotBtn, padToggleBtn, ambienceBtn, settingsBtn].forEach { addSubview($0!) }
    }

    private func barButton(_ symbol: String, _ tip: String, _ run: @escaping () -> Void) -> PlayerIconButton {
        PlayerIconButton(symbol: symbol, tooltip: tip, style: .bare, diameter: 32, behavior: .tap(run))
    }

    /// Add the solar-sensor "Light" toggle to the toolbar. Called by the session only for carts with a
    /// light sensor. The icon shows the action: a sun while dark (tap to bring sunlight), a moon while
    /// lit (tap to go dark).
    func installLightControl() {
        guard lightBtn == nil else { return }
        let btn = barButton("sun.max.fill", "Light: off — tap for sunlight (L)") { [weak self] in
            self?.onToggleLight?()
        }
        btn.onHoverChanged = { [weak self] button, entered in self?.showHint(entered ? button : nil) }
        addSubview(btn)
        lightBtn = btn
        needsLayout = true
    }

    /// Add the disc-swap button for a multi-disc game (`count` ≥ 2). Tapping cycles to the next disc.
    func installDiscControl(count: Int) {
        guard discBtn == nil, count > 1 else { return }
        discCount = count
        let btn = barButton("opticaldisc", "Disc 1 of \(count) — tap to swap") { [weak self] in
            self?.cycleDisc()
        }
        btn.onHoverChanged = { [weak self] button, entered in self?.showHint(entered ? button : nil) }
        addSubview(btn)
        discBtn = btn
        needsLayout = true
    }

    private func cycleDisc() {
        guard discCount > 1 else { return }
        currentDisc = (currentDisc + 1) % discCount
        onSwapDisc?(currentDisc)
        discBtn?.toolTip = "Disc \(currentDisc + 1) of \(discCount) — tap to swap"
        Toast.show(in: window, "Disc \(currentDisc + 1) of \(discCount)", style: .info)
    }

    /// Reflect the latched solar-sensor state on the toolbar button.
    func setLightState(on: Bool) {
        lightBtn?.setSymbol(on ? "moon.fill" : "sun.max.fill")
        lightBtn?.toolTip = on ? "Light: on — tap for darkness (L)" : "Light: off — tap for sunlight (L)"
    }

    /// Open (or close) the Save States browser popover, anchored to the toolbar's states button.
    private func toggleStatesPanel() {
        if let p = statesPopover, p.isShown { p.performClose(nil); return }
        let panel = SaveStatesPanelView(count: stateSlotCount)
        panel.slotsProvider = { [weak self] in
            guard let self else { return [] }
            return self.provideSlots?(self.stateSlotCount) ?? []
        }
        panel.onSave = { [weak self] n in self?.onSlotSave?(n) }
        panel.onLoad = { [weak self] n in self?.onSlotLoad?(n); self?.statesPopover?.performClose(nil) }
        panel.onDelete = { [weak self] n in self?.onSlotDelete?(n) }
        panel.reload()
        let vc = NSViewController(); vc.view = panel; vc.preferredContentSize = panel.frame.size
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.show(relativeTo: loadBtn.bounds, of: loadBtn, preferredEdge: .maxY)
        statesPopover = pop
    }

    private static func makeSeparator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        return v
    }

    private func buildPad() {
        let specs: [(String, GBAButtons, String)] = [
            ("↑", .up, "up"), ("↓", .down, "down"), ("←", .left, "left"), ("→", .right, "right"),
            ("L", .l, "l"), ("R", .r, "r"), ("B", .b, "b"), ("A", .a, "a"),
            ("SELECT", .select, "select"), ("START", .start, "start"),
        ]
        for (label, button, id) in specs {
            let b = ControlButton(label, .hold(button))
            b.onPress = { [weak self] x in self?.press(x) }
            b.onRelease = { [weak self] x in self?.release(x) }
            b.isHidden = true
            addSubview(b)
            padButtons.append((b, id))
        }
    }

    // MARK: - Actions

    /// Cycle the playback speed 1× → 1.5× → 2× → 1×. Above 1× runs video-timed with muted audio.
    private func cycleSpeed() {
        speedIndex = (speedIndex + 1) % speeds.count
        applySpeed(speeds[speedIndex])
    }

    /// Set the speed toggle to a specific multiplier (reflecting a per-game speed override at launch).
    /// Snaps to the nearest toolbar step so the label and subsequent cycling stay coherent.
    func setSpeedDisplay(_ m: Double) {
        speedIndex = speeds.firstIndex(of: m)
            ?? speeds.enumerated().min { abs($0.1 - m) < abs($1.1 - m) }?.offset ?? 0
        applySpeed(speeds[speedIndex])
    }

    private func applySpeed(_ m: Double) {
        metalView.driver?.setSpeed(m)
        speedBtn.setTitle(m == m.rounded() ? "\(Int(m))×" : "\(m)×")
    }

    /// Open (or dismiss) the background-sound picker above the ambience button — a scene list plus a
    /// volume slider. Its changes flow through ``Settings``, which the live ``AmbientPlayer`` applies;
    /// `onSceneChanged` keeps this button's icon in step.
    private func toggleAmbiencePanel() {
        if let p = ambiencePopover, p.isShown { p.performClose(nil); return }

        let panel = AmbiencePanelView { [weak self] scene in self?.syncAmbienceButton(scene) }
        let vc = NSViewController()
        vc.view = panel
        vc.preferredContentSize = panel.frame.size

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient          // closes on clicks elsewhere in the app
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.delegate = self                // popoverDidClose tears down the monitor below
        pop.show(relativeTo: ambienceBtn.bounds, of: ambienceBtn, preferredEdge: .maxY)
        ambiencePopover = pop
        panel.beginControllerFocus()   // ready for controller/keyboard navigation right away

        // …and on clicks outside the app entirely (another window or the desktop) — a global monitor
        // only sees events routed to other apps, so it complements `.transient` without double-firing.
        ambienceMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak pop] _ in
            pop?.performClose(nil)
        }
    }

    /// Reflect the chosen scene on the toolbar button (icon · tooltip · dim when Off).
    private func syncAmbienceButton(_ scene: Settings.AmbientScene) {
        ambienceBtn.setSymbol(Self.ambienceSymbol(scene))
        ambienceBtn.toolTip = "Background Sound: \(scene.title)"
        ambienceBtn.setDim(scene == .off)
    }

    private static func ambienceSymbol(_ scene: Settings.AmbientScene) -> String {
        AmbiencePanelView.symbol(scene)
    }

    /// Drop the outside-click monitor and our reference whenever the picker closes — however it closed
    /// (button re-tap, a click elsewhere, or the global monitor), so no stale monitor lingers.
    func popoverDidClose(_ notification: Notification) {
        if let m = ambienceMonitor { NSEvent.removeMonitor(m); ambienceMonitor = nil }
        ambiencePopover = nil
    }

    private func togglePad() {
        padVisible.toggle()
        if !padVisible { touchPressed = []; metalView.driver?.setTouch([]) }
        padButtons.forEach { $0.view.isHidden = !padVisible }
        needsLayout = true
    }

    /// Reflect whether the floating PiP mini-window is open on its toolbar button (icon + tooltip).
    func setPiPActive(_ active: Bool) {
        pipBtn.setSymbol(active ? "pip.exit" : "pip.enter")
        pipBtn.toolTip = active ? "Exit Picture in Picture" : "Picture in Picture"
    }

    // MARK: - Stats HUD

    /// Show or hide the performance HUD and pin it to `corner`. Driven by ``PlaySession`` from the
    /// Settings ▸ Emulation toggle (applied live).
    func setStats(visible: Bool, corner: Settings.StatsCorner) {
        statsBadge.isHidden = !visible
        statsCorner = corner
        needsLayout = true
    }

    /// Feed the HUD freshly sampled figures (a no-op while it's hidden).
    func updateStats(fps: Double, speedPercent: Int, drawRate: Double) {
        guard !statsBadge.isHidden else { return }
        statsBadge.update(fps: fps, speedPercent: speedPercent, drawRate: drawRate)
    }

    /// Pin the stats HUD into its corner, tucked clear of the top button row.
    private func layoutStatsBadge() {
        guard !statsBadge.isHidden else { return }
        let sideM: CGFloat = 24, topInset: CGFloat = 16, discD: CGFloat = 40
        let s = StatsBadge.size
        let topRowY = bounds.height - topInset - discD   // the corner buttons' row
        let x = statsCorner == .topLeft || statsCorner == .bottomLeft
            ? sideM
            : bounds.width - sideM - s.width
        let y = statsCorner == .topLeft || statsCorner == .topRight
            ? topRowY - 12 - s.height   // below the top buttons
            : 16                        // above the bottom edge (toolbar is centered, corners are clear)
        statsBadge.frame = CGRect(x: x, y: max(16, y), width: s.width, height: s.height)
    }

    private func press(_ b: GBAButtons) { touchPressed.insert(b); metalView.driver?.setTouch(touchPressed) }
    private func release(_ b: GBAButtons) { touchPressed.remove(b); metalView.driver?.setTouch(touchPressed) }

    // MARK: - Fill (game edge-to-edge)

    /// Enter or leave fill mode (game edge-to-edge in the current window, chrome hidden). This is
    /// independent of native full screen — the separate Full Screen button composes on top, so you
    /// can fill the window and *also* go full screen if you want, in either order.
    private func toggleImmersive() {
        if immersive { exitImmersive() } else { enterImmersive() }
    }

    /// Force Fill on if it isn't already — the host calls this when presenting a game so edge-to-edge
    /// is the reliable default even when the launch cinematic re-parents this view.
    func enterFillIfNeeded() { if !immersive { enterImmersive() } }

    // MARK: - Controller guide (Home-button dashboard)

    /// True whenever a controller-navigable menu is up — the guide itself, or the ambience popover
    /// hanging off it. The controller manager checks this to route the pad to the menu vs. the game.
    var isGuideOpen: Bool { guideOpen || (ambiencePopover?.isShown ?? false) }

    /// The buttons the guide steps through, in a sensible left-to-right order.
    private var guideTargets: [PlayerIconButton] {
        [backBtn, saveBtn, loadBtn, speedBtn, shotBtn, padToggleBtn, ambienceBtn, settingsBtn]
    }

    /// The ambience popover's panel, when it's up (so the guide can drive its scene list).
    private var ambiencePanelView: AmbiencePanelView? {
        ambiencePopover?.isShown == true ? ambiencePopover?.contentViewController?.view as? AmbiencePanelView : nil
    }

    /// Open/close the guide — the pad's Home button (or L3+R3) toggles this.
    func toggleGuide() { guideOpen ? closeGuide() : openGuide() }

    private func openGuide() {
        guard !guideOpen else { return }
        guideOpen = true
        metalView.driver?.setPaused(true)             // classic console guide: the game pauses
        guideDim.opacity = 0.45                        // dim the paused game so the menu reads clearly
        chromeHideTimer?.invalidate(); chromeHideTimer = nil
        setChrome(revealed: true)                     // keep the interface up while navigating
        guideIndex = 0
        updateGuideFocus()
    }

    /// Close the guide and resume the game (also dismissing the ambience popover if it's up). Safe
    /// to call when already closed.
    func closeGuide() {
        if ambiencePopover?.isShown == true { ambiencePopover?.performClose(nil) }
        guard guideOpen else { return }
        guideOpen = false
        metalView.driver?.setPaused(false)
        guideDim.opacity = 0
        guideTargets.forEach { $0.setFocused(false) }
        if immersive { setChrome(revealed: false) }   // let Fill tuck the chrome away again
    }

    /// The "back / B" action: step out of the ambience popover first, then out of the guide.
    func guideBack() {
        if ambiencePopover?.isShown == true { ambiencePopover?.performClose(nil); return }
        closeGuide()
    }

    /// Up/Down: step the focus ring (true = down/next). In the ambience popover it moves through the
    /// scene list; on the guide toolbar it steps between buttons.
    func guideMove(_ next: Bool) {
        if let panel = ambiencePanelView { panel.focusMove(next); return }
        stepGuideFocus(next)
    }

    /// Left/Right: adjust the focused control. In the ambience popover this nudges the volume; on the
    /// horizontal guide toolbar it just steps the focus like Up/Down.
    func guideAdjust(_ increase: Bool) {
        if let panel = ambiencePanelView { panel.adjustVolume(increase); return }
        stepGuideFocus(increase)
    }

    private func stepGuideFocus(_ next: Bool) {
        guard guideOpen else { return }
        let n = guideTargets.count
        guideIndex = ((guideIndex + (next ? 1 : -1)) % n + n) % n
        updateGuideFocus()
    }

    /// "Press" the focused item — the ambience scene if that popover is open, else the toolbar button.
    func guideActivate() {
        if let panel = ambiencePanelView { panel.activateFocused(); return }
        guard guideOpen, guideTargets.indices.contains(guideIndex) else { return }
        guideTargets[guideIndex].activate()
    }

    private func updateGuideFocus() {
        for (i, b) in guideTargets.enumerated() { b.setFocused(i == guideIndex) }
    }

    private func enterImmersive() {
        immersive = true
        immersiveBtn.setSymbol("arrow.down.right.and.arrow.up.left")
        immersiveBtn.toolTip = "Exit Fill (Esc)"
        window?.acceptsMouseMovedEvents = true
        setWindowTitlebarHidden(true)   // let the game run under the native titlebar too
        setChrome(revealed: false)
        needsLayout = true
    }

    private func exitImmersive() {
        guard immersive else { return }
        immersive = false
        chromeHideTimer?.invalidate(); chromeHideTimer = nil
        NSCursor.unhide()
        immersiveBtn.setSymbol("rectangle.inset.filled")
        immersiveBtn.toolTip = "Fill Window with Game"
        setWindowTitlebarHidden(false)
        setChrome(revealed: true)
        needsLayout = true
    }

    /// Fill mode should reach the very top of the window, so hide the native titlebar: extend the
    /// content under it (`.fullSizeContentView`), drop the title, and hide the traffic-light buttons.
    /// Restored on exit. Native full screen already covers the titlebar itself, so this is a no-op
    /// there — but it keeps a plain windowed Fill from showing the grey bar.
    private func setWindowTitlebarHidden(_ hidden: Bool) {
        guard let window else { return }
        if hidden {
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titleVisibility = .visible
        }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

    /// Esc hook: if filling, swallow the key and drop back to the windowed hero layout instead of
    /// quitting to the library. Returns true when it consumed the press.
    func exitImmersiveIfActive() -> Bool {
        guard immersive else { return false }
        exitImmersive()
        return true
    }

    /// Show or hide the chrome. In immersive mode "hidden" is the resting state; movement reveals it.
    private func setChrome(revealed: Bool) {
        let hidden = immersive && !revealed
        var chrome: [NSView] = [backBtn, fullscreenBtn, immersiveBtn, volumeIcon, volumeSlider,
                                toolbarGlass, sep1, sep2, saveBtn, loadBtn, speedBtn, shotBtn,
                                padToggleBtn, pipBtn, ambienceBtn, settingsBtn]
        if let lightBtn { chrome.append(lightBtn) }
        if let discBtn { chrome.append(discBtn) }
        chrome.forEach { $0.isHidden = hidden }
        if hidden { hint.isHidden = true }
    }

    /// Flash the chrome back for a couple of seconds whenever the mouse moves in immersive mode.
    private func revealChromeBriefly() {
        NSCursor.unhide()
        setChrome(revealed: true)
        chromeHideTimer?.invalidate()
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.immersive else { return }
                self.setChrome(revealed: false)
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveTracking { removeTrackingArea(moveTracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); moveTracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if immersive { revealChromeBriefly() }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Snap the background gradient to the new size with no implicit animation — otherwise a raw
        // CALayer's frame change lags a frame behind a live window resize, flashing the lighter window
        // backing at the newly-exposed edge (the "weird effect" in windowed mode).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        gradient.isHidden = immersive
        CATransaction.commit()
        // Immersive rests on pure black behind the letterbox bars; windowed keeps the soft gradient,
        // with the view's own backing set to the gradient's darkest stop so any resize gap reads as
        // that same dark, never the lighter window background.
        layer?.backgroundColor = immersive ? NSColor.black.cgColor : Self.backgroundBottom.cgColor
        hint.isHidden = true   // avoid a stale caption after a resize

        let sideM: CGFloat = 24, topInset: CGFloat = 16, discD: CGFloat = 40
        let topY = bounds.height - topInset - discD

        // Top-left: back.
        backBtn.frame = CGRect(x: sideM, y: topY, width: discD, height: discD)

        // Top-right: the window controls clustered at the corner (PiP · Fill · Full Screen), then
        // volume to their left.
        fullscreenBtn.frame = CGRect(x: bounds.width - sideM - discD, y: topY, width: discD, height: discD)
        immersiveBtn.frame = CGRect(x: fullscreenBtn.frame.minX - 8 - discD, y: topY, width: discD, height: discD)
        pipBtn.frame = CGRect(x: immersiveBtn.frame.minX - 8 - discD, y: topY, width: discD, height: discD)
        let sliderW: CGFloat = 96, iconW: CGFloat = 20
        let volRight = pipBtn.frame.minX - 14
        volumeSlider.frame = CGRect(x: volRight - sliderW, y: topY, width: sliderW, height: discD)
        volumeIcon.frame = CGRect(x: volRight - sliderW - 6 - iconW, y: topY, width: iconW, height: discD)

        layoutToolbar()

        // Game screen: edge-to-edge (aspect-fit) in immersive mode, otherwise the rounded hero panel
        // aspect-fit between the top chrome and the toolbar.
        metalView.layer?.cornerRadius = immersive ? 0 : DS.Radius.tile
        metalView.layer?.borderWidth = immersive ? 0 : 1
        metalView.frame = immersive ? fittedScreen(in: bounds) : Self.gameScreenRect(in: bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guideDim.frame = metalView.bounds
        guideDim.cornerRadius = metalView.layer?.cornerRadius ?? 0
        CATransaction.commit()
        if padVisible { layoutPad(over: metalView.frame) }
        layoutStatsBadge()
    }

    /// The windowed game-screen rect for a given void size — the rounded hero panel, aspect-fit between
    /// the top chrome and the bottom toolbar. Shared so the launch cinematic can play its boot clip at
    /// exactly this rect and crossfade into the game with no size jump.
    static func gameScreenRect(in bounds: CGRect) -> CGRect {
        let sideM: CGFloat = 24, topInset: CGFloat = 16, discD: CGFloat = 40
        let area = CGRect(x: sideM, y: 92, width: bounds.width - sideM * 2,
                          height: bounds.height - 92 - (topInset + discD + 14))
        guard area.width > 0, area.height > 0 else { return .zero }
        let aspect: CGFloat = 3.0 / 2.0
        var w = area.width, h = area.width / aspect
        if h > area.height { h = area.height; w = h * aspect }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// A centered glass toolbar: [save load] | [speed] | [screenshot gamepad settings].
    private func layoutToolbar() {
        let d: CGFloat = 32, tightGap: CGFloat = 4, sepGap: CGFloat = 10, sepW: CGFloat = 1
        let barCenterY: CGFloat = 46

        // token list: buttons and separators, in order.
        enum Tok { case btn(PlayerIconButton), sep(NSView) }
        var tokens: [Tok] = [
            .btn(saveBtn), .btn(loadBtn),
            .sep(sep1),
            .btn(speedBtn),
            .sep(sep2),
            .btn(shotBtn), .btn(padToggleBtn),
        ]
        if let lightBtn { tokens.append(.btn(lightBtn)) }
        if let discBtn { tokens.append(.btn(discBtn)) }
        tokens.append(contentsOf: [.btn(ambienceBtn), .btn(settingsBtn)])
        func width(_ t: Tok) -> CGFloat {
            if case let .btn(b) = t { return b.intrinsicContentSize.width } else { return sepW }
        }
        func gapBefore(_ i: Int) -> CGFloat {
            guard i > 0 else { return 0 }
            if case .sep = tokens[i] { return sepGap }
            if case .sep = tokens[i - 1] { return sepGap }
            return tightGap
        }
        let total = tokens.enumerated().reduce(CGFloat(0)) { $0 + gapBefore($1.offset) + width($1.element) }

        var x = (bounds.width - total) / 2
        for (i, t) in tokens.enumerated() {
            x += gapBefore(i)
            switch t {
            case let .btn(b):
                let w = b.intrinsicContentSize.width
                b.frame = CGRect(x: x, y: barCenterY - d / 2, width: w, height: d); x += w
            case let .sep(v):
                v.frame = CGRect(x: x, y: barCenterY - 9, width: sepW, height: 18); x += sepW
            }
        }

        let padX: CGFloat = 14, h: CGFloat = 48
        toolbarGlass.frame = CGRect(x: (bounds.width - total) / 2 - padX, y: barCenterY - h / 2,
                                    width: total + padX * 2, height: h)
        if let blur = toolbarGlass as? NSVisualEffectView { blur.layer?.cornerRadius = h / 2 }
    }

    /// Largest 3:2 rect centered in `area`.
    private func fittedScreen(in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        var w = area.width, h = area.width / screenAspect
        if h > area.height { h = area.height; w = h * screenAspect }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// A translucent gamepad laid over the game screen: D-pad lower-left, B/A lower-right, L/R along
    /// the top, Select/Start centered at the bottom.
    private func layoutPad(over g: CGRect) {
        func btn(_ id: String) -> ControlButton? { padButtons.first { $0.id == id }?.view }
        let key: CGFloat = 30, m: CGFloat = 16

        let cx = g.minX + m + key * 1.5, cy = g.minY + m + key * 1.5
        btn("up")?.frame    = CGRect(x: cx - key / 2, y: cy + key / 2, width: key, height: key)
        btn("down")?.frame  = CGRect(x: cx - key / 2, y: cy - key * 1.5, width: key, height: key)
        btn("left")?.frame  = CGRect(x: cx - key * 1.5, y: cy - key / 2, width: key, height: key)
        btn("right")?.frame = CGRect(x: cx + key / 2, y: cy - key / 2, width: key, height: key)

        let fx = g.maxX - m - key, fy = g.minY + m + key
        btn("a")?.frame = CGRect(x: fx, y: fy - key / 2, width: key, height: key)
        btn("b")?.frame = CGRect(x: fx - key - 10, y: fy - key / 2, width: key, height: key)

        btn("l")?.frame = CGRect(x: g.minX + m, y: g.maxY - m - key, width: key + 6, height: key)
        btn("r")?.frame = CGRect(x: g.maxX - m - key - 6, y: g.maxY - m - key, width: key + 6, height: key)

        if let sel = btn("select"), let start = btn("start") {
            let sw = sel.measuredWidth, stw = start.measuredWidth
            let sx = g.midX - (sw + 10 + stw) / 2
            sel.frame = CGRect(x: sx, y: g.minY + m, width: sw, height: 24)
            start.frame = CGRect(x: sx + sw + 10, y: g.minY + m, width: stw, height: 24)
        }
    }
}

// MARK: - Player icon button

/// A round icon button in the player's glass language: an SF Symbol that lights up on hover/press.
/// `.disc` carries its own soft translucent disc (the top-corner buttons); `.bare` has no base fill,
/// only a hover/press highlight (the buttons that sit on the glass toolbar). `tap` fires on click;
/// `hold` presses/releases (rewind/fast-forward).
private enum FloppyArrow { case none, up, down }

/// A monochrome 3.5" floppy-disk glyph, drawn as a template image so it inherits the player
/// bar's white tint exactly like the SF Symbols beside it — SF Symbols ships no floppy disk.
/// `arrow` stamps a direction on the disk label: down = Save (write), up = Load (read).
private func floppyDiskImage(pointSize: CGFloat, arrow: FloppyArrow = .none) -> NSImage {
    let s = pointSize * 1.3
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current else { return false }
        // Body: rounded-square with the classic clipped top-right corner (y is up).
        let l = 0.13 * s, r = 0.87 * s, b = 0.08 * s, t = 0.92 * s, notch = 0.22 * s
        let body = NSBezierPath()
        body.move(to: NSPoint(x: l, y: b))
        body.line(to: NSPoint(x: r, y: b))
        body.line(to: NSPoint(x: r, y: t - notch))
        body.line(to: NSPoint(x: r - notch, y: t))
        body.line(to: NSPoint(x: l, y: t))
        body.close()
        NSColor.black.setFill()
        body.fill()

        // Punch out the metal shutter (top) and the paper label (bottom).
        ctx.compositingOperation = .destinationOut
        NSBezierPath(rect: NSRect(x: 0.30 * s, y: 0.60 * s, width: 0.42 * s, height: 0.24 * s)).fill()
        NSBezierPath(rect: NSRect(x: 0.25 * s, y: 0.13 * s, width: 0.50 * s, height: 0.33 * s)).fill()

        // The little sliding window inside the shutter, drawn back in for detail.
        ctx.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0.34 * s, y: 0.62 * s, width: 0.11 * s, height: 0.20 * s)).fill()

        // An arrow stamped inside the (dark) label: down = Save (write), up = Load (read).
        if arrow != .none {
            let a = NSBezierPath()
            if arrow == .up {
                a.move(to: NSPoint(x: 0.50 * s, y: 0.45 * s))    // head apex (top)
                a.line(to: NSPoint(x: 0.385 * s, y: 0.325 * s))
                a.line(to: NSPoint(x: 0.615 * s, y: 0.325 * s))
                a.close()
                a.appendRect(NSRect(x: 0.455 * s, y: 0.17 * s, width: 0.09 * s, height: 0.16 * s))
            } else {
                a.move(to: NSPoint(x: 0.50 * s, y: 0.14 * s))    // head apex (bottom)
                a.line(to: NSPoint(x: 0.385 * s, y: 0.265 * s))
                a.line(to: NSPoint(x: 0.615 * s, y: 0.265 * s))
                a.close()
                a.appendRect(NSRect(x: 0.455 * s, y: 0.26 * s, width: 0.09 * s, height: 0.16 * s))
            }
            a.fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}

private final class PlayerIconButton: NSView {
    enum Style { case disc, bare }
    enum Behavior { case tap(() -> Void); case hold(down: () -> Void, up: () -> Void) }

    /// Fired on hover enter (true) / exit (false) so the play view can show a hint caption.
    var onHoverChanged: ((PlayerIconButton, Bool) -> Void)?
    /// The hint text shown on hover — reuses the accessibility tooltip.
    var hintText: String { toolTip ?? "" }

    private let behavior: Behavior
    private let style: Style
    private let diameter: CGFloat
    private let pointSize: CGFloat
    private let iconView = NSImageView()
    private var titleText: String?
    private var hovered = false
    private var pressed = false
    private var focused = false        // controller-guide focus ring
    private var tracking: NSTrackingArea?

    init(symbol: String, tooltip: String, style: Style = .disc, pointSize: CGFloat = 15,
         diameter: CGFloat = 40, behavior: Behavior) {
        self.behavior = behavior
        self.style = style
        self.diameter = diameter
        self.pointSize = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = tooltip
        layer?.cornerRadius = diameter / 2
        // A clean liquid-glass disc: a crisp rim to catch the light + a soft drop shadow so it lifts
        // off the dark player background and reads clearly, without a heavy solid fill.
        if style == .disc {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.20).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 6
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.masksToBounds = false
        }
        iconView.imageScaling = .scaleNone
        iconView.imageAlignment = .alignCenter
        iconView.contentTintColor = .white
        addSubview(iconView)
        setSymbol(symbol)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setSymbol(_ name: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(cfg)
    }

    /// Use a custom (non-SF-Symbol) glyph, tinted like the symbols beside it.
    func setImage(_ image: NSImage) {
        image.isTemplate = true
        iconView.image = image
    }

    /// Show text instead of a symbol (used for the speed toggle: "1×", "1.5×", "2×").
    func setTitle(_ s: String) { titleText = s; iconView.isHidden = true; needsDisplay = true }

    /// Dim the icon to signal an "inactive" state (e.g. ambience Off) without hiding the button.
    func setDim(_ on: Bool) { iconView.alphaValue = on ? 0.4 : 1 }

    override var intrinsicContentSize: NSSize {
        if let t = titleText {
            return NSSize(width: max(diameter, DS.Text.plain(t, size: 13).size().width + 18), height: diameter)
        }
        return NSSize(width: diameter, height: diameter)
    }
    override func layout() { super.layout(); iconView.frame = bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = titleText else { return }
        let str = DS.Text.plain(t, size: 13, color: .white)
        let sz = str.size()
        str.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }

    private func refresh() {
        let base: CGFloat = style == .disc ? 0.15 : 0.0
        let a = pressed ? base + 0.18 : ((hovered || focused) ? base + 0.12 : base)
        layer?.backgroundColor = NSColor(white: 1, alpha: a).cgColor
        if focused {
            layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.borderWidth = 2
        } else if style == .disc {
            layer?.borderColor = NSColor(white: 1, alpha: 0.20).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.borderWidth = 0
        }
    }

    /// Show/clear the controller-guide focus ring.
    func setFocused(_ on: Bool) { guard focused != on else { return }; focused = on; refresh() }

    /// Run the button's action programmatically (the controller guide "presses" the focused button).
    func activate() {
        switch behavior {
        case let .tap(run): run()
        case let .hold(down, up): down(); up()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh(); onHoverChanged?(self, true) }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        if pressed { pressed = false; if case let .hold(_, up) = behavior { up() } }
        refresh()
        onHoverChanged?(self, false)
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true; refresh()
        if case let .hold(down, _) = behavior { down() }
    }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed; pressed = false; refresh()
        switch behavior {
        case let .tap(run): if wasPressed { run() }
        case let .hold(_, up): up()
        }
    }
}

// MARK: - Hint badge

/// A small rounded caption that names the button under the cursor — an immediate, in-app replacement
/// for the slow system tooltip. Transparent to the mouse so it never steals hover from the buttons.
private final class HintBadge: NSView {
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setText(_ s: String) { text = s; needsDisplay = true; invalidateIntrinsicContentSize() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.plain(text, size: 12).size().width + 20, height: 24)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never intercept the mouse

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.05, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DS.Radius.small, yRadius: DS.Radius.small).fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: DS.Radius.small, yRadius: DS.Radius.small)
        border.lineWidth = 1; border.stroke()

        let str = DS.Text.plain(text, size: 12, color: .white)
        let sz = str.size()
        str.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}

// MARK: - Slim slider

/// A thin 0…1 slider matching the player chrome: a translucent track, a brighter filled portion, and
/// a small white knob. Click or drag to set. Used for the in-game volume and the ambience panel.
final class SlimSlider: NSView {
    var onChange: ((Double) -> Void)?
    private var value: Double
    private let w: CGFloat
    private let inset: CGFloat = 7

    init(value: Double, width: CGFloat) {
        self.value = value
        self.w = width
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Set the value programmatically (e.g. controller left/right) and redraw — does not fire onChange.
    func setValue(_ v: Double) { value = max(0, min(1, v)); needsDisplay = true }
    var currentValue: Double { value }

    override var intrinsicContentSize: NSSize { NSSize(width: w, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY, x0 = inset, x1 = bounds.width - inset
        let track = CGRect(x: x0, y: midY - 2, width: x1 - x0, height: 4)
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let knobX = x0 + (x1 - x0) * CGFloat(value)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: CGRect(x: x0, y: midY - 2, width: knobX - x0, height: 4),
                     xRadius: 2, yRadius: 2).fill()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: knobX - 5, y: midY - 5, width: 10, height: 10)).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { setFromEvent(event) }
    override func mouseDragged(with event: NSEvent) { setFromEvent(event) }

    private func setFromEvent(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let v = max(0, min(1, Double((x - inset) / (bounds.width - inset * 2))))
        guard v != value else { return }
        value = v
        needsDisplay = true
        onChange?(v)
    }
}
