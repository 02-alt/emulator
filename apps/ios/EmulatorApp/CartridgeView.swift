import SwiftUI

/// A GBA cartridge in its authentic case form — the iOS port of the macOS `CartridgeTileView`
/// (`emu-window/CoverView.swift`). Every proportion is the same fraction of the silhouette's
/// bounding box, measured from the reference outline: a wide body (**1.78:1**) with a flat top
/// insertion edge, shoulder bulges at the top corners, the signature domed **seam arc**, a large
/// **label window** that holds the cover art, and a **grip notch (▽)** at the bottom.
///
/// SwiftUI's default coordinate space is y-down, which matches the flipped AppKit coords the
/// original was drawn in, so the fractional points map across verbatim.
struct GBACartridgeView: View {
    let cover: UIImage?
    let title: String
    let systemTag: String
    /// Scales the glass sheen: 1 for the focused/selected cart, ~0.62 for a receded side cart —
    /// the same `intensity` the Mac's `DS.liquidGlass` takes. The dark ground/seam stay constant.
    var intensity: CGFloat = 1
    /// Cover-art strength: 1 focused, ~0.85 receded — matches the Mac's unselected `fraction`.
    var coverOpacity: Double = 1

    /// Recessed areas (grip, seam, label backing) — dark, so details read against the body.
    private static let ground = Color(white: 0.09)

    var body: some View {
        GeometryReader { geo in
            let bw = geo.size.width
            let bh = min(geo.size.height, bw / 1.78)
            let box = CGRect(x: (geo.size.width - bw) / 2,
                             y: (geo.size.height - bh) / 2,
                             width: bw, height: bh)
            let win = Self.labelWindow(box)

            ZStack {
                Canvas { ctx, _ in
                    Self.drawShell(ctx, box: box, hasCover: cover != nil,
                                   title: title, systemTag: systemTag, intensity: intensity)
                }
                // Cover art sits in the label window (aspect-fill, clipped) — the same treatment
                // as the Mac's `fillLabel`. Drawn as a real view so the crop + rounding are exact.
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: win.width, height: win.height)
                        .clipShape(RoundedRectangle(cornerRadius: bw * 0.03))
                        .opacity(coverOpacity)
                        .position(x: win.midX, y: win.midY)
                }
            }
        }
    }

    // MARK: Geometry (fractions of the silhouette box)

    /// Point at fractional (fx, fy) within the cartridge's bounding box.
    private static func pt(_ box: CGRect, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + fx * box.width, y: box.minY + fy * box.height)
    }

    /// The cover-art window — a landscape rectangle, same fractions as the Mac cart.
    private static func labelWindow(_ box: CGRect) -> CGRect {
        let tl = pt(box, 0.145, 0.235)
        return CGRect(x: tl.x, y: tl.y,
                      width: (0.853 - 0.145) * box.width,
                      height: (0.855 - 0.235) * box.height)
    }

    /// Outer silhouette, clockwise from the top-left of the flat top edge. The top corners bulge
    /// out to full width (the shoulders) then taper back to the straight sides.
    private static func silhouette(_ box: CGRect) -> Path {
        func F(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { pt(box, fx, fy) }
        let tiX: CGFloat = 0.041                          // flat top edge inset
        let sXL: CGFloat = 0.027, sXR: CGFloat = 0.973    // straight sides
        let bulgeY: CGFloat = 0.12                        // shoulders reach full width
        let taperY: CGFloat = 0.30                        // side settles straight
        let botRy: CGFloat = 0.06, bcX: CGFloat = 0.045   // bottom corner radii

        var p = Path()
        p.move(to: F(tiX, 0))
        p.addLine(to: F(1 - tiX, 0))                                                     // flat top edge
        p.addCurve(to: F(1, bulgeY), control1: F(1 - tiX * 0.35, 0), control2: F(1, bulgeY * 0.5))   // TR shoulder out
        p.addCurve(to: F(sXR, taperY), control1: F(1, bulgeY + 0.06), control2: F(sXR, taperY - 0.10)) // taper to side
        p.addLine(to: F(sXR, 1 - botRy))                                                 // right side
        p.addCurve(to: F(1 - bcX, 1), control1: F(sXR, 1), control2: F(sXR, 1))          // BR corner
        p.addLine(to: F(bcX, 1))                                                         // bottom edge
        p.addCurve(to: F(sXL, 1 - botRy), control1: F(sXL, 1), control2: F(sXL, 1))      // BL corner
        p.addLine(to: F(sXL, taperY))                                                    // left side
        p.addCurve(to: F(0, bulgeY), control1: F(sXL, taperY - 0.10), control2: F(0, bulgeY + 0.06))  // taper to shoulder
        p.addCurve(to: F(tiX, 0), control1: F(0, bulgeY * 0.5), control2: F(tiX * 0.35, 0))           // TL shoulder in
        p.closeSubpath()
        return p
    }

    // MARK: Canvas drawing

    private static func drawShell(_ ctx: GraphicsContext, box: CGRect,
                                  hasCover: Bool, title: String, systemTag: String,
                                  intensity: CGFloat) {
        let bw = box.width, bh = box.height
        func F(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { pt(box, fx, fy) }

        // Body + rim: the same two passes as the macOS `DS.liquidGlass`, scaled by `intensity`. The
        // cart floats on black, so the body's white-over-black alphas are drawn as opaque greys of
        // the same value; the rim keeps its alpha so it lifts over the body.
        let shell = silhouette(box)
        let top = CGPoint(x: box.midX, y: box.minY)
        let bottom = CGPoint(x: box.midX, y: box.maxY)

        // Frosted body: a soft sheen, brightest at the top, dipping darkest through the middle.
        ctx.fill(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(white: 0.28 * intensity), location: 0),
                .init(color: Color(white: 0.10 * intensity), location: 0.55),
                .init(color: Color(white: 0.17 * intensity), location: 1),
            ]),
            startPoint: top, endPoint: bottom))

        // Bright rim around the silhouette, fading from the top edge downward.
        ctx.stroke(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.7 * intensity), location: 0),
                .init(color: .white.opacity(0.08 * intensity), location: 1),
            ]),
            startPoint: top, endPoint: bottom),
            lineWidth: 1.5)

        // Corner notch grooves: the small dark slots just inside each shoulder that set the grip
        // tabs apart from the body — a hallmark of the GBA cart's top corners.
        for nx in [CGFloat(0.052), CGFloat(0.948)] {
            let slot = CGRect(x: F(nx, 0).x - bw * 0.006, y: F(nx, 0.02).y,
                              width: bw * 0.012, height: bh * 0.09)
            ctx.fill(Path(roundedRect: slot, cornerRadius: bw * 0.006), with: .color(ground))
        }

        // Shell seam: the bold dark arc that domes up toward the top edge at center.
        var seam = Path()
        seam.move(to: F(0.11, 0.11))
        seam.addCurve(to: F(0.89, 0.11), control1: F(0.33, 0.02), control2: F(0.67, 0.02))
        ctx.stroke(seam, with: .color(ground),
                   style: StrokeStyle(lineWidth: max(1.5, bh * 0.024), lineCap: .round))

        // Blank label (only when there's no cover; otherwise the cover view covers this window).
        if !hasCover { drawBlankLabel(ctx, box: box, title: title, systemTag: systemTag) }

        // Grip notch: a shallow ▽ just below the label's bottom edge.
        var notch = Path()
        notch.move(to: F(0.405, 0.90))
        notch.addLine(to: F(0.595, 0.90))
        notch.addLine(to: F(0.5, 0.96))
        notch.closeSubpath()
        ctx.fill(notch, with: .color(ground))
    }

    /// The default label for a cart with no cover art: a dark ground with an inset printed-label
    /// frame, a two-initial monogram, and the system tag. Minimalist, on-brand for Analogue OS.
    private static func drawBlankLabel(_ ctx: GraphicsContext, box: CGRect,
                                       title: String, systemTag: String) {
        let win = labelWindow(box)
        ctx.fill(Path(roundedRect: win, cornerRadius: box.width * 0.03), with: .color(ground))

        let frame = win.insetBy(dx: win.width * 0.055, dy: win.height * 0.09)
        ctx.stroke(Path(roundedRect: frame, cornerRadius: box.width * 0.02),
                   with: .color(.white.opacity(0.13)), lineWidth: 1)

        let mono = initials(from: title)
        let monoSize = min(win.height * 0.42, win.width * 0.30)
        ctx.draw(Text(mono).font(.system(size: monoSize, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.3)),
                 at: CGPoint(x: win.midX, y: win.midY - win.height * 0.04))

        ctx.draw(Text(systemTag)
            .font(.system(size: max(8, win.height * 0.11), weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.28)),
                 at: CGPoint(x: win.midX, y: frame.maxY - win.height * 0.10))
    }

    /// Two-letter monogram from a title: initials of the first two significant words (articles
    /// skipped, so "Legend of Zelda, The" → "LZ"), else the first two letters.
    private static func initials(from title: String) -> String {
        let stop: Set<String> = ["the", "of", "a", "an", "and", "or", "to", "in", "for", "de", "le", "la"]
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let sig = words.filter { !stop.contains($0.lowercased()) }
        let letters = sig.compactMap(\.first).map { String($0).uppercased() }
        if letters.count >= 2 { return letters[0] + letters[1] }
        let base = (sig.first ?? words.first ?? title).filter { $0.isLetter || $0.isNumber }
        if base.count >= 2 { return String(base.prefix(2)).uppercased() }
        return base.isEmpty ? "?" : base.uppercased()
    }
}
