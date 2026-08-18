import AppKit
import EmulatorCore
import MetalKit

/// A floating "picture in picture" mini game window that mirrors a live ``PlaySession`` and stays
/// **playable**. It shares the session's ``EmulationDriver`` — its own ``EmulatorMetalView`` +
/// ``Renderer`` are just a second render surface reading the same frames, so no emulation, audio, or
/// input ownership moves here. Keyboard events that land on this window drive the same driver, so the
/// mini screen plays like the main one. The session creates and tears it down (see ``PlaySession``).
@MainActor
final class PiPWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let metalView: EmulatorMetalView
    private let renderer: Renderer
    private var didClose = false

    /// Called when the window closes — its own close button, or a session teardown — so the session can
    /// drop its reference and re-light the toolbar toggle.
    var onClose: (() -> Void)?

    init(driver: EmulationDriver, title: String) {
        let view = EmulatorMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.driver = driver
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        let renderer = Renderer(driver: driver, view: view)
        view.delegate = renderer
        self.metalView = view
        self.renderer = renderer

        // A small floating utility panel that survives app switches and rides over other spaces /
        // full-screen apps, so the game stays visible while you work elsewhere. It can become key on
        // click, which routes keyboard input through its EmulatorMetalView to the shared driver — the
        // mini screen is fully playable, not just a preview. Aspect is locked to the GBA's 3:2 so
        // resizing stays proportional (the renderer letterboxes anything left over).
        let size = NSSize(width: 750, height: 500)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        panel.title = title
        // Chromeless: the game fills the whole window with no title bar. We keep the window "titled"
        // (so it stays resizable + a real key window) but make the bar transparent, hide its text, and
        // hide the traffic-light buttons. Dragging moves the window by its background instead.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false   // let a click make it key so keyboard reaches the game
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // We keep a strong `let panel`, so ARC owns it — don't let AppKit also release it on close, and
        // skip the transform animation that crashes on teardown of a Metal-backed window (same reason
        // PlayWindowController disables it).
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = PlayVoidView.backgroundBottom
        // Wrap the game view so a Liquid Glass close button can float over its top-right corner.
        panel.contentView = PiPContentView(gameView: view) { [weak self] in self?.close() }
        panel.contentAspectRatio = NSSize(width: 3, height: 2)
        panel.contentMinSize = NSSize(width: 180, height: 120)
        panel.delegate = self

        // Park it in the lower-right of the active screen, clear of the Dock.
        if let vf = NSScreen.main?.visibleFrame {
            let margin: CGFloat = 24
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - margin, y: vf.minY + margin))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    /// Close the window and stop its render surface. Idempotent — safe from the close button or session
    /// teardown. Stops rendering FIRST so the renderer can't read a driver the session is tearing down.
    func close() {
        guard !didClose else { return }
        didClose = true
        metalView.isPaused = true
        metalView.delegate = nil
        panel.delegate = nil          // we already fired onClose below; skip windowWillClose
        panel.close()
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        metalView.isPaused = true
        metalView.delegate = nil
        onClose?()
    }
}

/// The PiP's content: the live game view fills the window, with a Liquid Glass **close** button that
/// fades in at the top-right while the pointer is over the window and fades back out when it leaves —
/// so the mini screen stays uncluttered but is always one hover away from closing.
@MainActor
private final class PiPContentView: NSView {
    private let closeButton = GlassButton(symbol: "xmark", tooltip: "Close")
    private var tracking: NSTrackingArea?

    init(gameView: NSView, onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        gameView.autoresizingMask = [.width, .height]
        gameView.frame = bounds
        addSubview(gameView)

        closeButton.onClick = onClose
        closeButton.alphaValue = 0            // hidden until hovered
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        let m: CGFloat = 12
        let s = closeButton.measuredWidth
        closeButton.frame = CGRect(x: bounds.maxX - s - m, y: bounds.maxY - s - m, width: s, height: s)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) { fadeCloseButton(to: 1) }
    override func mouseExited(with event: NSEvent) { fadeCloseButton(to: 0) }

    private func fadeCloseButton(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            closeButton.animator().alphaValue = alpha
        }
    }
}
