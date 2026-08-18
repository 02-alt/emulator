import AppKit

/// A round, **icon-only Liquid Glass** button: the plain glass material (`NSGlassEffectView` on
/// macOS 26, `NSVisualEffectView` blur fallback) with a centered SF Symbol. Flat glass — no tint,
/// no dome. A tooltip names the action. Lifts slightly on hover.
final class GlassButton: NSView {
    var onClick: (() -> Void)?

    private let symbolName: String
    private let enabled: Bool
    private let disc: CGFloat = 44   // HIG minimum 44×44pt hit region

    private let glassContainer = NSView()   // scaled on hover
    private var glassView: NSView!
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(symbol: String, tooltip: String, enabled: Bool = true) {
        self.symbolName = symbol
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = tooltip
        glassContainer.wantsLayer = true
        addSubview(glassContainer)
        buildGlass()
        alphaValue = enabled ? 1 : 0.5
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func makeContent() -> NSView {
        let icon = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(icon)
        return GlassContent(icon: image, tint: enabled ? .white : DS.Color.textSecondary, disc: disc)
    }

    private func buildGlass() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = disc / 2
            glass.style = .regular
            glass.contentView = makeContent()
            glassView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = disc / 2
            blur.layer?.masksToBounds = true
            let content = makeContent()
            content.frame = CGRect(x: 0, y: 0, width: disc, height: disc)
            content.autoresizingMask = [.width, .height]
            blur.addSubview(content)
            glassView = blur
        }
        glassContainer.addSubview(glassView)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: disc, height: disc) }
    var measuredWidth: CGFloat { disc }

    override func layout() {
        super.layout()
        glassContainer.frame = CGRect(x: (bounds.width - disc) / 2,
                                      y: (bounds.height - disc) / 2, width: disc, height: disc)
        glassView.frame = glassContainer.bounds
    }

    // MARK: - Interaction

    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func mouseDown(with event: NSEvent) { if enabled { onClick?() } }

    private func setHovered(_ on: Bool) {
        guard enabled, hovered != on else { return }
        hovered = on
        if let layer = glassContainer.layer {
            let transform = Motion.scaleAboutCenter(on ? 1.12 : 1.0, in: CGSize(width: disc, height: disc))
            // A springy lift with a hint of overshoot — lively but smooth.
            Motion.spring(layer, keyPath: "transform", to: NSValue(caTransform3D: transform),
                          response: 0.36, dampingRatio: 0.7)
        }
    }
}

/// The glass disc's content: the SF Symbol icon plus a subtle **rim highlight** (bright at the top,
/// fading down the edge) so the Liquid Glass reads as glass even on a flat black canvas, where it
/// otherwise has nothing behind it to refract.
private final class GlassContent: NSView {
    private let iconView = NSImageView()

    init(icon: NSImage?, tint: NSColor, disc: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: disc, height: disc))
        wantsLayer = true
        iconView.image = icon
        iconView.contentTintColor = tint
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        iconView.frame = bounds
        iconView.autoresizingMask = [.width, .height]
        addSubview(iconView)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        let cs = CGColorSpaceCreateDeviceRGB()
        let ring = CGMutablePath()
        ring.addEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
        ring.addEllipse(in: r.insetBy(dx: 2.0, dy: 2.0))
        ctx.saveGState()
        ctx.addPath(ring); ctx.clip(using: .evenOdd)   // a 1.5pt-wide rim
        if let g = CGGradient(colorsSpace: cs,
                              colors: [CGColor(colorSpace: cs, components: [1, 1, 1, 0.55])!,
                                       CGColor(colorSpace: cs, components: [1, 1, 1, 0.06])!] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY),
                                   end: CGPoint(x: r.midX, y: r.minY), options: [])
        }
        ctx.restoreGState()
    }
}
