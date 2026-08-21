import AppKit

/// The in-game Settings surface: a dark scrim over the running game plus a bordered panel that hosts
/// the shared ``SettingsView`` — so tuning settings mid-game happens **inside the play window**
/// instead of spawning a separate window. Dismiss by clicking the scrim, hitting the ✕, or Esc / ⌘,.
@MainActor
final class SettingsOverlayView: NSView {
    /// Called when the overlay is dismissed (RA fields are already committed by then).
    var onClose: (() -> Void)?

    /// Forwarded to the embedded ``SettingsView`` so a login can refresh achievements elsewhere.
    var onCredentialsSaved: (() -> Void)? {
        get { settings.onCredentialsSaved }
        set { settings.onCredentialsSaved = newValue }
    }

    private let panel = NSView()
    private let settings = SettingsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = DS.Color.background.cgColor
        panel.layer?.cornerRadius = DS.Radius.tile
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = DS.Color.hairlineStrong.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // Header: uppercase title on the left, a hairline ✕ on the right.
        let titleLabel = NSTextField(labelWithAttributedString:
            DS.Text.label("Settings", size: 15, color: DS.Color.textPrimary))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(titleLabel)

        let close = OverlayCloseButton { [weak self] in self?.dismiss() }
        close.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(close)

        settings.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(settings)

        // Prefer the window's natural settings size, but never overflow a small play window.
        let w = panel.widthAnchor.constraint(equalToConstant: 720); w.priority = .defaultHigh
        let h = panel.heightAnchor.constraint(equalToConstant: 540); h.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            w, h,
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -DS.Space.md * 2),
            panel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -DS.Space.md * 2),

            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: DS.Space.md),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: DS.Space.lg),

            close.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -DS.Space.md),

            settings.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DS.Space.sm),
            settings.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            settings.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Persist edited fields and tear the overlay down (via ``onClose``).
    func dismiss() {
        settings.commit()
        onClose?()
    }

    // Clicking the scrim (anywhere outside the panel) closes; clicks inside the panel hit its
    // controls, not this view.
    override func mouseDown(with event: NSEvent) { dismiss() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss(); return }                       // Esc
        if event.modifierFlags.contains(.command), event.keyCode == 43 {   // ⌘, toggles closed
            dismiss(); return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Close button

/// A small hairline ✕ that fills on hover — the panel's dismiss affordance, in the app's flat
/// monochrome language.
private final class OverlayCloseButton: NSView {
    private let onClick: () -> Void
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let side: CGFloat = 26

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        if hovered { DS.Color.tileSelected.setFill(); box.fill() }
        DS.Color.hairlineStrong.setStroke(); box.lineWidth = 1.5; box.stroke()

        let ink = hovered ? DS.Color.background : DS.Color.textPrimary
        ink.setStroke()
        let inset: CGFloat = 8
        let x = NSBezierPath()
        x.move(to: CGPoint(x: inset, y: inset))
        x.line(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        x.move(to: CGPoint(x: bounds.width - inset, y: inset))
        x.line(to: CGPoint(x: inset, y: bounds.height - inset))
        x.lineWidth = 1.5
        x.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick() }
}
