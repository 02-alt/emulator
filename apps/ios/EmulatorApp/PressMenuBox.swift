import SwiftUI

/// The glossy black "Apple Intelligence" bubble that wraps every long-press (context-menu) preview,
/// so picking anything up on the shelf lands in the same signature box. Three stacked passes give it
/// that look: a near-black glossy fill (a hair of charcoal lifted at the top, like a summary bubble),
/// a soft specular reflection gliding across the top, and a thin iridescent rim that drifts slowly
/// through pinks/blues/violets — the living shimmer that reads as "AI", kept low-opacity so it stays
/// a quiet halo over the black rather than a coloured wash.
///
/// Use it as the `preview:` for a `.contextMenu`, e.g.
/// ```
/// .contextMenu(menuItems: { … }, preview: { PressMenuBox { SomeContent() } })
/// ```
struct PressMenuBox<Content: View>: View {
    /// Corner radius of the bubble; generous by default to echo the message-bubble silhouette.
    var cornerRadius: CGFloat = 30
    /// Inset around the content so it floats inside the glossy shell.
    var padding: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .padding(padding)
            .background {
                ZStack {
                    // 1. Glossy charcoal fill — a raised graphite card, not pure black: on the app's
                    //    black canvas a true-black box vanishes, so we lift the fill to a dark grey that
                    //    reads as a distinct surface while still carrying the AI-bubble gloss (brighter
                    //    at the top, settling darker at the base).
                    shape.fill(
                        LinearGradient(
                            colors: [Color(white: 0.24), Color(white: 0.15), Color(white: 0.10)],
                            startPoint: .top, endPoint: .bottom))

                    // 2. Specular reflection: a soft bright band across the top third, clipped to the
                    //    bubble, giving the glass its wet, glossy top edge.
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.16), location: 0.0),
                                .init(color: .white.opacity(0.03), location: 0.22),
                                .init(color: .clear, location: 0.5),
                            ],
                            startPoint: .top, endPoint: .bottom))
                        .blendMode(.plusLighter)

                    // 3. Iridescent rim: a slowly drifting rainbow stroke — the Apple-Intelligence
                    //    tell. TimelineView spins the gradient's angle so the hues creep around the
                    //    edge; opacity stays low so it's a halo, not a highlighter.
                    TimelineView(.animation) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        shape.strokeBorder(irisGradient(angle: t * 0.35), lineWidth: 1.4)
                            .blendMode(.plusLighter)
                            .opacity(0.9)
                    }

                    // A hairline inner edge keeps the silhouette crisp against dark wallpaper.
                    shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.75)
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
    }

    /// The oil-slick rim, an angular sweep through soft pinks, violets and blues that rotates with
    /// `angle` (radians) so the colours circle the border.
    private func irisGradient(angle: Double) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(hue: 0.92, saturation: 0.55, brightness: 1),   // rose
                Color(hue: 0.66, saturation: 0.55, brightness: 1),   // indigo
                Color(hue: 0.55, saturation: 0.55, brightness: 1),   // cyan-blue
                Color(hue: 0.78, saturation: 0.55, brightness: 1),   // violet
                Color(hue: 0.92, saturation: 0.55, brightness: 1),   // rose (seam-free loop)
            ]),
            center: .center,
            angle: .radians(angle))
    }
}
