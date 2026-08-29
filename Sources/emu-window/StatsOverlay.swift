import AppKit

/// A compact performance HUD pinned to a corner of the play view (toggled in Settings ▸ Emulation).
/// Draws three pixel-font rows — the emulation frame rate, the % of full speed it represents, and the
/// on-screen draw rate — over a translucent rounded chip. Purely a readout: it holds no timers and
/// runs no work of its own; ``PlaySession`` samples the driver/renderer and pushes values in via
/// ``update(fps:speedPercent:drawRate:)``.
@MainActor
final class StatsBadge: NSView {
    private var fpsText = "—"
    private var speedText = "—"
    private var drawText = "—"
    private var fpsColor = DS.Color.textPrimary

    /// The badge's natural size — read by ``PlayVoidView`` to place it in the chosen corner.
    static let size = NSSize(width: 116, height: 64)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }               // top-down rows
    override var intrinsicContentSize: NSSize { Self.size }
    // Clicks fall through to the game beneath — the HUD is a passive readout.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Push freshly sampled figures in. `fps` is the emulation rate, `speedPercent` its share of full
    /// speed (60 fps = 100%), `drawRate` the rate frames actually reach the screen.
    func update(fps: Double, speedPercent: Int, drawRate: Double) {
        fpsText = String(format: "%.0f", fps.rounded())
        speedText = "\(speedPercent)%"
        drawText = String(format: "%.0f", drawRate.rounded())
        // A glanceable health tint on the headline number: green at full speed, amber when it dips,
        // red when it's struggling.
        fpsColor = fps >= 58 ? Self.good : (fps >= 45 ? Self.warn : Self.bad)
        needsDisplay = true
    }

    private static let good = NSColor.systemGreen
    private static let warn = NSColor.systemYellow
    private static let bad = NSColor.systemRed

    override func draw(_ dirtyRect: NSRect) {
        // Translucent chip so the game reads through it.
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: DS.Radius.panel, yRadius: DS.Radius.panel)
        NSColor.black.withAlphaComponent(0.55).setFill(); chip.fill()
        DS.Color.hairline.setStroke(); chip.lineWidth = 1; chip.stroke()

        let padX: CGFloat = 10
        let rowH: CGFloat = 16
        var y: CGFloat = 8
        drawRow("FPS", fpsText, at: y, padX: padX, valueColor: fpsColor); y += rowH
        drawRow("SPD", speedText, at: y, padX: padX, valueColor: DS.Color.textPrimary); y += rowH
        drawRow("DRAW", drawText, at: y, padX: padX, valueColor: DS.Color.textSecondary)
    }

    /// One "LABEL … value" line: dim label pinned left, value pinned right.
    private func drawRow(_ label: String, _ value: String, at y: CGFloat, padX: CGFloat, valueColor: NSColor) {
        let l = DS.Text.label(label, size: 10, color: DS.Color.textTertiary)
        l.draw(at: CGPoint(x: padX, y: y + 2))
        let v = DS.Text.value(value, size: 12, color: valueColor)
        let vw = v.size().width
        v.draw(at: CGPoint(x: bounds.width - padX - vw, y: y))
    }
}
