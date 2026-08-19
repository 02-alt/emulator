import AppKit
import LibraryKit

/// The "a game just arrived from your other device" moment — the macOS mirror of the iPhone's
/// `TransferArrivalOverlay`, in AppKit. The library dims to black, concentric radar rings pulse
/// outward AirDrop/NameDrop-style, the received game's **cartridge** swoops in from the top edge with a
/// blue glow and a subtle "received" chime, announces "RECEIVED from <device>", holds a beat, then
/// dissolves and hands back so the Continue card can be revealed. Decorative and self-dismissing;
/// blocks input only while it's up (click anywhere to end it early).
@MainActor
final class NameDropArrival: NSView {

    /// Play the arrival over `window`'s content. `completion` fires on the main actor once it fades —
    /// the caller uses it to refresh the shelf (reveal the Continue card). `cover` overrides the game's
    /// on-disk art (e.g. the just-transferred box art, before the shelf's copy has been fetched).
    static func show(in window: NSWindow?, game: Game, cover: NSImage?, device: String,
                     completion: @escaping @MainActor () -> Void) {
        guard let host = window?.contentView else { completion(); return }
        host.subviews.compactMap { $0 as? NameDropArrival }.forEach { $0.removeFromSuperview() }
        let v = NameDropArrival(game: game, cover: cover, device: device, onDone: completion)
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        v.run()
    }

    private let scrim = CALayer()
    private let glow = CAGradientLayer()
    private var rings: [CALayer] = []
    private let cartWrap = NSView()          // transform target for the swoop; holds the cartridge tile
    private let cart: CartridgeTileView
    private let eyebrow = NSTextField(labelWithString: "RECEIVED")
    private let titleField = NSTextField(labelWithString: "")
    private let deviceField = NSTextField(labelWithString: "")
    private let onDone: @MainActor () -> Void
    private var finished = false

    private let cartSize: CGFloat = 224      // the cartridge fills a square (see CartridgeTileView.draw)
    private let accent = NSColor.systemBlue

    private init(game: Game, cover: NSImage?, device: String, onDone: @escaping @MainActor () -> Void) {
        self.cart = CartridgeTileView(game: game)
        self.onDone = onDone
        super.init(frame: .zero)
        wantsLayer = true
        // The shelf's focused cartridge tile sets a raised zPosition; sit decisively above it so the
        // scrim actually covers the shelf instead of the live cart bleeding through the overlay.
        layer?.zPosition = 1000
        alphaValue = 0

        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.97).cgColor
        layer?.addSublayer(scrim)

        // A soft blue radial bloom behind the cartridge.
        glow.type = .radial
        glow.colors = [accent.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        layer?.addSublayer(glow)

        // Four radar rings that pulse outward from the cartridge's resting center.
        for _ in 0..<4 {
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 220, height: 220)
            ring.cornerRadius = 110
            ring.borderWidth = 2.5
            ring.borderColor = accent.withAlphaComponent(0.55).cgColor
            ring.backgroundColor = NSColor.clear.cgColor
            ring.opacity = 0
            layer?.addSublayer(ring)
            rings.append(ring)
        }

        // The actual shelf cartridge (same renderer as the carousel), rendered as its selected/full
        // state with no interaction, so the received game shows exactly as it will on the shelf.
        cartWrap.wantsLayer = true
        addSubview(cartWrap)
        cart.hoverEnabled = false
        if let cover { cart.setCover(cover) }
        cart.setSelected(true, animated: false)
        cartWrap.addSubview(cart)

        eyebrow.font = DS.pixel(11)
        eyebrow.textColor = accent
        eyebrow.alignment = .center
        eyebrow.wantsLayer = true

        titleField.stringValue = game.displayTitle
        titleField.font = DS.pixel(16)
        titleField.textColor = DS.Color.textPrimary
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.wantsLayer = true

        deviceField.stringValue = "from \(device)"
        deviceField.font = DS.pixel(11)
        deviceField.textColor = DS.Color.textTertiary
        deviceField.alignment = .center
        deviceField.wantsLayer = true

        for f in [eyebrow, titleField, deviceField] { f.alphaValue = 0; addSubview(f) }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Rest position: cartridge a touch above center so the text block sits beneath it, centered as a group.
    private var restCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY + 44) }

    override func layout() {
        super.layout()
        scrim.frame = bounds
        let c = restCenter
        cartWrap.frame = CGRect(x: c.x - cartSize / 2, y: c.y - cartSize / 2, width: cartSize, height: cartSize)
        cart.frame = cartWrap.bounds
        glow.frame = CGRect(x: c.x - 260, y: c.y - 260, width: 520, height: 520)
        for ring in rings { ring.position = c }

        let w: CGFloat = 380
        let blockTop = cartWrap.frame.minY + 4   // non-flipped: below the cartridge is lower y
        eyebrow.frame = CGRect(x: c.x - w / 2, y: blockTop - 14, width: w, height: 14)
        titleField.frame = CGRect(x: c.x - w / 2, y: blockTop - 40, width: w, height: 24)
        deviceField.frame = CGRect(x: c.x - w / 2, y: blockTop - 60, width: w, height: 14)
    }

    // Block input while the flourish is up (it self-dismisses); a click ends it early.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { finish() }

    private func run() {
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }

        // Cartridge swoops in from above the top edge, with a slight rotate + spring settle.
        if let cl = cartWrap.layer {
            let dropFrom = bounds.maxY + cartSize - restCenter.y   // start above the top edge
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = dropFrom; drop.toValue = 0            // +y is up (non-flipped): start high, settle
            drop.duration = 0.6
            drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            cl.add(drop, forKey: "drop")

            let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
            tilt.fromValue = -8 * CGFloat.pi / 180; tilt.toValue = 0
            tilt.duration = 0.6
            tilt.timingFunction = Motion.timing
            cl.add(tilt, forKey: "tilt")

            cl.add(Motion.springAnimation("transform.scale", from: 0.5, to: 1,
                                          response: 0.55, dampingRatio: 0.7), forKey: "pop")
        }

        // Glow blooms with the landing.
        let glowGrow = CABasicAnimation(keyPath: "transform.scale")
        glowGrow.fromValue = 0.2; glowGrow.toValue = 1
        let glowFade = CABasicAnimation(keyPath: "opacity")
        glowFade.fromValue = 0; glowFade.toValue = 1
        let glowGroup = CAAnimationGroup()
        glowGroup.animations = [glowGrow, glowFade]
        glowGroup.duration = 0.55
        glowGroup.timingFunction = Motion.timing
        glowGroup.fillMode = .forwards; glowGroup.isRemovedOnCompletion = false
        glow.add(glowGroup, forKey: "glow"); glow.opacity = 1

        // Radar rings pulse outward on a staggered, repeating loop while the cartridge rests.
        let period: CFTimeInterval = 2.2
        for (i, ring) in rings.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.18; scale.toValue = 2.9
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = period
            group.beginTime = CACurrentMediaTime() + 0.4 + Double(i) * period / Double(rings.count)
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .backwards
            ring.add(group, forKey: "radar")
        }

        // The subtle "received" chime lands with the cartridge; the text rises in just after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SoundFX.shared.playReceived() }
        for (label, delay) in [(eyebrow, 0.34), (titleField, 0.4), (deviceField, 0.46)] {
            let begin = CACurrentMediaTime() + delay
            if let ll = label.layer {
                let up = CABasicAnimation(keyPath: "transform.translation.y")
                up.fromValue = -10; up.toValue = 0
                up.duration = 0.4; up.beginTime = begin
                up.timingFunction = Motion.timing; up.fillMode = .backwards
                ll.add(up, forKey: "rise")
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = Motion.timing
                label.animator().alphaValue = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = Motion.timing
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                self?.onDone()
            }
        })
    }
}
