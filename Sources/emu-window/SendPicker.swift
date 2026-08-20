import AppKit
import LibraryKit

/// A themed multi-select picker for sending several games to the user's other devices at once — the
/// batch companion to a cartridge's single "Send to My Devices" right-click. Presented as an in-window
/// overlay (like ``AppAlert``, so it's full-screen-safe): a checklist of the library, an optional
/// device target, and a **Send** that offers every checked game through the same private-iCloud
/// transfer. **Return** sends, **Esc** cancels.
@MainActor
final class SendPicker: NSView {
    /// Present the picker over `window`, with `preselect` already checked. `targets` are the user's
    /// other devices (empty → a plain broadcast). `onSend` receives the chosen games and target
    /// (nil = all devices); it isn't called on cancel.
    @discardableResult
    static func present(in window: NSWindow?,
                        games: [Game],
                        preselect: Game,
                        targets: [String],
                        onSend: @escaping ([Game], String?) -> Void) -> Bool {
        guard let host = window?.contentView, !games.isEmpty else { return false }
        let picker = SendPicker(games: games, preselect: preselect, targets: targets, onSend: onSend)
        picker.frame = host.bounds
        picker.autoresizingMask = [.width, .height]
        host.addSubview(picker)
        picker.layer?.zPosition = 1000   // above the carousel's raised hero cart
        picker.animateIn()
        window?.makeFirstResponder(picker)
        return true
    }

    private let games: [Game]
    private let targets: [String]
    private let onSend: ([Game], String?) -> Void

    private let dim = CALayer()
    private let card = NSView()
    private var selected: Set<UUID>
    private var target: String?                 // nil = all devices
    private var rows: [SendRow] = []
    private var chips: [TargetChip] = []
    private let sendButton: PickerButton
    private let selectAllButton: PickerButton
    private let countLabel = NSTextField(labelWithString: "")

    private init(games: [Game], preselect: Game, targets: [String], onSend: @escaping ([Game], String?) -> Void) {
        self.games = games
        self.targets = targets
        self.onSend = onSend
        self.selected = [preselect.id]
        self.sendButton = PickerButton(title: "Send", kind: .primary, onClick: {})
        self.selectAllButton = PickerButton(title: "Select All", kind: .plain, onClick: {})
        super.init(frame: .zero)
        wantsLayer = true
        build()
        refreshState()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func build() {
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
        column.distribution = .fill        // lets the checklist stretch to fill the card's height
        column.spacing = DS.Space.smd
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        if let img = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil) {
            let icon = NSImageView(image: img)
            icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            icon.contentTintColor = DS.Color.textPrimary
            column.addArrangedSubview(icon)
            column.setCustomSpacing(DS.Space.md, after: icon)
        }

        let title = NSTextField(labelWithAttributedString: NSAttributedString(string: "Send to My Devices", attributes: [
            .font: DS.pixel(20), .foregroundColor: DS.Color.textPrimary]))
        column.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "")
        subtitle.attributedStringValue = DS.Text.plain(
            "Choose the games to copy to your other devices through your own private iCloud — never our servers.",
            size: 13, color: DS.Color.textSecondary)
        subtitle.isSelectable = false
        subtitle.preferredMaxLayoutWidth = 396
        column.addArrangedSubview(subtitle)
        column.setCustomSpacing(DS.Space.md, after: subtitle)

        // The scrollable checklist.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        for game in games {
            let row = SendRow(game: game, checked: selected.contains(game.id)) { [weak self] in
                self?.toggle(game)
            }
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let doc = FlippedContainer()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        column.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // Optional device target row — single-select chips, "All Devices" first.
        if !targets.isEmpty {
            let chipRow = NSStackView()
            chipRow.orientation = .horizontal
            chipRow.spacing = DS.Space.sm
            let all = TargetChip(title: "All Devices", device: nil) { [weak self] d in self?.selectTarget(d) }
            chips.append(all)
            chipRow.addArrangedSubview(all)
            for device in targets {
                let chip = TargetChip(title: device, device: device) { [weak self] d in self?.selectTarget(d) }
                chips.append(chip)
                chipRow.addArrangedSubview(chip)
            }
            column.setCustomSpacing(DS.Space.md, after: scroll)
            column.addArrangedSubview(chipRow)
        }

        // Footer: selection count on the left, Select All / Cancel / Send on the right.
        countLabel.attributedStringValue = DS.Text.label("", size: 12, color: DS.Color.textSecondary)
        selectAllButton.onClick = { [weak self] in self?.toggleSelectAll() }
        sendButton.onClick = { [weak self] in self?.commit() }
        let cancel = PickerButton(title: "Cancel", kind: .normal) { [weak self] in self?.dismiss(then: nil) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [countLabel, spacer, selectAllButton, cancel, sendButton])
        footer.orientation = .horizontal
        footer.spacing = DS.Space.sm
        footer.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(DS.Space.md, after: column.arrangedSubviews.last!)
        column.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // Card sizing: fixed width, height flexes with the list but is capped to the window.
        let inset = DS.Space.lg
        let preferred = card.heightAnchor.constraint(equalToConstant: 520)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 440),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -64),
            preferred,
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - Selection

    private func toggle(_ game: Game) {
        if selected.contains(game.id) { selected.remove(game.id) } else { selected.insert(game.id) }
        rows.first { $0.gameID == game.id }?.setChecked(selected.contains(game.id))
        refreshState()
    }

    private func toggleSelectAll() {
        if selected.count == games.count { selected.removeAll() }
        else { selected = Set(games.map(\.id)) }
        for row in rows { row.setChecked(selected.contains(row.gameID)) }
        refreshState()
    }

    private func selectTarget(_ device: String?) {
        target = device
        for chip in chips { chip.setSelected(chip.device == device) }
    }

    private func refreshState() {
        let n = selected.count
        countLabel.attributedStringValue = DS.Text.label(
            n == 0 ? "None selected" : "\(n) selected", size: 12, color: DS.Color.textSecondary)
        selectAllButton.setTitle(n == games.count ? "Deselect All" : "Select All")
        sendButton.setEnabled(n > 0)
    }

    private func commit() {
        guard !selected.isEmpty else { return }
        let chosen = games.filter { selected.contains($0.id) }
        let pick = target
        dismiss { [weak self] in self?.onSend(chosen, pick) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss(then: nil)                   // Esc
        case 36, 76: commit()                         // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Animation

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
        pendingCompletion = handler
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.quick
            ctx.timingFunction = Motion.timing
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeFromSuperview()
                let done = self.pendingCompletion
                self.pendingCompletion = nil
                done?()
            }
        })
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
    }
}

/// A flipped container so the checklist stack lays out top-down inside the scroll view.
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// One selectable row in the send checklist: a checkbox, the cartridge's cover, and its title. Clicking
/// anywhere on the row toggles it.
@MainActor
private final class SendRow: NSView {
    let gameID: UUID
    private let onToggle: () -> Void
    private var checked: Bool
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let check = NSImageView()

    init(game: Game, checked: Bool, onToggle: @escaping () -> Void) {
        self.gameID = game.id
        self.checked = checked
        self.onToggle = onToggle
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        check.contentTintColor = DS.Color.background
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = !checked
        addSubview(check)

        let cover = NSImageView()
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.translatesAutoresizingMaskIntoConstraints = false
        if let url = game.coverURL, let image = NSImage(contentsOf: url) {
            cover.image = image
        } else {
            cover.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
            cover.contentTintColor = DS.Color.textTertiary
        }
        addSubview(cover)

        let title = NSTextField(labelWithAttributedString:
            DS.Text.plain(game.displayTitle, size: 14, color: DS.Color.textPrimary))
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.smd),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18),
            cover.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: DS.Space.smd),
            cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 28),
            cover.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: DS.Space.smd),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Space.smd),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }

    func setChecked(_ on: Bool) {
        checked = on
        check.isHidden = !on
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            DS.Color.surface.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: DS.Space.xs, dy: 2),
                         xRadius: DS.Radius.small, yRadius: DS.Radius.small).fill()
        }
        // Checkbox: a hairline square, filled white when checked (the checkmark image sits on top).
        let box = NSRect(x: DS.Space.smd, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let path = NSBezierPath(roundedRect: box, xRadius: DS.Radius.chip, yRadius: DS.Radius.chip)
        if checked {
            DS.Color.tileSelected.setFill(); path.fill()
        } else {
            DS.Color.hairlineStrong.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onToggle() }
}

/// A single-select device chip for the send target ("All Devices" or one device name).
@MainActor
private final class TargetChip: NSView {
    let device: String?
    private let title: String
    private let onSelect: (String?) -> Void
    private var selected: Bool
    private var tracking: NSTrackingArea?

    init(title: String, device: String?, onSelect: @escaping (String?) -> Void) {
        self.title = title
        self.device = device
        self.onSelect = onSelect
        self.selected = (device == nil)   // "All Devices" is the default
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.label(title, size: 12).size().width + DS.Space.md, height: 26)
    }

    func setSelected(_ on: Bool) { selected = on; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        if selected { DS.Color.tileSelected.setFill(); box.fill() }
        DS.Color.hairlineStrong.setStroke(); box.lineWidth = 1; box.stroke()
        let str = DS.Text.label(title, size: 12, color: selected ? DS.Color.background : DS.Color.textPrimary)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onSelect(device) }
}

/// A pixel button for the picker: filled white **primary** (Send), outlined **normal** (Cancel), and a
/// borderless **plain** (Select All). Matches the app's other pixel controls; dims when disabled.
@MainActor
private final class PickerButton: NSView {
    enum Kind { case primary, normal, plain }

    var onClick: () -> Void
    private var title: String
    private let kind: Kind
    private var hovered = false
    private var enabled = true
    private var tracking: NSTrackingArea?

    init(title: String, kind: Kind, onClick: @escaping () -> Void) {
        self.title = title; self.kind = kind; self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.Text.label(title, size: 13).size().width + (kind == .plain ? DS.Space.sm : DS.Space.lg), height: 34)
    }

    func setTitle(_ text: String) { title = text; invalidateIntrinsicContentSize(); needsDisplay = true }
    func setEnabled(_ on: Bool) { enabled = on; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = DS.Color.tileSelected
        if kind != .plain {
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                   xRadius: DS.Radius.control, yRadius: DS.Radius.control)
            let filled = kind == .primary || hovered
            if filled { accent.withAlphaComponent(enabled ? 1 : 0.4).setFill(); box.fill() }
            accent.withAlphaComponent(enabled ? 1 : 0.4).setStroke(); box.lineWidth = 1.5; box.stroke()
            let textColor: NSColor = filled ? DS.Color.background : DS.Color.textPrimary
            drawTitle(color: textColor.withAlphaComponent(enabled ? 1 : 0.6))
        } else {
            drawTitle(color: (hovered ? DS.Color.textPrimary : DS.Color.textSecondary))
        }
    }

    private func drawTitle(color: NSColor) {
        let str = DS.Text.label(title, size: 13, color: color)
        let size = str.size()
        str.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if enabled { onClick() } }
}
