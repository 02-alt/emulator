import SwiftUI
import UIKit
import EmulatorCore

/// On-screen gamepad, corner-anchored so it works in both portrait (below the screen) and landscape
/// (overlaid on the letterbox beside the screen): D-pad bottom-left, face + shoulder buttons
/// bottom-right, SELECT/START bottom-center.
///
/// Input is handled by a single UIKit multitouch layer (`MultitouchPad`) rather than per-button
/// SwiftUI gestures. SwiftUI routes sibling `DragGesture`s through a shared arena that cancels the
/// first touch when a second finger lands, so holding a direction *and* pressing a face button at the
/// same time silently dropped one of them. The UIKit layer tracks every `UITouch` independently and
/// rebuilds the held-button mask from the union of all touches, so simultaneous presses work.
///
/// The SwiftUI views below are purely visual: each reports its frame (in the `padSpace` coordinate
/// space) up to the overlay, and dims while its bit is held in `mask`.
struct TouchControls: View {
    /// Called with the full held-button mask whenever it changes.
    let onChange: (GBAButtons) -> Void

    @State private var mask = GBAButtons()
    @State private var frames: [UInt16: CGRect] = [:]

    private let padSpace = "TouchControlsPad"
    /// User-set button size. Scales layout dimensions, so the reported frames (and thus the
    /// multitouch hit-testing) scale with the visuals.
    private let scale = CGFloat(AppSettings.controlScale)

    // Base sizes chosen so that even at the smallest ("Small", 0.85×) setting every target stays
    // ≥ 44 pt — Apple's minimum touch target for accessibility.
    private var dpadSide: CGFloat { 56 * scale }   // 0.85× → 47.6
    private var faceSide: CGFloat { 64 * scale }   // 0.85× → 54.4
    private var barH: CGFloat { 52 * scale }        // shoulders + START/SELECT; 0.85× → 44.2
    /// The touch rect is inflated past the visible button so near-misses still register.
    private let hitInset: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if geo.size.width > geo.size.height {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: padSpace)
            .onPreferenceChange(ButtonFramesKey.self) { frames = $0 }
            .overlay(
                MultitouchPad(frames: frames) { newMask in
                    mask = newMask
                    onChange(newMask)
                }
            )
        }
    }

    /// Portrait: the game sits at the top, so controls stack in rows below it — shoulders, then
    /// START/SELECT centered, then D-pad + faces at the bottom corners (prime thumb zone).
    private var portraitLayout: some View {
        VStack(spacing: 18) {
            HStack {
                shoulder("L", .l)
                Spacer()
                shoulder("R", .r)
            }
            HStack(spacing: 16) {
                pill("SELECT", .select)
                pill("START", .start)
            }
            HStack(alignment: .bottom) {
                dpad
                Spacer()
                faceButtons
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// Landscape: the game is centered and fills the height. Controls hug the corners the way a real
    /// pad sits in the hands — L/R shoulders at the TOP corners (index fingers), D-pad and face
    /// buttons at the BOTTOM corners (thumbs), and START/SELECT centered at the bottom.
    private var landscapeLayout: some View {
        ZStack {
            shoulder("L", .l).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            shoulder("R", .r).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            dpad.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            faceButtons.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            HStack(spacing: 16) {
                pill("SELECT", .select)
                pill("START", .start)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// Wraps a button's visual in a frame reporter + pressed-state dimming.
    private func padButton<Content: View>(
        _ button: GBAButtons, @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(mask.contains(button) ? 0.6 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ButtonFramesKey.self,
                        value: [button.rawValue: geo.frame(in: .named(padSpace)).insetBy(dx: -hitInset, dy: -hitInset)])
                }
            )
    }

    // MARK: - D-pad

    private var dpad: some View {
        VStack(spacing: 0) {
            dirButton("▲", .up)
            HStack(spacing: 0) {
                dirButton("◀", .left)
                Color.clear.frame(width: dpadSide, height: dpadSide)
                dirButton("▶", .right)
            }
            dirButton("▼", .down)
        }
    }

    private func dirButton(_ label: String, _ button: GBAButtons) -> some View {
        padButton(button) {
            RoundedRectangle(cornerRadius: 8 * scale)
                .fill(Color.white.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(Color.white.opacity(0.45), lineWidth: 1))
                .overlay(Text(label).font(.system(size: 18 * scale)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: dpadSide, height: dpadSide)
        }
    }

    // MARK: - Face + shoulder buttons

    /// Face buttons — B left, A right (Nintendo layout).
    private var faceButtons: some View {
        HStack(spacing: 20) {
            round("B", .b)
            round("A", .a)
        }
    }

    private func round(_ label: String, _ button: GBAButtons) -> some View {
        padButton(button) {
            Circle()
                .fill(Color.white.opacity(0.22))
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                .overlay(Text(label).font(.system(size: 20 * scale, weight: .semibold)).foregroundStyle(.white))
                .frame(width: faceSide, height: faceSide)
        }
    }

    /// Shoulder buttons (L / R) — wide, sat above each side's cluster.
    private func shoulder(_ label: String, _ button: GBAButtons) -> some View {
        padButton(button) {
            RoundedRectangle(cornerRadius: 12 * scale)
                .fill(Color.white.opacity(0.20))
                .overlay(RoundedRectangle(cornerRadius: 12 * scale).stroke(Color.white.opacity(0.5), lineWidth: 1))
                .overlay(Text(label).font(.system(size: 16 * scale, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 92 * scale, height: barH)
        }
    }

    private func pill(_ label: String, _ button: GBAButtons) -> some View {
        padButton(button) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
                .overlay(Text(label).font(.system(size: 12 * scale, weight: .medium)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: 104 * scale, height: barH)
        }
    }
}

/// Collects each button's frame (keyed by `GBAButtons.rawValue`) in the pad coordinate space.
private struct ButtonFramesKey: PreferenceKey {
    static let defaultValue: [UInt16: CGRect] = [:]
    static func reduce(value: inout [UInt16: CGRect], nextValue: () -> [UInt16: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Transparent UIKit layer that owns all touch handling for the gamepad. It only claims touches that
/// land on a button (see `hitTest`), so taps on the game screen or menu behind it pass through.
private struct MultitouchPad: UIViewRepresentable {
    let frames: [UInt16: CGRect]
    let onChange: (GBAButtons) -> Void

    func makeUIView(context: Context) -> MultitouchView {
        let view = MultitouchView()
        view.frames = frames
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: MultitouchView, context: Context) {
        view.frames = frames
        view.onChange = onChange
    }

    final class MultitouchView: UIView {
        var frames: [UInt16: CGRect] = [:]
        var onChange: ((GBAButtons) -> Void)?

        private var lastMask = GBAButtons()
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            isOpaque = false
            haptic.prepare()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Only intercept touches that begin on a button; let the rest fall through to the views below.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            for rect in frames.values where rect.contains(point) { return self }
            return nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { recompute(event) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { recompute(event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { recompute(event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { recompute(event) }

        /// Rebuild the held mask from *all* live touches so simultaneous presses accumulate.
        private func recompute(_ event: UIEvent?) {
            var mask = GBAButtons()
            for touch in event?.allTouches ?? [] {
                switch touch.phase {
                case .began, .moved, .stationary:
                    let point = touch.location(in: self)
                    for (raw, rect) in frames where rect.contains(point) {
                        mask.insert(GBAButtons(rawValue: raw))
                    }
                default:
                    break   // .ended / .cancelled: this touch no longer holds anything
                }
            }

            guard mask.rawValue != lastMask.rawValue else { return }
            if !mask.subtracting(lastMask).isEmpty, AppSettings.haptics {   // a new button just went down
                haptic.impactOccurred(intensity: 0.6)
                haptic.prepare()
            }
            lastMask = mask
            onChange?(mask)
        }
    }
}
