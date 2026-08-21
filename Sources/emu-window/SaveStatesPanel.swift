import AppKit

/// One save-state slot's info for the browser.
struct SaveSlot {
    let index: Int
    let date: Date?
    let thumbnail: NSImage?
    var isEmpty: Bool { date == nil }
}

/// The in-game **Save States** browser — a themed popover listing numbered slots, each with a frame
/// thumbnail, timestamp, and Save / Load / Delete. Mirrors the ambience popover's look. The play view
/// supplies the slot data + actions; any action refreshes the list in place.
@MainActor
final class SaveStatesPanelView: NSView {
    var onSave: ((Int) -> Void)?
    var onLoad: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    /// Fetch the current slot list (called on build + after every action).
    var slotsProvider: (() -> [SaveSlot])?

    private let stack = NSStackView()
    private let rowH: CGFloat = 54
    private let pad: CGFloat = 12

    init(count: Int) {
        let width: CGFloat = 340
        let height = pad + 16 + 8 + CGFloat(count) * (rowH + 6) + pad
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad + 16 + 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DS.Text.label("Save States", size: 11, color: NSColor(white: 1, alpha: 0.55))
            .draw(at: CGPoint(x: pad + 8, y: pad))
    }

    /// (Re)build the rows from the current slot data — call once the callbacks are wired.
    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for slot in slotsProvider?() ?? [] {
            let row = SlotRow(slot: slot)
            row.onSave = { [weak self] in self?.onSave?(slot.index); self?.reload() }
            row.onLoad = { [weak self] in self?.onLoad?(slot.index) }
            row.onDelete = { [weak self] in self?.onDelete?(slot.index); self?.reload() }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: rowH).isActive = true
            row.widthAnchor.constraint(equalToConstant: frame.width - pad * 2).isActive = true
            stack.addArrangedSubview(row)
        }
    }
}

/// One slot row: thumbnail · "Slot N" + date (or "Empty") · Save / Load / Delete.
private final class SlotRow: NSView {
    var onSave: (() -> Void)?
    var onLoad: (() -> Void)?
    var onDelete: (() -> Void)?
    private let slot: SaveSlot

    init(slot: SaveSlot) {
        self.slot = slot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        build()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    override var isFlipped: Bool { true }

    private func build() {
        // Thumbnail (3:2), or a placeholder for an empty slot.
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.image = slot.thumbnail
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)

        let title = NSTextField(labelWithAttributedString: DS.Text.label("Slot \(slot.index)", size: 13))
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let subtitle = NSTextField(labelWithAttributedString:
            DS.Text.plain(slot.isEmpty ? "Empty" : Self.stamp(slot.date), size: 11,
                          color: slot.isEmpty ? DS.Color.textTertiary : DS.Color.textSecondary))
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        let save = TinyButton(title: "Save") { [weak self] in self?.onSave?() }
        let load = TinyButton(title: "Load", enabled: !slot.isEmpty) { [weak self] in self?.onLoad?() }
        let del = TinyButton(symbol: "trash", enabled: !slot.isEmpty, destructive: true) { [weak self] in self?.onDelete?() }
        let actions = NSStackView(views: [save, load, del])
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 60),
            thumb.heightAnchor.constraint(equalToConstant: 40),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -1),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
}

/// A compact text/symbol button for a slot row (pixel label; dim when disabled; red when destructive).
private final class TinyButton: NSView {
    private let onClick: () -> Void
    private let enabled: Bool
    private let destructive: Bool
    private let title: String?
    private let symbol: String?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String? = nil, symbol: String? = nil, enabled: Bool = true,
         destructive: Bool = false, onClick: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.enabled = enabled
        self.destructive = destructive; self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.chip
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if let title { return NSSize(width: DS.Text.label(title, size: 12).size().width + 16, height: 26) }
        return NSSize(width: 30, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                               xRadius: DS.Radius.chip, yRadius: DS.Radius.chip)
        let tint: NSColor = destructive ? .systemRed : DS.Color.hairlineStrong
        if hovered && enabled { tint.withAlphaComponent(destructive ? 0.9 : 1).setFill(); box.fill() }
        tint.withAlphaComponent(enabled ? 0.6 : 0.2).setStroke(); box.lineWidth = 1; box.stroke()
        let fg: NSColor = (hovered && enabled) ? (destructive ? .white : DS.Color.background)
            : (enabled ? DS.Color.textPrimary : DS.Color.textTertiary)
        if let title {
            let s = DS.Text.label(title, size: 12, color: fg)
            let sz = s.size(); s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        } else if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            let tinted = img.withSymbolConfiguration(cfg)
            NSGraphicsContext.saveGraphicsState()
            fg.set()
            let r = CGRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
            tinted?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
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
    override func mouseUp(with event: NSEvent) { if enabled { onClick() } }
}
