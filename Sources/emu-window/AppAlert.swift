import AppKit

/// A themed, app-modal alert that matches the Analogue-OS look (pure-black card, pixel type, hairline
/// border) while following Apple's alert conventions: a short **title** stating what happened, an
/// informative **message** (why it happened + what to do), and **verb-labeled buttons** with the
/// default action on the right. It's shown as an in-window overlay that dims the content behind it
/// (full-screen-safe, unlike a child window) — the same overlay pattern the launch cinematic uses.
///
/// Keyboard follows the platform: **Return** runs the default action, **Esc** the cancel action.
/// Clicking the dimmed backdrop does nothing (alerts require a deliberate button press).
@MainActor
final class AppAlert: NSView {
    /// One button. Exactly one action should be `isDefault` (rightmost, Return-triggered); an action
    /// titled to dismiss without consequence should be `isCancel` (Esc-triggered).
    struct Action {
        var title: String
        var isDefault = false
        var isCancel = false
        var isDestructive = false
        var handler: () -> Void = {}
    }

    /// One highlighted change for a "What's new" card: an SF Symbol with a short title and a one-line
    /// detail. Passing a non-empty `features:` list turns the alert into a release-notes card, with the
    /// rows drawn between the message and the buttons.
    struct Feature {
        var symbol: String
        var title: String
        var detail: String
    }

    private let dim = CALayer()
    private let card = NSView()
    private var defaultHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    /// Present the alert over `window`'s content view. No-op (returns false) if there's no window —
    /// callers can fall back to a system `NSAlert` for the windowless case.
    @discardableResult
    static func present(in window: NSWindow?,
                        symbol: String? = "exclamationmark.triangle",
                        title: String,
                        message: String,
                        features: [Feature] = [],
                        actions: [Action] = [Action(title: "OK", isDefault: true)]) -> Bool {
        guard let host = window?.contentView else { return false }
        let alert = AppAlert(symbol: symbol, title: title, message: message, features: features, actions: actions)
        alert.frame = host.bounds
        alert.autoresizingMask = [.width, .height]
        host.addSubview(alert)
        // Float above the carousel's hero cart, which lifts itself with a raised layer zPosition
        // (CoverView) — subview order alone wouldn't keep the modal on top of it.
        alert.layer?.zPosition = 1000
        alert.animateIn()
        window?.makeFirstResponder(alert)
        return true
    }

    private init(symbol: String?, title: String, message: String, features: [Feature], actions: [Action]) {
        super.init(frame: .zero)
        wantsLayer = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        dim.frame = bounds
        layer?.addSublayer(dim)

        card.wantsLayer = true
        card.layer?.backgroundColor = DS.Color.background.cgColor
        card.layer?.cornerRadius = DS.Radius.card
        card.layer?.borderColor = DS.Color.hairlineStrong.cgColor
        card.layer?.borderWidth = 1
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Space.sm
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let icon = NSImageView(image: img)
            icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            icon.contentTintColor = DS.Color.textPrimary
            column.addArrangedSubview(icon)
            column.setCustomSpacing(DS.Space.md, after: icon)
        }

        // The pixel title, wrapping — DS.Text.title truncates by design (it's for the big game name),
        // so build a word-wrapping variant here so a longer alert title spills to a second line.
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byWordWrapping
        let titleField = NSTextField(wrappingLabelWithString: "")
        titleField.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: DS.pixel(20),
            .foregroundColor: DS.Color.textPrimary,
            .paragraphStyle: titleStyle,
        ])
        titleField.isSelectable = false
        titleField.preferredMaxLayoutWidth = 332
        column.addArrangedSubview(titleField)

        let messageField = NSTextField(wrappingLabelWithString: "")
        messageField.attributedStringValue = DS.Text.plain(message, size: 13, color: DS.Color.textSecondary)
        messageField.isSelectable = true
        messageField.preferredMaxLayoutWidth = 340
        column.addArrangedSubview(messageField)

        // "What's new" rows, when present: an SF Symbol beside a title + one-line detail, stacked under
        // the message. The button row gets a little breathing room below them (normal alerts keep their
        // tight, message-hugging layout).
        var lastInColumn: NSView = messageField
        if !features.isEmpty {
            column.setCustomSpacing(DS.Space.lg, after: messageField)
            for feature in features {
                let row = AppAlert.featureRow(feature)
                column.addArrangedSubview(row)
                column.setCustomSpacing(DS.Space.md, after: row)
                lastInColumn = row
            }
        }
        column.setCustomSpacing(DS.Space.lg, after: lastInColumn)

        // Buttons, laid out trailing with the default action on the right (platform convention).
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = DS.Space.sm
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for action in actions {
            if action.isDefault { defaultHandler = action.handler }
            if action.isCancel { cancelHandler = action.handler }
            let kind: AlertButton.Kind = action.isDestructive ? .destructive
                : action.isDefault ? .primary : .normal
            let button = AlertButton(title: action.title, kind: kind) { [weak self] in
                self?.dismiss(then: action.handler)
            }
            buttons.addArrangedSubview(button)
        }
        // If nothing was flagged cancel, Esc falls back to the default (single-button alerts).
        if cancelHandler == nil { cancelHandler = defaultHandler }
        card.addSubview(buttons)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 380),

            column.topAnchor.constraint(equalTo: card.topAnchor, constant: DS.Space.lg),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DS.Space.lg),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DS.Space.lg),

            buttons.topAnchor.constraint(equalTo: column.bottomAnchor, constant: features.isEmpty ? 0 : DS.Space.lg),
            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DS.Space.lg),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DS.Space.lg),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        dim.frame = bounds
    }

    /// A single "What's new" row: the SF Symbol on the left, a pixel title above a dim one-line detail.
    private static func featureRow(_ feature: Feature) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = DS.Space.md
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: feature.symbol, accessibilityDescription: feature.title) {
            icon.image = img
        }
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = DS.Color.textPrimary
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        row.addArrangedSubview(icon)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = DS.Space.xs

        let titleField = NSTextField(labelWithAttributedString:
            DS.Text.plain(feature.title, size: 14, color: DS.Color.textPrimary))
        titleField.isSelectable = false

        let detailField = NSTextField(wrappingLabelWithString: "")
        detailField.attributedStringValue = DS.Text.plain(feature.detail, size: 12, color: DS.Color.textSecondary)
        detailField.isSelectable = false
        detailField.preferredMaxLayoutWidth = 288

        text.addArrangedSubview(titleField)
        text.addArrangedSubview(detailField)
        row.addArrangedSubview(text)

        return row
    }

    // Modal: swallow every click that isn't on a button (the backdrop must not fall through to the
    // content beneath, and tapping outside the card must not dismiss the alert).
    override func mouseDown(with event: NSEvent) {}

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: dismiss(then: defaultHandler)   // Return / Enter → default
        case 53:     dismiss(then: cancelHandler)     // Esc → cancel
        default:     super.keyDown(with: event)
        }
    }

    private func animateIn() {
        alphaValue = 0
        card.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }
        let pop = Motion.springAnimation("transform",
                                         from: NSValue(caTransform3D: CATransform3DMakeScale(0.96, 0.96, 1)),
                                         to: NSValue(caTransform3D: CATransform3DIdentity),
                                         response: 0.4, dampingRatio: 0.82)
        card.layer?.add(pop, forKey: "transform")
        card.layer?.transform = CATransform3DIdentity
    }

    private var pendingCompletion: (() -> Void)?
    private func dismiss(then handler: (() -> Void)?) {
        pendingCompletion = handler   // held on self so the @Sendable completion needn't capture it
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {   // runAnimationGroup's completion fires on the main thread
                guard let self else { return }
                self.removeFromSuperview()
                let done = self.pendingCompletion
                self.pendingCompletion = nil
                done?()
            }
        })
    }
}

/// A pixel button styled for the themed alert: a filled white **primary** (the default action), an
/// outlined **normal**, and a red **destructive**. Matches the app's other pixel controls.
@MainActor
private final class AlertButton: NSView {
    enum Kind { case primary, normal, destructive }

    private let onClick: () -> Void
    private let title: String
    private let kind: Kind
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, kind: Kind, onClick: @escaping () -> Void) {
        self.title = title; self.kind = kind; self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.label(title, size: 13).size().width + DS.Space.lg, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        let accent: NSColor = kind == .destructive ? .systemRed : DS.Color.tileSelected
        let filled = kind == .primary || kind == .destructive || hovered
        if filled { accent.setFill(); box.fill() }
        accent.setStroke(); box.lineWidth = 1.5; box.stroke()
        let textColor: NSColor = filled
            ? (kind == .destructive ? .white : DS.Color.background)
            : DS.Color.textPrimary
        let str = DS.Text.label(title, size: 13, color: textColor)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
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
