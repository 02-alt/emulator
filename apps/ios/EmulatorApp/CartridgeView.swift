import SwiftUI
import UIKit
import LibraryKit

/// In-memory cache of decoded cover art, keyed by file path. `UIImage(contentsOfFile:)` re-reads AND
/// re-decodes the file on every call — and the carousel calls it from inside a view `body`, so a plain
/// load decodes every cover from disk on each scroll frame, which stutters badly. Route cover loads
/// through here so repeated body evaluations are just a cache hit (already-decoded bitmap).
@MainActor
enum CoverStore {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Draws a game's cartridge in the shape of its console: the wide GBA shell for Game Boy Advance
/// carts, the near-square portrait Game Boy shell for Game Boy / Color carts. A thin dispatcher so
/// call sites (shelf, launch cinematic) stay system-agnostic — they hand it the game's system and the
/// same cover/title/intensity params both underlying carts share.
struct CartridgeView: View {
    let system: GameSystem
    let cover: UIImage?
    let title: String
    let systemTag: String
    var intensity: CGFloat = 1
    var coverOpacity: Double = 1
    var crop: CoverCrop? = nil
    /// When set, laminates a holographic foil over the cover, shifting with this tilt (−1…1 per axis).
    /// `nil` on the shelf so carts stay flat; supplied by the long-press preview.
    var foilTilt: CGSize? = nil

    var body: some View {
        switch system {
        case .gba:
            GBACartridgeView(cover: cover, title: title, systemTag: systemTag,
                             intensity: intensity, coverOpacity: coverOpacity, crop: crop, foilTilt: foilTilt)
        case .gbc, .ps1:
            // iOS has no bespoke PS1 disc-case art yet; reuse the square Game Boy cart as a placeholder.
            GBCCartridgeView(cover: cover, title: title, systemTag: systemTag,
                             intensity: intensity, coverOpacity: coverOpacity, crop: crop, foilTilt: foilTilt)
        }
    }

    /// The label-window aspect (width ÷ height) for a system's cart — GBA landscape, Game Boy square.
    /// Cover crops are authored at this aspect so they fill the window without distortion.
    static func labelAspect(for system: GameSystem) -> CGFloat {
        switch system {
        case .gba: return GBACartridgeView.labelAspect
        case .gbc, .ps1: return GBCCartridgeView.labelAspect
        }
    }

    /// The cart silhouette's own width ÷ height — used to size the hero frame in the launch cinematic
    /// so each console's cart keeps its true proportions (GBA wide, Game Boy portrait).
    static func cartAspect(for system: GameSystem) -> CGFloat {
        switch system {
        case .gba: return 1.78
        case .gbc, .ps1: return GBCCartridgeView.cartAspect
        }
    }
}

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
    /// Optional per-game framing of the cover within the label window. `nil`/`.full` → centered
    /// aspect-fill; otherwise the normalized crop is applied non-destructively at display time.
    var crop: CoverCrop? = nil
    /// Holographic-foil tilt (−1…1 per axis); `nil` → no foil (the shelf). See `foilOverlay`.
    var foilTilt: CGSize? = nil

    /// The label window's width:height. Any cover crop is authored at this aspect so it fills without
    /// distortion (see `CoverCropEditor`).
    static var labelAspect: CGFloat { (0.853 - 0.145) * 1.78 / (0.855 - 0.235) }

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
                    coverArt(cover, win: win, radius: bw * 0.03)
                        // Holographic foil laminated onto the art, then the clear glass pane on top.
                        .overlay { foilOverlay(cover: cover, win: win, radius: bw * 0.03) }
                        .overlay { glassOverlay(radius: bw * 0.03) }   // clear Liquid Glass pane (iOS 26+)
                        .compositingGroup()
                        // Hard-clip so the glass never spills past the cover at full tilt.
                        .clipShape(RoundedRectangle(cornerRadius: bw * 0.03))
                        .opacity(coverOpacity)
                        .position(x: win.midX, y: win.midY)
                }
            }
        }
    }

    /// Holographic foil laminated over the cover label (clipped to its rounded rect) — only in the
    /// long-press preview (`foilTilt` set); `nil` on the shelf. Color-dodges onto the bright cover art.
    @ViewBuilder
    private func foilOverlay(cover: UIImage, win: CGRect, radius: CGFloat) -> some View {
        if let foilTilt {
            HolographicFoil(tilt: foilTilt, intensity: intensity)
                // Mask the foil by the cover art's own luminance so the shimmer hugs the bright/whitish
                // areas and skips the dark ones — an embossed, 3D foil rather than a flat sheet. (This is
                // how the CSS masks holo to regions.) The cover clip also bounds it, so no edge fringe.
                .mask(coverArt(cover, win: win, radius: radius).luminanceToAlpha())
                .blendMode(.colorDodge)
                .allowsHitTesting(false)
        }
    }

    /// A clear Liquid Glass pane over the cover — the label sits under glossy glass, so it gets Apple's
    /// real refraction and a specular highlight that shifts as you move the phone. Only in the long-press
    /// preview (gated on `foilTilt`); iOS 26+ only, a no-op below that.
    @ViewBuilder
    private func glassOverlay(radius: CGFloat) -> some View {
        if let foilTilt, #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: radius)
            GeometryReader { _ in
                ZStack {
                    // The real Liquid Glass pane (keeps the art crisp, adds refraction).
                    Color.clear.glassEffect(.clear.interactive(), in: shape)

                    // A bold glossy highlight that sweeps across as you tilt — the visible "glass catching
                    // the light" the native material is too subtle to show on its own.
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.2),
                            .init(color: .white.opacity(0.3), location: 0.5),
                            .init(color: .clear, location: 0.8),
                        ]),
                        startPoint: UnitPoint(x: -0.5 + foilTilt.width * 0.8, y: -0.2 + foilTilt.height * 0.4),
                        endPoint: UnitPoint(x: 0.5 + foilTilt.width * 0.8, y: 1.2 + foilTilt.height * 0.4))
                        .blendMode(.plusLighter)
                        .clipShape(shape)

                    // Glass edge rim so it reads as a raised pane.
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The cover art filling the label window. With a `crop`, scale the source so the crop rect fills
    /// the window, offset so the crop's top-left sits at the window origin, then clip — non-destructive
    /// (the source image is untouched). Without one, plain centered aspect-fill.
    @ViewBuilder
    private func coverArt(_ image: UIImage, win: CGRect, radius: CGFloat) -> some View {
        if let crop, crop != .full, image.size.width > 0, image.size.height > 0 {
            let iw = image.size.width, ih = image.size.height
            let scale = win.width / (CGFloat(crop.width) * iw)
            Image(uiImage: image)
                .resizable()
                .frame(width: iw * scale, height: ih * scale)
                .offset(x: -CGFloat(crop.x) * iw * scale, y: -CGFloat(crop.y) * ih * scale)
                .frame(width: win.width, height: win.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: radius))
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: win.width, height: win.height)
                .clipShape(RoundedRectangle(cornerRadius: radius))
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

/// A Game Boy / Game Boy Color cartridge — the iOS port of the macOS `drawGBCCartridge`. A near-square
/// **portrait** shell (**0.90:1**) with the console's hallmarks: ribbed thumb grips tucked into the top
/// corners, a recessed grip groove across the top, a large **square** label window for the cover, and a
/// small ▽ insertion arrow at the foot. Same Liquid-Glass body + dark recesses as `GBACartridgeView`
/// so the two read as one family of carts. Drawn in SwiftUI's y-down space, matching the flipped AppKit
/// coords of the original.
struct GBCCartridgeView: View {
    let cover: UIImage?
    let title: String
    let systemTag: String
    var intensity: CGFloat = 1
    var coverOpacity: Double = 1
    var crop: CoverCrop? = nil
    /// Holographic-foil tilt (−1…1 per axis); `nil` → no foil (the shelf). See `foilOverlay`.
    var foilTilt: CGSize? = nil

    /// Cart silhouette width ÷ height (portrait).
    static let cartAspect: CGFloat = 0.90
    /// The label window is square (matches `GameSystem.gbc.coverAspect`).
    static var labelAspect: CGFloat { 1.0 }

    private static let ground = Color(white: 0.09)

    var body: some View {
        GeometryReader { geo in
            // Fit a 0.90:1 portrait body inside the frame, centered.
            let bh = min(geo.size.height, geo.size.width / Self.cartAspect)
            let bw = bh * Self.cartAspect
            let box = CGRect(x: (geo.size.width - bw) / 2,
                             y: (geo.size.height - bh) / 2,
                             width: bw, height: bh)
            let win = Self.labelWindow(box)

            ZStack {
                Canvas { ctx, _ in
                    Self.drawShell(ctx, box: box, hasCover: cover != nil,
                                   title: title, systemTag: systemTag, intensity: intensity)
                }
                if let cover {
                    coverArt(cover, win: win, radius: bw * 0.03)
                        // Holographic foil laminated onto the art, then the clear glass pane on top.
                        .overlay { foilOverlay(cover: cover, win: win, radius: bw * 0.03) }
                        .overlay { glassOverlay(radius: bw * 0.03) }   // clear Liquid Glass pane (iOS 26+)
                        .compositingGroup()
                        // Hard-clip so the glass never spills past the cover at full tilt.
                        .clipShape(RoundedRectangle(cornerRadius: bw * 0.03))
                        .opacity(coverOpacity)
                        .position(x: win.midX, y: win.midY)
                }
            }
        }
    }

    /// Holographic foil laminated over the cover label — only in the long-press preview (`foilTilt`
    /// set); `nil` on the shelf.
    @ViewBuilder
    private func foilOverlay(cover: UIImage, win: CGRect, radius: CGFloat) -> some View {
        if let foilTilt {
            HolographicFoil(tilt: foilTilt, intensity: intensity)
                // Mask the foil by the cover art's own luminance so the shimmer hugs the bright/whitish
                // areas and skips the dark ones — an embossed, 3D foil rather than a flat sheet. (This is
                // how the CSS masks holo to regions.) The cover clip also bounds it, so no edge fringe.
                .mask(coverArt(cover, win: win, radius: radius).luminanceToAlpha())
                .blendMode(.colorDodge)
                .allowsHitTesting(false)
        }
    }

    /// A clear Liquid Glass pane over the cover — the label sits under glossy glass, so it gets Apple's
    /// real refraction and a specular highlight that shifts as you move the phone. Only in the long-press
    /// preview (gated on `foilTilt`); iOS 26+ only, a no-op below that.
    @ViewBuilder
    private func glassOverlay(radius: CGFloat) -> some View {
        if let foilTilt, #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: radius)
            GeometryReader { _ in
                ZStack {
                    // The real Liquid Glass pane (keeps the art crisp, adds refraction).
                    Color.clear.glassEffect(.clear.interactive(), in: shape)

                    // A bold glossy highlight that sweeps across as you tilt — the visible "glass catching
                    // the light" the native material is too subtle to show on its own.
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.2),
                            .init(color: .white.opacity(0.3), location: 0.5),
                            .init(color: .clear, location: 0.8),
                        ]),
                        startPoint: UnitPoint(x: -0.5 + foilTilt.width * 0.8, y: -0.2 + foilTilt.height * 0.4),
                        endPoint: UnitPoint(x: 0.5 + foilTilt.width * 0.8, y: 1.2 + foilTilt.height * 0.4))
                        .blendMode(.plusLighter)
                        .clipShape(shape)

                    // Glass edge rim so it reads as a raised pane.
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.1)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The cover art filling the square label window — same non-destructive crop math as the GBA cart.
    @ViewBuilder
    private func coverArt(_ image: UIImage, win: CGRect, radius: CGFloat) -> some View {
        if let crop, crop != .full, image.size.width > 0, image.size.height > 0 {
            let iw = image.size.width, ih = image.size.height
            let scale = win.width / (CGFloat(crop.width) * iw)
            Image(uiImage: image)
                .resizable()
                .frame(width: iw * scale, height: ih * scale)
                .offset(x: -CGFloat(crop.x) * iw * scale, y: -CGFloat(crop.y) * ih * scale)
                .frame(width: win.width, height: win.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: radius))
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: win.width, height: win.height)
                .clipShape(RoundedRectangle(cornerRadius: radius))
        }
    }

    // MARK: Geometry

    private static func pt(_ box: CGRect, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + fx * box.width, y: box.minY + fy * box.height)
    }

    /// The square cover window, centered horizontally and set below the grip groove.
    private static func labelWindow(_ box: CGRect) -> CGRect {
        let side = box.width * 0.68
        return CGRect(x: box.midX - side / 2, y: box.minY + box.height * 0.25,
                      width: side, height: side)
    }

    // MARK: Canvas drawing

    private static func drawShell(_ ctx: GraphicsContext, box: CGRect,
                                  hasCover: Bool, title: String, systemTag: String,
                                  intensity: CGFloat) {
        let bw = box.width, bh = box.height
        func F(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { pt(box, fx, fy) }

        // Shell body: the same frosted glass gradient + bright rim as the GBA cart, as a rounded rect.
        let shell = Path(roundedRect: box, cornerRadius: bw * 0.06)
        let top = CGPoint(x: box.midX, y: box.minY)
        let bottom = CGPoint(x: box.midX, y: box.maxY)
        ctx.fill(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(white: 0.28 * intensity), location: 0),
                .init(color: Color(white: 0.10 * intensity), location: 0.55),
                .init(color: Color(white: 0.17 * intensity), location: 1),
            ]),
            startPoint: top, endPoint: bottom))
        ctx.stroke(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.7 * intensity), location: 0),
                .init(color: .white.opacity(0.08 * intensity), location: 1),
            ]),
            startPoint: top, endPoint: bottom),
            lineWidth: 1.5)

        // Slot keys: small dark notches cut into the top edge just inside each shoulder.
        for nx in [CGFloat(0.05), CGFloat(0.95)] {
            let slot = CGRect(x: F(nx, 0).x - bw * 0.007, y: box.minY,
                              width: bw * 0.014, height: bh * 0.05)
            ctx.fill(Path(roundedRect: slot, cornerRadius: bw * 0.006), with: .color(ground))
        }

        // Ribbed thumb grips: a few short vertical ridges tucked into each top corner.
        var ribs = Path()
        for base in [CGFloat(0.055), CGFloat(0.85)] {
            for i in 0..<4 {
                let x = box.minX + (base + CGFloat(i) * 0.030) * bw
                ribs.move(to: CGPoint(x: x, y: box.minY + bh * 0.055))
                ribs.addLine(to: CGPoint(x: x, y: box.minY + bh * 0.125))
            }
        }
        ctx.stroke(ribs, with: .color(ground),
                   style: StrokeStyle(lineWidth: max(1, bw * 0.010), lineCap: .round))

        // Thumb groove: a recessed pill across the top center, between the two grips.
        let grooveH = bh * 0.075
        let groove = CGRect(x: F(0.20, 0).x, y: box.minY + bh * 0.045,
                            width: (0.80 - 0.20) * bw, height: grooveH)
        ctx.fill(Path(roundedRect: groove, cornerRadius: grooveH / 2), with: .color(ground))

        // Blank label (only when there's no cover; otherwise the cover view covers this window).
        if !hasCover { drawBlankLabel(ctx, box: box, title: title, systemTag: systemTag) }

        // Insertion arrow: a shallow ▽ centered beneath the label.
        var notch = Path()
        notch.move(to: F(0.44, 0.915))
        notch.addLine(to: F(0.56, 0.915))
        notch.addLine(to: F(0.5, 0.955))
        notch.closeSubpath()
        ctx.fill(notch, with: .color(ground))
    }

    /// The default label for a Game Boy cart with no cover: a square dark ground, an inset frame, a
    /// two-initial monogram, and the system tag — the square sibling of the GBA cart's blank label.
    private static func drawBlankLabel(_ ctx: GraphicsContext, box: CGRect,
                                       title: String, systemTag: String) {
        let win = labelWindow(box)
        ctx.fill(Path(roundedRect: win, cornerRadius: box.width * 0.03), with: .color(ground))

        let frame = win.insetBy(dx: win.width * 0.07, dy: win.height * 0.07)
        ctx.stroke(Path(roundedRect: frame, cornerRadius: box.width * 0.02),
                   with: .color(.white.opacity(0.13)), lineWidth: 1)

        let mono = cartInitials(from: title)
        let monoSize = min(win.height * 0.38, win.width * 0.34)
        ctx.draw(Text(mono).font(.system(size: monoSize, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.3)),
                 at: CGPoint(x: win.midX, y: win.midY - win.height * 0.05))

        ctx.draw(Text(systemTag)
            .font(.system(size: max(8, win.height * 0.10), weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.28)),
                 at: CGPoint(x: win.midX, y: frame.maxY - win.height * 0.10))
    }
}

/// Two-letter monogram from a title (articles skipped): "Legend of Zelda" → "LZ". Shared by the cart
/// views' blank labels.
private func cartInitials(from title: String) -> String {
    let stop: Set<String> = ["the", "of", "a", "an", "and", "or", "to", "in", "for", "de", "le", "la"]
    let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let sig = words.filter { !stop.contains($0.lowercased()) }
    let letters = sig.compactMap(\.first).map { String($0).uppercased() }
    if letters.count >= 2 { return letters[0] + letters[1] }
    let base = (sig.first ?? words.first ?? title).filter { $0.isLetter || $0.isNumber }
    if base.count >= 2 { return String(base.prefix(2)).uppercased() }
    return base.isEmpty ? "?" : base.uppercased()
}
