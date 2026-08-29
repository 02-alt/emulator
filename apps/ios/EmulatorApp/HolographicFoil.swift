import SwiftUI
import UIKit

/// "Holofoil Rare" foil, ported from simeydotme/pokemon-cards-css (`regular-holo.css`). A diagonal
/// rainbow that sweeps as the device tilts, carved into fine vertical beams by a bar layer and textured
/// with fine scanlines, then **bloomed near the light** (a radial mask centred on the tilt) so it reads
/// as a reflection catching foil rather than uniform neon bars. On top, a swirling metallic **contour
/// texture** (`illusion.png`) that only reveals as you tilt off-centre — the "catch it at the right
/// angle" shimmer. The caller color-dodges + luminance-masks it onto the bright cover; `tilt` (−1…1 per
/// axis) is the pointer and `intensity` scales the whole thing.
struct HolographicFoil: View {
    var tilt: CGSize
    var intensity: CGFloat = 1

    /// The swirling contour foil texture (bundled from pokemon-cards-css), revealed on tilt.
    private static let foilImage: UIImage? = {
        if let url = Bundle.main.url(forResource: "illusion", withExtension: "png")
            ?? Bundle.main.url(forResource: "illusion", withExtension: "png", subdirectory: "Resources") {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }()

    /// The six "sunpillar" hues (red→yellow→green→cyan→blue→violet). Highly saturated so the rainbow
    /// reads strongly even after color-dodge onto bright art.
    private static let sunpillars: [Color] = [
        Color(hue: 0.006, saturation: 1.0, brightness: 1),
        Color(hue: 0.147, saturation: 1.0, brightness: 1),
        Color(hue: 0.258, saturation: 1.0, brightness: 1),
        Color(hue: 0.489, saturation: 1.0, brightness: 1),
        Color(hue: 0.633, saturation: 1.0, brightness: 1),
        Color(hue: 0.786, saturation: 1.0, brightness: 1),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let tx = CGFloat(tilt.width), ty = CGFloat(tilt.height)
            let mag = min(1, hypot(tx, ty))   // how far off-centre the tilt is → texture reveal

            // Bloom near the light, fade to clear at the edges (keeps it subtle, and no edge fringe).
            let lightMask = RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white.opacity(0.5), location: 0.5),
                    .init(color: .clear, location: 1.0),
                ]),
                center: UnitPoint(x: 0.5 + tx * 0.45, y: 0.5 + ty * 0.45),
                startRadius: 0,
                endRadius: max(w, h) * 0.9)

            ZStack {
                ZStack {
                    // Diagonal (~110°) repeating rainbow, oversized and offset by tilt so colours sweep.
                    LinearGradient(
                        gradient: Gradient(stops: Self.repeatingStops(Self.sunpillars, cycles: 3)),
                        startPoint: UnitPoint(x: 0, y: 0.15),
                        endPoint: UnitPoint(x: 1, y: 0.85))
                        .frame(width: w * 3, height: h * 3)
                        .offset(x: tx * w * 1.2, y: ty * h * 0.6)
                        .frame(width: w, height: h)
                        .clipped()

                    // Fine vertical scanlines — the brushed-foil texture.
                    LinearGradient(
                        gradient: Gradient(stops: Self.scanStops(cycles: 80)),
                        startPoint: .leading, endPoint: .trailing)
                        .blendMode(.overlay)

                    // Fine vertical beams multiplied over the rest — many thin beams, not fat bars.
                    LinearGradient(
                        gradient: Gradient(stops: Self.barStops(cycles: 40)),
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 3, height: h)
                        .offset(x: tx * w * 0.5)
                        .frame(width: w, height: h)
                        .clipped()
                        .blendMode(.multiply)

                    // Swirling metallic contour texture, panned by tilt. Its opacity ramps with how far
                    // you've tilted, so the swirl only "catches" at certain angles — invisible flat-on.
                    if let foilImage = Self.foilImage {
                        Image(uiImage: foilImage)
                            .resizable()
                            .frame(width: w * 3, height: h * 3)
                            .offset(x: tx * w * 0.5, y: ty * h * 0.5)
                            .frame(width: w, height: h)
                            .clipped()
                            .blendMode(.exclusion)
                            .opacity(0.75 * Double(mag))
                    }
                }
                .compositingGroup()
                .saturation(1.8)
                .contrast(1.25)
                .mask(lightMask)

                // Soft glare hotspot tracking the tilt.
                RadialGradient(
                    gradient: Gradient(colors: [.white.opacity(0.5), .clear]),
                    center: UnitPoint(x: 0.5 + tx * 0.4, y: 0.5 + ty * 0.4),
                    startRadius: 0,
                    endRadius: min(w, h) * 0.7)
                    .blendMode(.plusLighter)
                    .opacity(0.3)
            }
            .opacity(Double(intensity))
        }
    }

    /// `colors` repeated `cycles` times evenly across 0…1.
    static func repeatingStops(_ colors: [Color], cycles: Int) -> [Gradient.Stop] {
        let n = colors.count
        let total = cycles * n
        return (0...total).map { k in
            .init(color: colors[k % n], location: Double(k) / Double(total))
        }
    }

    /// Repeating vertical beams: a bright band across the middle of each period, with dark-grey gaps
    /// (not pure black) so the rainbow still shows between beams rather than being cut out.
    static func barStops(cycles: Int) -> [Gradient.Stop] {
        let gap = Color(white: 0.30)
        var stops: [Gradient.Stop] = []
        for k in 0..<cycles {
            let base = Double(k) / Double(cycles)
            let u = 1.0 / Double(cycles)
            stops.append(.init(color: gap, location: base))
            stops.append(.init(color: gap, location: base + u * 0.28))
            stops.append(.init(color: .white, location: base + u * 0.42))
            stops.append(.init(color: .white, location: base + u * 0.58))
            stops.append(.init(color: gap, location: base + u * 0.72))
        }
        stops.append(.init(color: gap, location: 1))
        return stops
    }

    /// Fine vertical scanlines: a black↔grey repeat, overlay-blended for a brushed-foil texture.
    static func scanStops(cycles: Int) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        for k in 0..<cycles {
            let base = Double(k) / Double(cycles)
            let u = 1.0 / Double(cycles)
            stops.append(.init(color: .black, location: base))
            stops.append(.init(color: Color(white: 0.42), location: base + u * 0.5))
        }
        stops.append(.init(color: .black, location: 1))
        return stops
    }
}
