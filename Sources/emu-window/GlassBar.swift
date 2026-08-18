import AppKit

/// A single floating **glass bar** of icon actions — modeled on Apple Music's playback capsule —
/// used instead of separate glass discs. One flat Liquid-Glass body (`NSGlassEffectView` on macOS
/// 26, `NSVisualEffectView` blur fallback) rounded to a stadium, holding a row of monochrome SF
/// Symbol buttons that light up on hover. Groups the footer actions into one object so the bottom
/// bar reads as a deliberate control surface rather than loose buttons.
final class GlassBar: NSView {
    /// One action in the bar.
    struct Item {
        let symbol: String
        let tooltip: String
        var enabled: Bool = true
        let onClick: () -> Void
    }

    private let barH: CGFloat = 48
    private let pad: CGFloat = 8      // inset from the capsule's rounded ends
    private let itemW: CGFloat = 46   // per-icon hit target

    private var glassView: NSView!
    private let content = NSView()
    private var buttons: [BarButton] = []

    var measuredWidth: CGFloat { pad * 2 + itemW * CGFloat(max(buttons.count, 1)) }
    var measuredHeight: CGFloat { barH }

    init(items: [Item]) {
        super.init(frame: .zero)
        wantsLayer = true
        content.wantsLayer = true
        buildGlass()
        buttons = items.map { BarButton(item: $0, disc: itemW) }
        buttons.forEach { content.addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func buildGlass() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = barH / 2
            glass.style = .regular
            glass.contentView = content
            glassView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = barH / 2
            blur.layer?.masksToBounds = true
            content.autoresizingMask = [.width, .height]
            blur.addSubview(content)
            glassView = blur
        }
        addSubview(glassView)
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        content.frame = bounds
        // Center the icon row inside the capsule.
        var x = pad
        let y = (bounds.height - itemW) / 2
        for b in buttons {
            b.frame = CGRect(x: x, y: y, width: itemW, height: itemW)
            x += itemW
        }
    }
}

/// One icon inside a ``GlassBar``: a centered SF Symbol with a subtle rounded hover highlight (like
/// the hover state of a macOS toolbar control), a pointing-hand cursor, and a tooltip. Dimmed and
/// inert when disabled.
private final class BarButton: NSView {
    private let item: GlassBar.Item
    private let iconView = NSImageView()
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(item: GlassBar.Item, disc: CGFloat) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = item.tooltip
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = item.enabled ? .white : DS.Color.textSecondary
        iconView.imageScaling = .scaleNone
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)
        alphaValue = item.enabled ? 1 : 0.5
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        iconView.frame = bounds
    }

    /// Hover highlight, drawn behind the icon (the icon is a subview, so it paints on top).
    override func draw(_ dirtyRect: NSRect) {
        guard hovered, item.enabled else { return }
        let r = bounds.insetBy(dx: 4, dy: 4)
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }

    override func resetCursorRects() { if item.enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { if item.enabled { hovered = true; needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if item.enabled { item.onClick() } }
}
