import AppKit
import LibraryKit

/// A full-shelf **search overlay**: a search field pinned to the top and every cartridge laid out in
/// a scrollable grid (rows × columns) beneath it, filtered live as you type. Picking a cartridge
/// launches it; Escape (or the ✕ / the search button that opened it) closes the overlay. Same
/// Analogue-OS look as the shelf — pure-black canvas, pixel type, floating glass cartridges.
@MainActor
final class SearchGridView: NSView {
    /// Launch the picked cartridge (the overlay closes first, then the game boots).
    var onLaunch: ((Game) -> Void)?
    /// Dismiss the overlay (Escape / ✕).
    var onClose: (() -> Void)?

    private let allGames: [Game]
    private var filtered: [Game] = []

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = GlassButton(symbol: "xmark", tooltip: "Close Search")
    private let scrollView = NSScrollView()
    private let grid = FlippedGrid()          // flipped documentView → row 0 at the top
    private var cells: [SearchTileView] = []

    // Grid metrics.
    private let cellW: CGFloat = 150
    private let cellH: CGFloat = 196          // square (150) + title room beneath
    private let gap: CGFloat = 22
    private let sideMargin: CGFloat = 44
    private let gridTopPad: CGFloat = 8

    // Header metrics: a centered (Spotlight/Launchpad-style) search field with the result count as a
    // subtitle beneath it, clear of the window's own titlebar.
    private let fieldTop: CGFloat = 56       // clears the transparent titlebar + "Library" title
    private let fieldH: CGFloat = 36
    private let fieldMaxW: CGFloat = 520
    private var headerH: CGFloat { fieldTop + fieldH + 12 + 18 + 20 }   // field + count + breathing room

    init(games: [Game]) {
        self.allGames = games
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.background.cgColor
        setupUI()
        apply(query: "")
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Setup

    private func setupUI() {
        searchField.placeholderString = "Search games"
        searchField.font = DS.pixel(15)
        searchField.focusRingType = .none
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        addSubview(searchField)

        countLabel.font = DS.pixel(12)
        countLabel.textColor = DS.Color.textSecondary
        countLabel.alignment = .center
        addSubview(countLabel)

        closeButton.onClick = { [weak self] in self?.onClose?() }
        addSubview(closeButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        grid.wantsLayer = true
        scrollView.documentView = grid
        addSubview(scrollView)
    }

    /// Focus the search field so the user can type immediately when the overlay opens.
    func focusSearch() { window?.makeFirstResponder(searchField) }

    // MARK: - Filtering

    private func apply(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Search the whole library (minus hidden carts), by title.
        filtered = allGames.filter { game in
            guard !game.hidden else { return false }
            return q.isEmpty || game.displayTitle.lowercased().contains(q)
        }

        cells.forEach { $0.removeFromSuperview() }
        cells = filtered.map { game in
            let cell = SearchTileView(game: game)
            cell.onLaunch = { [weak self] in
                self?.onClose?()
                self?.onLaunch?(game)
            }
            grid.addSubview(cell)
            return cell
        }

        let n = filtered.count
        if q.isEmpty {
            countLabel.stringValue = "\(n) GAME\(n == 1 ? "" : "S")"
        } else {
            countLabel.stringValue = n == 0 ? "NO MATCHES"
                : "\(n) MATCH\(n == 1 ? "" : "ES")"
        }
        relayoutGrid()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Centered search field (Spotlight/Launchpad-style), the result count centered beneath it as a
        // subtitle, and the ✕ pinned to the top-right corner, aligned to the field's vertical center.
        let fieldW = min(fieldMaxW, bounds.width - sideMargin * 2)
        searchField.frame = CGRect(x: (bounds.width - fieldW) / 2, y: fieldTop,
                                   width: fieldW, height: fieldH)
        countLabel.frame = CGRect(x: 0, y: fieldTop + fieldH + 12,
                                  width: bounds.width, height: 18)   // centered via .center alignment

        let btn = closeButton.measuredWidth
        closeButton.frame = CGRect(x: bounds.width - sideMargin - btn,
                                   y: fieldTop + (fieldH - btn) / 2, width: btn, height: btn)

        scrollView.frame = CGRect(x: 0, y: headerH, width: bounds.width,
                                  height: max(0, bounds.height - headerH))
        relayoutGrid()
    }

    /// Flow the cartridge cells into as many columns as the width allows, centered as a block.
    private func relayoutGrid() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        let usable = width - sideMargin * 2
        let cols = max(1, Int((usable + gap) / (cellW + gap)))
        let rows = cells.isEmpty ? 0 : Int(ceil(Double(cells.count) / Double(cols)))
        let blockW = CGFloat(cols) * cellW + CGFloat(cols - 1) * gap
        let startX = max(sideMargin, (width - blockW) / 2)

        for (i, cell) in cells.enumerated() {
            let r = i / cols, c = i % cols
            cell.frame = CGRect(x: startX + CGFloat(c) * (cellW + gap),
                                y: gridTopPad + CGFloat(r) * (cellH + gap),
                                width: cellW, height: cellH)
        }
        let contentH = rows == 0 ? 0
            : gridTopPad * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        grid.frame = CGRect(x: 0, y: 0, width: width,
                            height: max(contentH, scrollView.contentSize.height))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }   // Esc
        super.keyDown(with: event)
    }
}

// MARK: - Search field delegate

extension SearchGridView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        apply(query: searchField.stringValue)
    }

    /// Return launches the first result; Escape closes the overlay (even while the field is focused).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let first = filtered.first { onClose?(); onLaunch?(first) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// A flipped container so the grid fills top-to-bottom (row 0 at the top) inside the scroll view.
private final class FlippedGrid: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Grid cartridge tile

/// A cartridge cell in the search grid: the shared cartridge art (drawn full-strength via
/// ``CartridgeTileView``) with the game's title beneath it, a soft hover highlight, and a click that
/// launches the game. It reuses the carousel tile's drawing but swaps the carousel's scrub/scale
/// gestures for plain button behavior.
@MainActor
final class SearchTileView: CartridgeTileView {
    var onLaunch: (() -> Void)?
    private var gridHovered = false

    override init(game: Game) {
        super.init(game: game)
        setSelected(true, animated: false)   // full-strength art (no carousel dimming)
        hoverEnabled = false                  // suppress the carousel's own hover transform
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if gridHovered {
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                         xRadius: DS.Radius.tile, yRadius: DS.Radius.tile).fill()
        }
        super.draw(dirtyRect)   // the cartridge itself (square at the top of the cell)
        drawTitle()
    }

    /// The game's title, centered beneath the cartridge square, one line, truncated.
    private func drawTitle() {
        let side = min(bounds.width, bounds.height)
        let top = side + 8
        let rect = CGRect(x: 4, y: top, width: bounds.width - 8, height: max(0, bounds.height - top))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: game.displayTitle, attributes: [
            .font: DS.pixel(11),
            .foregroundColor: gridHovered ? DS.Color.textPrimary : DS.Color.textSecondary,
            .paragraphStyle: style,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // Plain button behavior — no scrub/drag, no carousel selection.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onLaunch?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) { setGridHovered(true) }
    override func mouseExited(with event: NSEvent) { setGridHovered(false) }

    private func setGridHovered(_ on: Bool) {
        guard gridHovered != on else { return }
        gridHovered = on
        needsDisplay = true
        if let layer {
            let t = Motion.scaleAboutCenter(on ? 1.05 : 1.0, in: bounds.size)
            Motion.spring(layer, keyPath: "transform", to: NSValue(caTransform3D: t),
                          response: 0.3, dampingRatio: 0.8)
        }
    }
}
