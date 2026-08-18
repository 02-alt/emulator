import AppKit
import EmulatorCore

/// A single clickable on-screen control in the play window's footer. Two kinds:
/// - `.hold(button)` — a GBA button that presses on mouse-down and releases on mouse-up (so it can
///   be held), reported via `onPress`/`onRelease`.
/// - `.action(run)` — a one-shot action (e.g. Save/Load) that fires on click.
final class ControlButton: NSView {
    enum Kind { case hold(GBAButtons); case action(() -> Void) }

    private let title: String
    private let kind: Kind
    var onPress: ((GBAButtons) -> Void)?
    var onRelease: ((GBAButtons) -> Void)?

    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ title: String, _ kind: Kind) {
        self.title = title
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.plain(title, size: 12).size().width + 18, height: 26)
    }
    var measuredWidth: CGFloat { intrinsicContentSize.width }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        switch kind {
        case let .hold(button): onPress?(button)
        case let .action(run): run()
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false; needsDisplay = true
        if case let .hold(button) = kind { onRelease?(button) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: DS.Radius.chip, yRadius: DS.Radius.chip)
        if pressed {
            DS.Color.textPrimary.setFill(); chip.fill()
        } else {
            DS.Color.surface.setFill(); chip.fill()
            DS.Color.hairline.setStroke(); chip.lineWidth = 1; chip.stroke()
        }
        let label = DS.Text.plain(title, size: 12,
                                  color: pressed ? DS.Color.background : DS.Color.textSecondary)
        label.draw(at: CGPoint(x: bounds.midX - label.size().width / 2,
                               y: bounds.midY - label.size().height / 2))
    }
}
