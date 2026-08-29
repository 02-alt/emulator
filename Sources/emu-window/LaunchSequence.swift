import AppKit
import AVFoundation
import LibraryKit

/// Tunable knobs for the launch cinematic. Read fresh each time the cinematic runs.
@MainActor
final class LaunchAnimationConfig {
    static let shared = LaunchAnimationConfig()

    var baseWidth: CGFloat = 300        // the cart's on-stage size
    var stageCenterY: CGFloat = 0.42    // rest height, as a fraction of the stage (0 = top, 1 = bottom)
    var liftDuration: CGFloat = 0.55    // how long the lift off the shelf takes
    var textFade: CGFloat = 0.5         // text/buttons fade over this fraction of the lift (1 = gone at centre)
    var holdDuration: CGFloat = 0.15    // beat the cart holds at centre before it drops
    var diveDuration: CGFloat = 0.5     // how long the straight drop takes
    var diveScale: CGFloat = 0.7        // how much the cart shrinks as it plunges
    var diveDepth: CGFloat = 0.8        // how far below the bottom edge it plunges (× cart height)
    var soundLead: CGFloat = 0.12       // how long before the cart is gone the "cha-chunk" plays
    var videoGap: CGFloat = 0.1         // pause between the cart vanishing and the clip powering on
    var bootLength: CGFloat = 4.0       // how long the boot clip plays before crossfading to the game

    func reset() { self.copy(from: LaunchAnimationConfig()) }
    private func copy(from d: LaunchAnimationConfig) {
        baseWidth = d.baseWidth; stageCenterY = d.stageCenterY; liftDuration = d.liftDuration
        textFade = d.textFade; holdDuration = d.holdDuration; diveDuration = d.diveDuration
        diveScale = d.diveScale; diveDepth = d.diveDepth; soundLead = d.soundLead
        videoGap = d.videoGap; bootLength = d.bootLength
    }
}

/// The launch cinematic: when a game is played, the selected cartridge lifts straight off the shelf,
/// the shelf dims to black beneath it (title, metadata and footer icons dissolving away), the cart
/// **turns on itself** and **plunges down into the darkening screen** — and then the screen powers on
/// into the authentic **Game Boy Advance startup** clip before the live game is revealed.
///
/// It runs as an in-window overlay **subview** of the host's content view (full-screen-safe, unlike a
/// child window). Near the end the host presents the game *underneath* the overlay, which is re-parented
/// on top of it and then fades away to reveal it. A click anywhere skips straight to the game.
@MainActor
final class LaunchCinematic: NSObject {
    private weak var window: NSWindow?
    private let sequence: LaunchSequenceView
    private var didFinish = false

    /// Swap the host window's content to the live game (called while the overlay still covers it), and
    /// return the game screen's rect (content-view coords) so the boot clip can morph into it.
    private let onPresentGame: () -> CGRect?
    /// Tear the cinematic down (host clears its reference so a future launch can start).
    private let onDone: () -> Void

    init(parent: NSWindow, game: Game, startFrame: CGRect,
         onPresentGame: @escaping () -> CGRect?, onDone: @escaping () -> Void) {
        self.window = parent
        self.onPresentGame = onPresentGame
        self.onDone = onDone
        sequence = LaunchSequenceView(frame: parent.contentView?.bounds ?? .zero,
                                      game: game, startFrame: startFrame)
        sequence.autoresizingMask = [.width, .height]
        super.init()
    }

    /// Lay the overlay over the shelf and play the sequence through to the game.
    func start() {
        guard let content = window?.contentView else { return }
        sequence.frame = content.bounds
        content.addSubview(sequence)
        sequence.onFinish = { [weak self] in self?.finish() }
        sequence.run()
    }

    /// End the intro with a clean **fade to black**, then present the game and **fade it in from black**
    /// — simple and always smooth, independent of the clip's framerate. Idempotent (video end + skip).
    private func finish() {
        guard !didFinish else { return }
        didFinish = true

        // Phase 1 — dip the Game Boy clip to black.
        sequence.fadeToBlack { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Phase 2 — present the game beneath the (now opaque-black) overlay, keep the overlay on
                // top through the content swap, then fade it away to reveal the game.
                _ = self.onPresentGame()
                if let content = self.window?.contentView, self.sequence.superview !== content {
                    self.sequence.frame = content.bounds
                    content.addSubview(self.sequence)
                }
                self.sequence.fadeAway { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sequence.removeFromSuperview()
                        self.sequence.teardown()
                        self.onDone()
                    }
                }
            }
        }
    }
}

// MARK: - The animated stage

@MainActor
private final class LaunchSequenceView: NSView {
    var onFinish: (() -> Void)?

    private let tile: CartridgeTileView
    private let startFrame: CGRect
    private let ratio: CGFloat                 // tile height / width, held constant as the cart scales
    private let cfg = LaunchAnimationConfig.shared
    private var baseWidth: CGFloat { cfg.baseWidth }   // the cart's on-stage size (layer scales to/from this)
    private let screen = BootScreenView()
    private var started = false
    private var pending: [Timer] = []          // scheduled phases, invalidated on skip/teardown
    // The dark the boot screen sits on once the shelf's own content has dissolved away.
    private let stageDark = PlayVoidView.backgroundBottom

    init(frame: CGRect, game: Game, startFrame: CGRect) {
        self.tile = CartridgeTileView(game: game)
        self.startFrame = startFrame
        self.ratio = startFrame.height / max(1, startFrame.width)
        super.init(frame: frame)
        wantsLayer = true
        // Fully transparent: the real (black) shelf shows through and dissolves its own text/buttons —
        // we never paint a background, so the colour is always exactly right.
        layer?.backgroundColor = NSColor.clear.cgColor

        // The cart is rendered ONCE at its full centre-stage size, then moved purely by animating its
        // layer transform (translate + scale). Transforms are GPU compositing — no per-frame redraw of
        // the vector cartridge — so the motion is perfectly smooth. `.onSetNeedsDisplay` keeps the layer
        // from re-rasterising during the animation.
        tile.setSelected(true, animated: false)   // full-strength cart, no side-recede
        tile.hoverEnabled = false                  // we own its transform; its hover mustn't fight us
        tile.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(tile)

        screen.frame = screenPanelRect()
        screen.alphaValue = 0
        addSubview(screen)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }          // top-left origin, matching the shelf's tile frames

    // Every click lands on the stage (to skip) — no subview (least of all the cart) intercepts it.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    // MARK: Geometry

    private var baseHeight: CGFloat { baseWidth * ratio }
    /// Centre stage: the cart's fixed on-screen frame — `baseWidth` wide, centred horizontally, a little
    /// above the middle. The cart is drawn at this size once; every pose is a transform off it.
    private var liftFrame: CGRect {
        CGRect(x: bounds.midX - baseWidth / 2, y: bounds.height * cfg.stageCenterY - baseHeight / 2,
               width: baseWidth, height: baseHeight)
    }
    private var stageCenter: CGPoint { CGPoint(x: liftFrame.midX, y: liftFrame.midY) }
    private var shelfCenter: CGPoint { CGPoint(x: startFrame.midX, y: startFrame.midY) }
    private var diveCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.height + baseHeight * cfg.diveDepth) }

    /// A transform that moves the fixed-frame cart so it appears centred on `center` at `scale`, scaling
    /// about its own middle (anchor stays (0,0), so we translate to the centre and back like the rest of
    /// the app's `Motion.scaleAboutCenter`).
    private func pose(scale s: CGFloat, center c: CGPoint) -> CATransform3D {
        let w = liftFrame.width, h = liftFrame.height
        var t = CATransform3DMakeTranslation(c.x - stageCenter.x, c.y - stageCenter.y, 0)  // world move
        t = CATransform3DTranslate(t, w / 2, h / 2, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -w / 2, -h / 2, 0)
        return t
    }
    private var shelfPose: CATransform3D { pose(scale: startFrame.width / baseWidth, center: shelfCenter) }
    private var divePose: CATransform3D { pose(scale: cfg.diveScale, center: diveCenter) }

    /// The boot screen plays at exactly the game screen's rect, so the end is a pure crossfade (no size
    /// jump). The game rect is in the player's bottom-left coords; this view is flipped, so mirror y.
    private func screenPanelRect() -> CGRect {
        let r = PlayVoidView.gameScreenRect(in: bounds)
        guard r.width > 0 else {   // degenerate (tiny window) — fall back to a centred 3:2 panel
            let w = bounds.width * 0.66, h = w / 1.5
            return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        }
        return CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Sequence

    private var runStart: CFTimeInterval = 0

    func run() {
        guard !started else { return }
        started = true
        runStart = CACurrentMediaTime()

        // Render the cart once at centre-stage size, then place it on the shelf via a transform. Force
        // the (expensive vector) rasterisation to happen NOW — before the first animated frame — so the
        // lift doesn't hitch on its opening frame.
        tile.frame = liftFrame
        tile.layoutSubtreeIfNeeded()
        tile.layer?.transform = shelfPose
        tile.layer?.setNeedsDisplay()
        tile.layer?.displayIfNeeded()

        let diveStart = CFTimeInterval(cfg.liftDuration + cfg.holdDuration)
        let diveEnd = diveStart + CFTimeInterval(cfg.diveDuration)

        // Phase 1 — lift the cart off the shelf to centre stage (transform → identity). Ease-in-out so it
        // starts and settles gently (an ease-out felt like it "popped" off the shelf).
        animateTransform(to: CATransform3DIdentity, dur: CFTimeInterval(cfg.liftDuration),
                         timing: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.2, 1))

        // Phase 2 — after a brief hold, drop it straight down into the (now black) screen; the
        // "cha-chunk" lands as it seats home.
        at(diveStart) { $0.dive() }
        at(diveEnd - CFTimeInterval(cfg.soundLead)) { _ in SoundFX.shared.playCartridgeInsert() }

        // Phase 3 — the screen powers on into the Game Boy Advance startup clip.
        at(diveEnd + CFTimeInterval(cfg.videoGap)) { $0.powerOnScreen() }
    }

    /// Drop the cart straight down off the bottom of the screen — shrinking and fading into the dark.
    private func dive() {
        animateTransform(to: divePose, dur: CFTimeInterval(cfg.diveDuration),
                         timing: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.85, 0.6))   // ease-in
        guard let l = tile.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + CFTimeInterval(cfg.diveDuration) * 0.6
        fade.duration = CFTimeInterval(cfg.diveDuration) * 0.4
        fade.timingFunction = Motion.timing
        fade.fillMode = .both          // hold opacity 1 through the delay so the cart stays visible as it drops
        fade.isRemovedOnCompletion = false
        l.opacity = 0
        l.add(fade, forKey: "fade")
    }

    /// Animate the cart's layer transform from its current (in-flight) value — pure GPU, no redraw.
    private func animateTransform(to t: CATransform3D, dur: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let l = tile.layer else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = l.presentation()?.transform ?? l.transform
        a.toValue = NSValue(caTransform3D: t)
        a.duration = dur
        a.timingFunction = timing
        l.transform = t
        l.add(a, forKey: "transform")
    }

    /// Reveal the boot screen with a soft "power-on" pop, then play the clip. When it finishes (or if
    /// it can't load), hand off to the live game.
    private func powerOnScreen() {
        screen.frame = screenPanelRect()
        guard screen.load() else { finish(); return }

        screen.onEnded = { [weak self] in self?.finish() }   // fallback if the clip is shorter than bootLength
        if let layer = screen.layer {
            layer.transform = Motion.scaleAboutCenter(0.9, in: screen.bounds.size)
            Motion.spring(layer, keyPath: "transform",
                          to: NSValue(caTransform3D: Motion.scaleAboutCenter(1, in: screen.bounds.size)),
                          response: 0.5, dampingRatio: 0.72)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = Motion.timing
            screen.animator().alphaValue = 1
        }
        screen.play()
        // Cross-cut to the game as the logo finishes — before the clip's blank white tail, so there's
        // no dead pause.
        at(TimeInterval(cfg.bootLength)) { $0.finish() }
    }

    /// Run a phase on the main actor after `delay`, tracked so it can be cancelled on skip/teardown.
    /// The phase receives `self` as its argument, so it captures nothing non-Sendable of its own.
    private func at(_ delay: TimeInterval, _ phase: @escaping @MainActor @Sendable (LaunchSequenceView) -> Void) {
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                phase(self)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pending.append(t)
    }

    private func finish() { onFinish?() }

    /// Fade the boot clip out to black: the boot panel dissolves and the whole stage turns opaque black,
    /// so the intro ends on a clean black screen (the overlay is then opaque, ready to cover the game).
    func fadeToBlack(completion: @escaping @Sendable () -> Void) {
        let bg = CABasicAnimation(keyPath: "backgroundColor")
        bg.fromValue = layer?.backgroundColor
        bg.toValue = NSColor.black.cgColor
        bg.duration = 0.32
        bg.timingFunction = Motion.timing
        bg.fillMode = .forwards
        bg.isRemovedOnCompletion = false
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.add(bg, forKey: "toBlack")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = Motion.timing
            screen.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Fade the whole (black) overlay away to reveal the game beneath it.
    func fadeAway(completion: @escaping @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// Stop everything (invoked when the cinematic is dismissed) so no timer or player outlives it.
    func teardown() {
        pending.forEach { $0.invalidate() }
        pending.removeAll()
        screen.teardown()
    }

    // A click anywhere skips the rest of the cinematic — but not in the first beat, so the very click
    // that launched the game (GlassBar fires on mouse-down) can never skip it before it's even seen.
    override func mouseDown(with event: NSEvent) {
        guard CACurrentMediaTime() - runStart > 0.6 else { return }
        finish()
    }
}

// MARK: - Boot screen (the GBA startup clip)

/// Plays the bundled Game Boy Advance startup clip inside a rounded screen panel. The clip is 3:2, so
/// it fills the panel edge-to-edge like a real console screen.
@MainActor
private final class BootScreenView: NSView {
    var onEnded: (() -> Void)?

    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.tile
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.backgroundColor = NSColor.white.cgColor   // the clip's own background is white
        playerLayer.videoGravity = .resize               // panel is 3:2, so no letterbox
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]   // scales during the morph
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }

    /// Load the bundled clip. Returns false (so the caller can skip the boot) if it's missing.
    func load() -> Bool {
        guard let url = Bundle.moduleResources?.url(forResource: "gba-boot", withExtension: "mp4") else {
            NSLog("LaunchCinematic: missing gba-boot.mp4"); return false
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p
        playerLayer.player = p
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        return true
    }

    func play() { player?.play() }

    func teardown() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playerLayer.player = nil
        player = nil
    }
}
