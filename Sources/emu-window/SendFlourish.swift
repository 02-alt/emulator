import AppKit

/// The "whoosh" played when a game is sent to another device: the cartridges lift off the shelf and
/// streak up, converging into an **iCloud chip** near the top that holds — "Sending to <dest>…" — until
/// the real upload finishes, then resolves in place to "Sent to <dest> ✓" or "Couldn't reach iCloud".
/// So the animation reflects the actual transfer instead of firing and forgetting. Monochrome (Analogue
/// house style — no coloured glow). Purely decorative (never intercepts the mouse); full-screen-safe as
/// an in-window overlay, like ``AppAlert`` and the launch cinematic.
@MainActor
final class SendFlourish: NSView {
    /// Play the flourish over `window`'s content. `carts` are the sent games' cartridge images (see
    /// ``CartridgeTileView/cartridgeImage(for:side:)``) — up to the first three fly, fanned. `dest` is
    /// the destination label shown in the chip. Returns the instance so the caller can `resolve(...)` it
    /// when the upload completes; nil (a no-op) without a window or carts.
    @discardableResult
    static func play(in window: NSWindow?, carts: [NSImage], dest: String) -> SendFlourish? {
        guard let host = window?.contentView, !carts.isEmpty else { return nil }
        let v = SendFlourish(carts: Array(carts.prefix(3)), dest: dest)
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        v.layer?.zPosition = 1200   // above the alert/picker layer too
        v.run()
        return v
    }

    private let carts: [NSImage]
    private let dest: String
    private let trail = CAGradientLayer()
    private let flash = CALayer()

    // Chip state.
    private var chip: NSView?
    private var chipIcon: NSImageView?
    private var chipLabel: NSTextField?
    private var result: Bool?          // nil while uploading
    private var chipShown = false      // the chip has popped in (min hold begins)
    private var finishing = false

    private let flightDuration: CFTimeInterval = 0.72

    private init(carts: [NSImage], dest: String) {
        self.carts = carts
        self.dest = dest
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // y grows upward: the carts fly from just above the footer up toward the chip near the top.
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // decoration only

    /// The chip's approximate centre — the point the carts converge into.
    private var chipCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.maxY - 92) }

    private func run() {
        let cSide: CGFloat = 138                // square cart cell; the silhouette sits centred inside
        let startY = bounds.minY + 132          // just above the footer capsule
        let cx = bounds.midX
        let dur = flightDuration
        let n = carts.count
        // Fan the carts across the centre so a batch reads as a little launch of several.
        let spread: CGFloat = n > 1 ? 42 : 0
        let offsets: [CGFloat] = (0..<n).map { n == 1 ? 0 : (CGFloat($0) / CGFloat(n - 1) - 0.5) * 2 * spread }

        // Launch flash — a quiet monochrome bloom at the lift-off point (no coloured glow).
        flash.frame = CGRect(x: cx - 80, y: startY - 80, width: 160, height: 160)
        flash.contents = SendFlourish.radialGlow(diameter: 160)
        flash.opacity = 0
        layer?.addSublayer(flash)
        animate(flash, "opacity", keyframes: [0, 0.7, 0], times: [0, 0.15, 0.4], dur: dur)
        animate(flash, "transform.scale", values: [0.5, 1.3, 1.7], times: [0, 0.2, 0.4], dur: dur)

        // Glow trail — a soft white vertical streak up the centre toward the chip.
        trail.frame = CGRect(x: cx - 8, y: startY - 40, width: 16, height: 170)
        trail.cornerRadius = 8
        trail.colors = [NSColor.clear.cgColor,
                        NSColor.white.withAlphaComponent(0.28).cgColor,
                        NSColor.white.withAlphaComponent(0.6).cgColor]
        trail.startPoint = CGPoint(x: 0.5, y: 0)
        trail.endPoint = CGPoint(x: 0.5, y: 1)
        trail.opacity = 0
        layer?.addSublayer(trail)
        animate(trail, "opacity", keyframes: [0, 0.6, 0.6, 0], times: [0, 0.25, 0.7, 1], dur: dur)
        let trailRise = CABasicAnimation(keyPath: "position.y")
        trailRise.byValue = (chipCenter.y - startY) * 0.7
        trailRise.duration = dur
        trailRise.timingFunction = CAMediaTimingFunction(name: .easeIn)
        trail.add(trailRise, forKey: "rise")

        // Each cartridge rises and converges into the chip, shrinking + fading as it "uploads".
        for (i, cartImage) in carts.enumerated() {
            let cart = CALayer()
            let cxi = cx + offsets[i]
            cart.frame = CGRect(x: cxi - cSide / 2, y: startY - cSide / 2, width: cSide, height: cSide)
            cart.contents = cartImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            cart.contentsGravity = .resizeAspect          // keep the silhouette's aspect
            cart.shadowColor = NSColor.black.cgColor      // neutral depth shadow (no coloured glow)
            cart.shadowRadius = 12
            cart.shadowOpacity = 0.5
            cart.shadowOffset = CGSize(width: 0, height: -6)
            cart.zPosition = CGFloat(i == n / 2 ? n : n - i)   // centre cart on top
            layer?.addSublayer(cart)

            let delay = Double(i) * 0.07
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = [CGPoint(x: cxi, y: startY),
                           CGPoint(x: (cxi + chipCenter.x) / 2, y: bounds.midY + 20),
                           chipCenter].map { NSValue(point: $0) }
            move.keyTimes = [0, 0.45, 1]
            move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            move.duration = dur
            move.beginTime = CACurrentMediaTime() + delay
            move.fillMode = .backwards
            cart.add(move, forKey: "move")
            animateDelayed(cart, "transform.scale", values: [0.72, 0.6, 0.3], times: [0, 0.45, 1], dur: dur, delay: delay)
            animateDelayed(cart, "opacity", values: [1, 1, 0], times: [0, 0.7, 1], dur: dur, delay: delay)
            cart.position = chipCenter; cart.opacity = 0
        }

        // When the carts arrive, pop the chip in and begin the minimum hold.
        DispatchQueue.main.asyncAfter(deadline: .now() + flightDuration) { [weak self] in
            self?.showChip()
        }
        // Safety net: never hang if a result somehow never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.finishing else { return }
            self.finishing = true
            self.removeFromSuperview()
        }
    }

    // MARK: - Result

    /// Resolve the flourish to the real upload outcome — the chip snaps to "Sent ✓" or a slash, holds a
    /// beat, then fades. Safe to call before or after the chip has appeared.
    func resolve(success: Bool) {
        result = success
        applyChip()
        maybeFinish()
    }

    private func maybeFinish() {
        guard !finishing, chipShown, result != nil else { return }
        finishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in   // let the ✓/✗ read
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.quick
                ctx.timingFunction = Motion.timing
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.removeFromSuperview() }
            })
        }
    }

    // MARK: - Chip

    private func showChip() {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = DS.Color.surfaceRaised.cgColor
        chip.layer?.cornerRadius = DS.Radius.panel
        chip.layer?.borderColor = DS.Color.hairline.cgColor
        chip.layer?.borderWidth = 1
        chip.layer?.shadowColor = NSColor.black.cgColor
        chip.layer?.shadowOpacity = 0.4
        chip.layer?.shadowRadius = 12
        chip.layer?.shadowOffset = CGSize(width: 0, height: -3)
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: DS.Space.sm, left: DS.Space.md,
                                      bottom: DS.Space.sm, right: DS.Space.md)
        chip.addSubview(row)

        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        row.addArrangedSubview(icon)
        let label = NSTextField(labelWithString: "")
        row.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: chip.topAnchor),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.xl),
        ])

        self.chip = chip
        self.chipIcon = icon
        self.chipLabel = label
        chipShown = true
        applyChip()

        // Pop in: fade + a subtle scale (presentation-only, so no layout shift).
        chip.alphaValue = 0
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6; pop.toValue = 1
        pop.duration = Motion.quick
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1)   // slight overshoot
        chip.layer?.add(pop, forKey: "pop")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            chip.animator().alphaValue = 1
        }

        maybeFinish()
    }

    /// Set the chip's icon + text for the current state (uploading / sent / failed). White check on
    /// success (no green), muted glyph otherwise.
    private func applyChip() {
        guard let icon = chipIcon, let label = chipLabel else { return }
        let symbol: String, text: String, tint: NSColor
        switch result {
        case .some(true):  symbol = "checkmark.circle.fill";   text = "Sent to \(dest)";       tint = DS.Color.textPrimary
        case .some(false): symbol = "icloud.slash";            text = "Couldn’t reach iCloud"; tint = DS.Color.textSecondary
        case .none:        symbol = "icloud.and.arrow.up.fill"; text = "Sending to \(dest)…";   tint = DS.Color.textSecondary
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        label.attributedStringValue = DS.Text.plain(text, size: 13, color: DS.Color.textPrimary)
    }

    // MARK: - Animation helpers

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

    /// A soft white→clear radial glow image for the launch flash (monochrome — no blue).
    private static func radialGlow(diameter: CGFloat) -> CGImage? {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [NSColor.white.withAlphaComponent(0.55).cgColor,
                          NSColor.white.withAlphaComponent(0.12).cgColor,
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
