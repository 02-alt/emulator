import AppKit
import LibraryKit

/// The **Continue** affordance on the shelf — the last-played game surfaced as a one-tap resume. Drawn
/// in the app's Analogue-OS language (no glass): a small cover thumbnail with a hairline border, a grey
/// "CONTINUE" eyebrow, and the title in the pixel face — matching the metadata table beneath. A flat
/// hover fill (like a selectable row) signals it's clickable; clicking anywhere resumes.
@MainActor
final class ContinueBanner: NSView {
    /// Invoked when clicked — the owner launches the current last-played game.
    var onClick: (() -> Void)?

    private let coverHBase: CGFloat = 34
    private let leadBase: CGFloat = 8     // gap from the hover box's left edge to the cover
    private let trailBase: CGFloat = 14
    private let gapBase: CGFloat = 12     // cover → text
    private let maxTitleWBase: CGFloat = 300  // long titles truncate rather than stretch the row
    private let titlePadBase: CGFloat = 8     // slack past the measured title so its last glyph never clips

    /// Matches the shelf's `contentScale` so the row grows with the rest of the dashboard in fullscreen.
    /// The owner sets this before calling ``update(game:)``.
    var uiScale: CGFloat = 1

    private var coverH: CGFloat { coverHBase * uiScale }
    private var leadInset: CGFloat { leadBase * uiScale }
    private var trailInset: CGFloat { trailBase * uiScale }
    private var gap: CGFloat { gapBase * uiScale }
    private var maxTitleW: CGFloat { maxTitleWBase * uiScale }
    private var titlePad: CGFloat { titlePadBase * uiScale }

    /// How far the cover sits in from this view's left edge — the owner shifts the view left by this so
    /// the cover aligns with the content margin (the big title below starts at the same x).
    var leadingInset: CGFloat { leadInset }

    private let coverView = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "CONTINUE")
    private let titleField = NSTextField(labelWithString: "")
    private var hovered = false
    private var tracking: NSTrackingArea?

    private var coverW: CGFloat = 34
    /// Width the row wants for its current game — the owner reads this to size/place it.
    private(set) var measuredWidth: CGFloat = 160

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = DS.Radius.hairlineChip
        coverView.layer?.borderWidth = 1
        coverView.layer?.borderColor = DS.Color.hairline.cgColor
        coverView.layer?.masksToBounds = true
        coverView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(coverView)

        eyebrow.textColor = DS.Color.textSecondary
        addSubview(eyebrow)

        titleField.textColor = DS.Color.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        addSubview(titleField)
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Point the row at a new game — updates cover/title and recomputes ``measuredWidth``. `eyebrow`
    /// is the grey label above the title: "CONTINUE" for the local last-played game, or e.g.
    /// "CONTINUE FROM IPHONE" when the row surfaces a cross-device Continuity session.
    func update(game: Game, eyebrow eyebrowText: String = "CONTINUE") {
        eyebrow.stringValue = eyebrowText
        eyebrow.font = DS.pixel((9 * uiScale).rounded())
        titleField.font = DS.pixel((13 * uiScale).rounded())
        titleField.stringValue = game.displayTitle
        if let url = game.coverURL, let img = NSImage(contentsOf: url), img.size.height > 0 {
            coverView.image = img
            coverW = min(max((coverH * img.size.width / img.size.height).rounded(), 22 * uiScale), 60 * uiScale)
        } else {
            coverView.image = nil
            coverW = coverH
        }
        // Pad past the exact glyph width: NSTextField reserves a couple points of internal margin, so
        // sizing the column to the bare measured width clips the last character ("Advance Wa…").
        let titleW = min(ceil(titleField.attributedStringValue.size().width) + titlePad, maxTitleW)
        let eyebrowW = ceil(eyebrow.attributedStringValue.size().width)
        measuredWidth = leadInset + coverW + gap + max(titleW, eyebrowW) + trailInset
        needsLayout = true
    }

    /// Flat hover fill — a selectable-row highlight, not a glass panel. Painted behind the subviews.
    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: DS.Radius.small, yRadius: DS.Radius.small).fill()
    }

    override func layout() {
        super.layout()
        coverView.layer?.cornerRadius = DS.Radius.hairlineChip * uiScale
        coverView.frame = CGRect(x: leadInset, y: (bounds.height - coverH) / 2, width: coverW, height: coverH)

        // Two-line stack (eyebrow over title), vertically centered. Not flipped: higher y is nearer top.
        let textX = leadInset + coverW + gap
        let textW = max(0, bounds.width - textX - trailInset)
        let eH = (12 * uiScale).rounded(), tH = (18 * uiScale).rounded(), spacing = uiScale
        let bottom = (bounds.height - (eH + spacing + tH)) / 2
        titleField.frame = CGRect(x: textX, y: bottom, width: textW, height: tH)
        eyebrow.frame = CGRect(x: textX, y: bottom + tH + spacing, width: textW, height: eH)
    }

    // MARK: - Hover / click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
