import AppKit

/// The "whoosh" played when a game is sent to another device: the cartridge's cover lifts off the shelf
/// and streaks up off the top edge — toward the cloud — with a glowing trail and a soft launch flash,
/// then removes itself. Purely decorative (never intercepts the mouse); full-screen-safe as an in-window
/// overlay, like ``AppAlert`` and the launch cinematic.
@MainActor
final class SendFlourish: NSView {
    /// Play the flourish over `window`'s content. `carts` are the sent games' cartridge images (see
    /// ``CartridgeTileView/cartridgeImage(for:side:)``) — up to the first three fly, fanned. No-op
    /// without a window or carts.
    static func play(in window: NSWindow?, carts: [NSImage]) {
        guard let host = window?.contentView, !carts.isEmpty else { return }
        let v = SendFlourish(carts: Array(carts.prefix(3)))
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        v.layer?.zPosition = 1200   // above the alert/picker layer too
        v.run()
    }

    private let carts: [NSImage]
    private let trail = CAGradientLayer()
    private let flash = CALayer()

    private init(carts: [NSImage]) {
        self.carts = carts
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // y grows upward: the cart flies from just above the footer up and off the top edge.
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // decoration only

    private func run() {
        let cSide: CGFloat = 138                // square cart cell; the silhouette sits centred inside
        let startY = bounds.minY + 132          // just above the footer capsule
        let endY = bounds.maxY + cSide          // off the top edge
        let cx = bounds.midX
        let dur: CFTimeInterval = 0.85
        let n = carts.count
        // Fan the carts across the centre so a batch reads as a little launch of several.
        let spread: CGFloat = n > 1 ? 42 : 0
        let offsets: [CGFloat] = (0..<n).map { n == 1 ? 0 : (CGFloat($0) / CGFloat(n - 1) - 0.5) * 2 * spread }

        // Launch flash — a quick radial bloom at the lift-off point.
        flash.frame = CGRect(x: cx - 80, y: startY - 80, width: 160, height: 160)
        flash.contents = SendFlourish.radialGlow(diameter: 160)
        flash.opacity = 0
        layer?.addSublayer(flash)
        animate(flash, "opacity", keyframes: [0, 0.9, 0], times: [0, 0.15, 0.4], dur: dur)
        animate(flash, "transform.scale", values: [0.5, 1.3, 1.7], times: [0, 0.2, 0.4], dur: dur)

        // Glow trail — a soft vertical streak up the centre.
        trail.frame = CGRect(x: cx - 10, y: startY - 40, width: 20, height: 170)
        trail.cornerRadius = 10
        trail.colors = [NSColor.clear.cgColor,
                        NSColor.systemBlue.withAlphaComponent(0.5).cgColor,
                        NSColor.white.withAlphaComponent(0.7).cgColor]
        trail.startPoint = CGPoint(x: 0.5, y: 0)
        trail.endPoint = CGPoint(x: 0.5, y: 1)
        trail.opacity = 0
        layer?.addSublayer(trail)
        animate(trail, "opacity", keyframes: [0, 0.85, 0.85, 0], times: [0, 0.25, 0.7, 1], dur: dur)
        let trailRise = CABasicAnimation(keyPath: "position.y")
        trailRise.byValue = (endY - startY) * 0.7
        trailRise.duration = dur
        trailRise.timingFunction = CAMediaTimingFunction(name: .easeIn)
        trail.add(trailRise, forKey: "rise")

        // Each cartridge rises off the top, fanned and slightly staggered so they read as a small deck.
        for (i, cartImage) in carts.enumerated() {
            let cart = CALayer()
            let cxi = cx + offsets[i]
            cart.frame = CGRect(x: cxi - cSide / 2, y: startY - cSide / 2, width: cSide, height: cSide)
            cart.contents = cartImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            cart.contentsGravity = .resizeAspect          // keep the silhouette's aspect; glow hugs its alpha
            cart.shadowColor = NSColor.systemBlue.cgColor
            cart.shadowRadius = 16
            cart.shadowOpacity = 0.85
            cart.shadowOffset = .zero
            cart.zPosition = CGFloat(i == n / 2 ? n : n - i)   // centre cart on top
            layer?.addSublayer(cart)

            let delay = Double(i) * 0.07
            let rise = CAKeyframeAnimation(keyPath: "position.y")
            rise.values = [startY, bounds.midY + 40, endY]
            rise.keyTimes = [0, 0.45, 1]
            rise.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            rise.duration = dur
            rise.beginTime = CACurrentMediaTime() + delay
            rise.fillMode = .backwards
            cart.add(rise, forKey: "rise")
            animateDelayed(cart, "transform.scale", values: [0.7, 1.06, 0.9], times: [0, 0.4, 1], dur: dur, delay: delay)
            animateDelayed(cart, "opacity", values: [1, 1, 0], times: [0, 0.7, 1], dur: dur, delay: delay)
            cart.position.y = endY; cart.opacity = 0
        }

        let total = dur + Double(max(0, n - 1)) * 0.07 + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            self?.removeFromSuperview()
        }
    }

    private func animateDelayed(_ layer: CALayer, _ keyPath: String, values: [CGFloat],
                                times: [CGFloat], dur: CFTimeInterval, delay: Double) {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { $0 as NSNumber }
        a.keyTimes = times.map { $0 as NSNumber }
        a.duration = dur
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        layer.add(a, forKey: keyPath)
    }

    /// A keyframe opacity/scale helper (values default to the `keyframes`).
    private func animate(_ layer: CALayer, _ keyPath: String,
                         from: CGFloat? = nil, to: CGFloat? = nil,
                         values: [CGFloat]? = nil, keyframes: [CGFloat]? = nil,
                         times: [CGFloat], dur: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (values ?? keyframes ?? [from ?? 0, to ?? 1]).map { $0 as NSNumber }
        a.keyTimes = times.map { $0 as NSNumber }
        a.duration = dur
        layer.add(a, forKey: keyPath)
    }

    /// A soft white→clear radial glow image for the launch flash.
    private static func radialGlow(diameter: CGFloat) -> CGImage? {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [NSColor.white.withAlphaComponent(0.9).cgColor,
                          NSColor.systemBlue.withAlphaComponent(0.35).cgColor,
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
