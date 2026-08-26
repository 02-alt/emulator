import AppKit
import LibraryKit

/// A themed, in-window overlay that shows a game's PlayStation **memory card** — its saves rendered
/// as the keepsake they are, on a hand-drawn grey PS1 card whose label wears the game's cover art.
/// Follows the same dim-backdrop pattern as ``AppAlert``.
@MainActor
final class MemoryCardView: NSView {

    @discardableResult
    static func present(in window: NSWindow?, gameTitle: String, cover: NSImage?,
                        card: PSXMemoryCard.Card) -> Bool {
        guard let host = window?.contentView else { return false }
        let view = MemoryCardView(gameTitle: gameTitle, cover: cover, card: card)
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        view.layer?.zPosition = 1000
        view.animateIn()
        window?.makeFirstResponder(view)
        return true
    }

    private let dim = CALayer()
    private let panel = NSView()
    private let art: CardArtView
    private let card: PSXMemoryCard.Card

    private init(gameTitle: String, cover: NSImage?, card: PSXMemoryCard.Card) {
        self.card = card
        self.art = CardArtView(cover: cover, blocksUsed: card.blocksUsed)
        super.init(frame: .zero)
        wantsLayer = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.addSublayer(dim)

        panel.wantsLayer = true
        panel.layer?.backgroundColor = DS.Color.background.cgColor
        panel.layer?.cornerRadius = DS.Radius.card
        panel.layer?.borderColor = DS.Color.hairlineStrong.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.5
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DS.Space.sm
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)

        let heading = NSTextField(labelWithAttributedString: DS.Text.title("Memory Card", size: 20))
        column.addArrangedSubview(heading)
        let sub = NSTextField(labelWithAttributedString: DS.Text.label(gameTitle, size: 11, color: DS.Color.textSecondary))
        column.addArrangedSubview(sub)
        column.setCustomSpacing(DS.Space.md, after: sub)

        // The hero: the drawn card.
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 340).isActive = true
        art.heightAnchor.constraint(equalToConstant: 214).isActive = true
        column.addArrangedSubview(art)
        column.setCustomSpacing(DS.Space.md, after: art)

        // Block usage.
        let usage = card.isEmpty
            ? "New card · \(PSXMemoryCard.blockCount) blocks free"
            : "\(card.blocksUsed) of \(PSXMemoryCard.blockCount) blocks used"
        let usageField = NSTextField(labelWithAttributedString: DS.Text.label(usage, size: 12))
        column.addArrangedSubview(usageField)
        column.addArrangedSubview(BlockBarView(used: card.blocksUsed))
        column.setCustomSpacing(DS.Space.md, after: column.arrangedSubviews.last!)

        // Saves list (or an empty-state line).
        if card.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "")
            empty.attributedStringValue = DS.Text.plain(
                "No saves yet. Save inside the game and they’ll appear here.",
                size: 12, color: DS.Color.textSecondary)
            empty.preferredMaxLayoutWidth = 340
            column.addArrangedSubview(empty)
        } else {
            for save in card.saves {
                column.addArrangedSubview(saveRow(save))
            }
        }

        let button = AlertButton(title: "Done", kind: .primary) { [weak self] in self?.dismiss() }
        panel.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 396),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: DS.Space.lg),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: DS.Space.lg),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -DS.Space.lg),
            button.topAnchor.constraint(equalTo: column.bottomAnchor, constant: DS.Space.lg),
            button.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -DS.Space.lg),
            button.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -DS.Space.lg),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func saveRow(_ save: PSXSave) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DS.Space.sm

        // The save's own 16×16 icon, scaled up crisp (nearest-neighbor) — the picture the PS1 shows.
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = save.icon.flatMap { Self.pixelImage($0, side: 16) }
        iconView.wantsLayer = true
        iconView.layer?.magnificationFilter = .nearest
        iconView.layer?.cornerRadius = 2
        iconView.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        iconView.layer?.borderWidth = save.icon == nil ? 0 : 1
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let title = NSTextField(labelWithAttributedString: DS.Text.plain(save.title, size: 13))
        let meta = "\(save.blocks) block\(save.blocks == 1 ? "" : "s")" + (save.region.map { " · \($0)" } ?? "")
        let metaField = NSTextField(labelWithAttributedString: DS.Text.label(meta, size: 10, color: DS.Color.textSecondary))
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())   // spacer
        row.addArrangedSubview(metaField)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return row
    }

    /// Build an NSImage from `side`×`side` RGBA8888 pixels (memory order R,G,B,A), unfiltered.
    static func pixelImage(_ px: [UInt32], side: Int) -> NSImage? {
        let bytes = px.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    override func layout() { super.layout(); dim.frame = bounds }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}   // modal backdrop
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    private func animateIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.quick; ctx.timingFunction = Motion.timing
            animator().alphaValue = 1
        }
    }
    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.quick; ctx.timingFunction = Motion.timing
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}

// MARK: - The drawn card

/// A hand-drawn original grey PlayStation memory card: a landscape body with a recessed label (the
/// game's cover art), a ridged thumb grip, and the connector edge.
private final class CardArtView: NSView {
    private let cover: NSImage?
    private let blocksUsed: Int
    init(cover: NSImage?, blocksUsed: Int) {
        self.cover = cover; self.blocksUsed = blocksUsed
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Fit a 1.45:1 card centered in the view.
        let aspect: CGFloat = 1.45
        var w = bounds.width, h = w / aspect
        if h > bounds.height { h = bounds.height; w = h * aspect }
        let card = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        let r = h * 0.10

        // Body — light grey plastic with a soft top-lit gradient and a hairline edge.
        let body = NSBezierPath(roundedRect: card, xRadius: r, yRadius: r)
        ctx.saveGState(); body.addClip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 0.72, alpha: 1).cgColor,
                                       NSColor(white: 0.55, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: card.midX, y: card.minY),
                               end: CGPoint(x: card.midX, y: card.maxY), options: [])
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.22).setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        edge.lineWidth = 1; edge.stroke()

        // Connector edge — a darker band down the right short side with vertical contact lines.
        let connW = w * 0.12
        let conn = CGRect(x: card.maxX - connW, y: card.minY, width: connW, height: h)
        ctx.saveGState()
        NSBezierPath(roundedRect: card, xRadius: r, yRadius: r).addClip()
        NSColor(white: 0.30, alpha: 1).setFill(); NSBezierPath(rect: conn).fill()
        NSColor(white: 0.5, alpha: 1).setStroke()
        let lines = NSBezierPath()
        for k in 0..<5 {
            let x = conn.minX + connW * (0.22 + 0.14 * CGFloat(k))
            lines.move(to: CGPoint(x: x, y: conn.minY + h * 0.2))
            lines.line(to: CGPoint(x: x, y: conn.maxY - h * 0.2))
        }
        lines.lineWidth = 1; lines.stroke()
        ctx.restoreGState()

        // Thumb grip — a few ridges on the far left edge.
        NSColor(white: 0.42, alpha: 0.9).setStroke()
        let grip = NSBezierPath()
        for k in 0..<4 {
            let x = card.minX + w * (0.03 + 0.018 * CGFloat(k))
            grip.move(to: CGPoint(x: x, y: card.minY + h * 0.22))
            grip.line(to: CGPoint(x: x, y: card.maxY - h * 0.22))
        }
        grip.lineWidth = 1.5; grip.lineCapStyle = .round; grip.stroke()

        // Recessed label — the game's cover art (the keepsake face), inset between grip and connector.
        let label = CGRect(x: card.minX + w * 0.10, y: card.minY + h * 0.12,
                           width: w * 0.76, height: h * 0.76)
        let labelPath = NSBezierPath(roundedRect: label, xRadius: r * 0.6, yRadius: r * 0.6)
        NSColor(white: 0.14, alpha: 1).setFill(); labelPath.fill()
        ctx.saveGState(); labelPath.addClip()
        if let cover {
            cover.draw(in: CartridgeTileView.aspectFill(cover.size, in: label),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            // Empty label: the "PS" wordmark, embossed.
            let s = DS.Text.label("PS", size: h * 0.34, color: NSColor(white: 1, alpha: 0.22), alignment: .center)
            let sz = s.size()
            s.draw(at: CGPoint(x: label.midX - sz.width / 2, y: label.midY - sz.height / 2))
        }
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.10).setStroke()
        let lb = NSBezierPath(roundedRect: label, xRadius: r * 0.6, yRadius: r * 0.6)
        lb.lineWidth = 1; lb.stroke()
    }
}

// MARK: - Block usage bar

/// A 15-segment strip showing how full the card is (used segments lit, free segments hairline).
private final class BlockBarView: NSView {
    private let used: Int
    init(used: Int) { self.used = used; super.init(frame: .zero); wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 340).isActive = true
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let n = PSXMemoryCard.blockCount
        let gap: CGFloat = 3
        let segW = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let rect = CGRect(x: CGFloat(i) * (segW + gap), y: 0, width: segW, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if i < used { DS.Color.textPrimary.setFill(); path.fill() }
            else { NSColor(white: 1, alpha: 0.14).setStroke(); path.lineWidth = 1; path.stroke() }
        }
    }
}
