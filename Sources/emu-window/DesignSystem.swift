import AppKit
import CoreText

/// The single source of truth for the UI's visual language.
///
/// Design north star: **Analogue OS** (the Pocket / 3D dashboard) — pure-black canvas, monochrome
/// white/grey, a bundled **pixel/bitmap typeface** (Departure Mono, SIL OFL), cartridges as hero
/// objects on a horizontal carousel, technical metadata tables with bordered pixel chips, and a
/// console-style top/bottom chrome (logo · title · L/R · button-prompt actions). Everything visual
/// reads from here so the whole app can be re-toned by editing one file.
enum DS {

    // MARK: - Palette (Analogue OS: pure black, monochrome)

    enum Color {
        static let background = NSColor.black                                 // #000000
        static let tileSelected = NSColor.white                              // selected cartridge tile
        static let tileUnknown = NSColor(calibratedWhite: 0.20, alpha: 1)    // placeholder tile
        static let tileUnknownArt = NSColor(calibratedWhite: 0.42, alpha: 1) // silhouette on placeholder

        static let hairline = NSColor.white.withAlphaComponent(0.16)
        static let hairlineStrong = NSColor.white.withAlphaComponent(0.85)

        static let textPrimary = NSColor.white
        static let textSecondary = NSColor(calibratedWhite: 0.62, alpha: 1)
        static let textTertiary = NSColor(calibratedWhite: 0.34, alpha: 1)   // dim / disabled
        static let surface = NSColor(calibratedWhite: 0.10, alpha: 1)
        static let surfaceRaised = NSColor(calibratedWhite: 0.17, alpha: 1)   // hovered/active surface
    }

    // MARK: - Spacing (strict grid, 4pt base)

    /// A continuous 4pt-based ramp with no gaps: 4 · 8 · 12 · 16 · 24 · 32 · 40 · 64. Earlier this
    /// skipped 12 and 32, which forced those (and off-grid neighbours like 14) to be written as raw
    /// literals across the custom-drawn surfaces — the two new steps let those snap back onto the grid.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let smd: CGFloat = 12   // fills the 8→16 gap (row/label gaps, capsule insets)
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let ml: CGFloat = 32    // fills the 24→40 gap (control heights, section gaps)
        static let xl: CGFloat = 40
        static let xxl: CGFloat = 64
    }

    // MARK: - Radii

    /// The full set of corner radii in use, tokenised so a shape's rounding is chosen by role rather
    /// than by a bare number. `hairlineChip`/`small`/`badge`/`card` were previously ad-hoc `.cornerRadius`
    /// literals (2 · 4/6 · 7 · 8 · 12) scattered across views; naming them keeps the set small and shared.
    enum Radius {
        static let hairlineChip: CGFloat = 2   // thin bordered thumbnails (Continue cover)
        static let chip: CGFloat = 3
        static let small: CGFloat = 6          // hover fills, hint badges
        static let popover: CGFloat = 7        // floating panels (ambience picker)
        static let control: CGFloat = 5
        static let panel: CGFloat = 8          // toasts, small panels
        static let card: CGFloat = 12          // alert cards
        static let tile: CGFloat = 14
    }

    enum Stroke { static let hairline: CGFloat = 1.5 }

    // MARK: - The pixel typeface

    /// Departure Mono, registered once from the bundle. Falls back to the system monospaced
    /// font if registration ever fails (so the UI still renders, just without the pixel look).
    private static let registerOnce: Void = {
        guard let url = Bundle.moduleResources?.url(forResource: "DepartureMono-Regular", withExtension: "otf") else {
            NSLog("DS: Departure Mono resource missing — falling back to system mono")
            return
        }
        var err: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
            NSLog("DS: Departure Mono registration failed: \(String(describing: err))")
        }
    }()

    /// The bundled pixel font at `size`, or the system monospaced font as a fallback.
    static func pixel(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        _ = registerOnce
        return NSFont(name: "DepartureMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Typography

    enum Text {
        /// A technical field label: uppercase, dim, lightly tracked. The Analogue-OS signature.
        static func label(_ text: String,
                          size: CGFloat = 13,
                          color: NSColor = Color.textSecondary,
                          alignment: NSTextAlignment = .left) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            return NSAttributedString(string: text.uppercased(), attributes: [
                .font: pixel(size),
                .foregroundColor: color,
                .kern: 0.5,
                .paragraphStyle: style,
            ])
        }

        /// A metadata value (mixed-case, primary color) or "-" when unknown.
        static func value(_ text: String?,
                          size: CGFloat = 13,
                          color: NSColor = Color.textPrimary) -> NSAttributedString {
            let s = (text?.isEmpty == false) ? text! : "-"
            return NSAttributedString(string: s.uppercased(), attributes: [
                .font: pixel(size),
                .foregroundColor: text == nil ? Color.textTertiary : color,
                .kern: 0.5,
            ])
        }

        /// A large title in the pixel face (mixed case, as in the reference).
        static func title(_ text: String, size: CGFloat = 34) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return NSAttributedString(string: text, attributes: [
                .font: pixel(size),
                .foregroundColor: Color.textPrimary,
                .paragraphStyle: style,
            ])
        }

        /// Plain mixed-case pixel text at a color (used for "Library", action labels).
        static func plain(_ text: String,
                          size: CGFloat = 15,
                          color: NSColor = Color.textPrimary) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: pixel(size),
                .foregroundColor: color,
            ])
        }
    }

    // MARK: - Chips

    /// Draw a bordered pixel chip (e.g. RUMBLE PAK, USA) at `origin`, returning its full width so
    /// callers can lay chips out in a row. Uppercased pixel text inside a hairline rounded box.
    @discardableResult
    static func drawChip(_ text: String, at origin: CGPoint,
                         color: NSColor = Color.textPrimary,
                         filled: Bool = false) -> CGFloat {
        let str = Text.label(text, size: 12, color: filled ? Color.background : color)
        let textSize = str.size()
        let padX: CGFloat = 6, padY: CGFloat = 3
        let box = CGRect(x: origin.x, y: origin.y,
                         width: (textSize.width + padX * 2).rounded(),
                         height: (textSize.height + padY * 2).rounded())
        let path = NSBezierPath(roundedRect: box, xRadius: Radius.chip, yRadius: Radius.chip)
        if filled {
            color.setFill(); path.fill()
        } else {
            color.withAlphaComponent(0.9).setStroke(); path.lineWidth = 1; path.stroke()
        }
        str.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY))
        return box.width
    }

    // MARK: - Liquid Glass

    /// Render an arbitrary shape as **Liquid Glass** — a translucent frosted fill with a soft vertical
    /// sheen (brightest at the top) and a bright rim. On the pure-black canvas there's nothing behind
    /// the shape to refract, so — like the glass buttons — the light is faked. Used for cartridges and
    /// for selection/fill chrome (selected tabs, segments, the volume bar). `intensity` scales the
    /// whole effect (1 = a focused/selected element; lower recedes). Orientation-aware: it reads the
    /// current context's flip so "top" is always the visual top.
    static func liquidGlass(_ path: NSBezierPath, in rect: CGRect, intensity: CGFloat = 1) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let topY = flipped ? rect.minY : rect.maxY
        let botY = flipped ? rect.maxY : rect.minY
        let cs = CGColorSpaceCreateDeviceRGB()
        func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [1, 1, 1, a])! }

        // Frosted body: a soft sheen, brightest at the top.
        ctx.saveGState()
        path.addClip()
        if let g = CGGradient(colorsSpace: cs,
                              colors: [white(0.28 * intensity), white(0.10 * intensity), white(0.17 * intensity)] as CFArray,
                              locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: topY),
                                   end: CGPoint(x: rect.midX, y: botY), options: [])
        }
        ctx.restoreGState()

        // Bright rim around the silhouette, fading from the top edge downward.
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.setLineWidth(1.5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let g = CGGradient(colorsSpace: cs,
                              colors: [white(0.7 * intensity), white(0.08 * intensity)] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: topY),
                                   end: CGPoint(x: rect.midX, y: botY), options: [])
        }
        ctx.restoreGState()
    }
}
