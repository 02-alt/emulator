import AppKit

/// The counterpart to ``SendFlourish`` for removal: the deleted game's cartridge **drops away** from
/// its shelf slot — falling under gravity, tumbling a little, and dissolving into a soft dust puff —
/// while the shelf re-lays behind it. Purely decorative; removes itself when done. Pair with
/// ``SoundFX/playRemoved()``.
@MainActor
final class DeleteFlourish: NSView {
    /// Play the drop over `window`'s content. `cart` is the game's cartridge image (see
    /// ``CartridgeTileView/cartridgeImage(for:side:)``); `rect` is its on-screen slot in the content
    /// view's coordinates (non-flipped — y up). No-op without a window.
    static func play(in window: NSWindow?, cart: NSImage, rect: CGRect) {
        guard let host = window?.contentView else { return }
        let v = DeleteFlourish(cart: cart, rect: rect)
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        v.layer?.zPosition = 1150
        v.run()
    }

    private let cart: NSImage
    private let rect: CGRect

    private init(cart: NSImage, rect: CGRect) {
        self.cart = cart
        self.rect = rect
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { false }   // y up; caller passes a non-flipped rect
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func run() {
        let dur: CFTimeInterval = 0.6

        // Dust puff — a soft grey bloom left behind at the slot as the cart drops out of it.
        let puff = CALayer()
        puff.frame = CGRect(x: rect.midX - 70, y: rect.midY - 70, width: 140, height: 140)
        puff.contents = DeleteFlourish.puffGlow(diameter: 140)
        puff.opacity = 0
        layer?.addSublayer(puff)
        animate(puff, "opacity", values: [0, 0.7, 0], times: [0, 0.2, 0.6], dur: dur)
        animate(puff, "transform.scale", values: [0.5, 1.2, 1.5], times: [0, 0.3, 0.6], dur: dur)

        // The cartridge: drops under gravity (ease-in), tumbles, shrinks and fades as it goes.
        let cartLayer = CALayer()
        cartLayer.frame = rect
        cartLayer.contents = cart.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cartLayer.contentsGravity = .resizeAspect
        cartLayer.shadowColor = NSColor.black.cgColor
        cartLayer.shadowRadius = 12
        cartLayer.shadowOpacity = 0.5
        cartLayer.shadowOffset = CGSize(width: 0, height: -6)
        layer?.addSublayer(cartLayer)

        let fallTo = rect.midY - (rect.height * 1.4 + 120)      // down and out of its slot
        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = rect.midY
        fall.toValue = fallTo
        fall.duration = dur
        fall.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)   // gravity accelerate
        cartLayer.add(fall, forKey: "fall")
        cartLayer.position = CGPoint(x: rect.midX, y: fallTo)

        // A small sideways drift + tumble so it topples rather than sliding straight down.
        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = rect.midX
        drift.toValue = rect.midX + (Bool.random() ? 26 : -26)
        drift.duration = dur
        drift.timingFunction = CAMediaTimingFunction(name: .easeIn)
        cartLayer.add(drift, forKey: "drift")

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (Bool.random() ? 1 : -1) * 0.5     // ~29°
        spin.duration = dur
        spin.timingFunction = CAMediaTimingFunction(name: .easeIn)
        cartLayer.add(spin, forKey: "spin")

        animate(cartLayer, "transform.scale", values: [1, 0.92, 0.7], times: [0, 0.4, 1], dur: dur)
        animate(cartLayer, "opacity", values: [1, 1, 0], times: [0, 0.55, 1], dur: dur)
        cartLayer.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { [weak self] in
            self?.removeFromSuperview()
        }
    }

    private func animate(_ layer: CALayer, _ keyPath: String, values: [CGFloat],
                         times: [CGFloat], dur: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { $0 as NSNumber }
        a.keyTimes = times.map { $0 as NSNumber }
        a.duration = dur
        layer.add(a, forKey: keyPath)
    }

    /// A soft grey→clear radial puff for the dust left behind at the emptied slot.
    private static func puffGlow(diameter: CGFloat) -> CGImage? {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [NSColor(white: 0.8, alpha: 0.5).cgColor,
                          NSColor(white: 0.5, alpha: 0.2).cgColor,
                          NSColor.clear.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.5, 1]) {
                let c = CGPoint(x: diameter / 2, y: diameter / 2)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                       endCenter: c, endRadius: diameter / 2, options: [])
            }
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
