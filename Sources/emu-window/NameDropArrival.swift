import AppKit

/// The "a game just arrived from your other device" moment — a NameDrop-style flourish over the
/// library: the backdrop dims, concentric rings pulse outward, and the game's cover rises into place
/// with a soft glow, then everything fades and the Continue card is revealed. Purely decorative and
/// self-dismissing; it blocks input only for the ~2s it's on screen so a stray click can't fire behind
/// it. Drawn in the app's language (pixel type, hairline borders) rather than a literal Apple clone.
@MainActor
final class NameDropArrival: NSView {

    /// Play the arrival over `window`'s content. `completion` fires on the main actor once the flourish
    /// has faded — the caller uses it to refresh the shelf (e.g. reveal the Continue card).
    static func show(in window: NSWindow?, image: NSImage?, title: String, device: String,
                     completion: @escaping @MainActor () -> Void) {
        guard let host = window?.contentView else { completion(); return }
        host.subviews.compactMap { $0 as? NameDropArrival }.forEach { $0.removeFromSuperview() }
        let v = NameDropArrival(image: image, title: title, device: device, onDone: completion)
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        v.run()
    }

    private let coverWrap = NSView()      // holds the glow shadow (cover itself clips its corners)
    private let cover = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private var rings: [CALayer] = []
    private let onDone: @MainActor () -> Void

    private let coverH: CGFloat = 132
    private var coverW: CGFloat = 132

    private init(image: NSImage?, title: String, device: String, onDone: @escaping @MainActor () -> Void) {
        self.onDone = onDone
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        alphaValue = 0   // whole overlay fades in/out

        if let image, image.size.height > 0 {
            coverW = min(max((coverH * image.size.width / image.size.height).rounded(), 90), 200)
        }

        // Three rings behind the cover, sized to pulse outward from its center.
        for _ in 0..<3 {
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
            ring.cornerRadius = 60
            ring.borderWidth = 2
            ring.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            ring.backgroundColor = NSColor.clear.cgColor
            ring.opacity = 0
            layer?.addSublayer(ring)
            rings.append(ring)
        }

        coverWrap.wantsLayer = true
        coverWrap.layer?.shadowColor = NSColor.white.cgColor
        coverWrap.layer?.shadowRadius = 22
        coverWrap.layer?.shadowOpacity = 0.0   // animated up as it lands
        coverWrap.layer?.shadowOffset = .zero
        addSubview(coverWrap)

        cover.image = image
        cover.wantsLayer = true
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.layer?.cornerRadius = DS.Radius.small
        cover.layer?.borderWidth = 1
        cover.layer?.borderColor = DS.Color.hairline.cgColor
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = DS.Color.surfaceRaised.cgColor
        coverWrap.addSubview(cover)

        eyebrow.stringValue = "RECEIVED FROM \(device.uppercased())"
        eyebrow.font = DS.pixel(10)
        eyebrow.textColor = DS.Color.textSecondary
        eyebrow.alignment = .center
        eyebrow.wantsLayer = true
        addSubview(eyebrow)

        titleField.stringValue = title
        titleField.font = DS.pixel(15)
        titleField.textColor = DS.Color.textPrimary
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.wantsLayer = true
        addSubview(titleField)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        let cx = bounds.midX
        let cy = bounds.midY + 18   // nudge the cover up so the labels sit under it, centered as a group
        coverWrap.frame = CGRect(x: cx - coverW / 2, y: cy - coverH / 2, width: coverW, height: coverH)
        cover.frame = coverWrap.bounds
        for ring in rings { ring.position = CGPoint(x: cx, y: cy) }

        let labelW: CGFloat = 360
        eyebrow.frame = CGRect(x: cx - labelW / 2, y: coverWrap.frame.minY - 30, width: labelW, height: 14)
        titleField.frame = CGRect(x: cx - labelW / 2, y: coverWrap.frame.minY - 54, width: labelW, height: 22)
    }

    // Block input only while the flourish is up (it self-dismisses in ~2s).
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    private func run() {
        layoutSubtreeIfNeeded()

        // Backdrop + everything fades in together.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }

        // Rings pulse outward, staggered.
        for (i, ring) in rings.enumerated() {
            let begin = CACurrentMediaTime() + Double(i) * 0.16
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.5; scale.toValue = 3.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.1
            group.beginTime = begin
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .backwards
            ring.add(group, forKey: "pulse")
        }

        // Cover rises + scales into place with a spring, and its glow blooms.
        if let cl = coverWrap.layer {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -36; rise.toValue = 0    // flipped view: start lower, settle up
            rise.duration = 0.55
            rise.timingFunction = Motion.timing
            cl.add(rise, forKey: "rise")

            cl.add(Motion.springAnimation("transform.scale", from: 0.6, to: 1,
                                          response: 0.5, dampingRatio: 0.7), forKey: "pop")

            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.0; glow.toValue = 0.85
            glow.duration = 0.5
            glow.autoreverses = true      // bloom, then settle back down
            glow.timingFunction = Motion.timing
            cl.add(glow, forKey: "glow")
        }

        // Labels rise + fade in slightly after the cover lands.
        for (label, delay) in [(eyebrow, 0.28), (titleField, 0.34)] {
            guard let ll = label.layer else { continue }
            let begin = CACurrentMediaTime() + delay
            let up = CABasicAnimation(keyPath: "transform.translation.y")
            up.fromValue = -10; up.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [up, fade]
            group.duration = 0.4
            group.beginTime = begin
            group.timingFunction = Motion.timing
            group.fillMode = .backwards
            ll.add(group, forKey: "label-in")
        }

        // Hold, then fade the whole thing out and hand control back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
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
}
