import AppKit
import QuartzCore

/// Shared motion vocabulary so animation feels consistent everywhere: a couple of standard
/// durations, one easing curve, a Core Animation transaction helper for layer changes, a
/// center-anchored scale transform (for hover lifts on frame-laid-out views), and a tiny
/// timer-driven value animator for custom-drawn transitions (e.g. the detail crossfade).
enum Motion {
    static let quick: CFTimeInterval = 0.28
    static let base: CFTimeInterval = 0.48

    /// A gentle ease-in-out (soft acceleration, long soft settle) — reads smooth and unhurried for
    /// slides and fades, without the abrupt launch of a hard ease-out.
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.42, 0, 0.18, 1) }

    /// Build a `CASpringAnimation` for `keyPath`. `response` is the rough settle time; `dampingRatio`
    /// < 1 adds a little overshoot, 1 is critically damped (none). Shared so every spring in the app
    /// (scale lifts, the carousel translation) speaks the same physical language.
    static func springAnimation(_ keyPath: String, from: Any?, to value: Any,
                                response: CGFloat = 0.42, dampingRatio: CGFloat = 0.82) -> CASpringAnimation {
        let mass: CGFloat = 1
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.mass = mass
        anim.stiffness = pow(2 * .pi / response, 2) * mass
        anim.damping = 4 * .pi * dampingRatio * mass / response
        anim.initialVelocity = 0
        anim.fromValue = from
        anim.toValue = value
        anim.duration = anim.settlingDuration
        return anim
    }

    /// A **spring** animation for a layer property (transform, position…) — the natural, "smooth"
    /// motion for interactive changes like hover lifts and the selection scale. Sets the model value
    /// and layers a matching `CASpringAnimation` from the current presentation so it interrupts
    /// gracefully (a new spring picks up mid-flight instead of snapping).
    static func spring(_ layer: CALayer, keyPath: String, to value: Any,
                       response: CGFloat = 0.42, dampingRatio: CGFloat = 0.82) {
        let anim = springAnimation(keyPath, from: (layer.presentation() ?? layer).value(forKeyPath: keyPath),
                                   to: value, response: response, dampingRatio: dampingRatio)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(anim, forKey: keyPath)
    }

    /// Animate NSView frame changes (the AppKit animator proxy) with our standard easing.
    static func animateViews(_ duration: CFTimeInterval = base, _ body: (NSAnimationContext) -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            body(ctx)   // callers use the explicit `.animator()` proxy; implicit stays off so
                        // direct frame sets (e.g. a wrapping carousel tile) snap instead of sliding
        }
    }

    /// iOS "Designing Fluid Interfaces" momentum projection: the extra distance a flick of
    /// `velocity` (points/sec) coasts before stopping, decelerating at `rate` (→1 = slipperier).
    static func project(_ velocity: CGFloat, rate: CGFloat = 0.992) -> CGFloat {
        (velocity / 1000) * rate / (1 - rate)
    }

    /// A scale transform anchored at the center of a `size`, so a frame-based (anchorPoint 0,0)
    /// view can grow in place on hover without disturbing layout.
    static func scaleAboutCenter(_ s: CGFloat, in size: CGSize) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, size.width / 2, size.height / 2, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
        return t
    }
}

/// A lightweight eased value animator for content that's custom-drawn (where Core Animation can't
/// tween the property for us). Drives `onChange` at display cadence and lerps with ease-in-out.
@MainActor
final class ValueAnimator {
    /// Easing curve. `easeOutBack` overshoots slightly past the target then settles — a springy pop.
    enum Curve { case easeInOut, easeOutBack }

    private(set) var value: CGFloat
    var onChange: ((CGFloat) -> Void)?

    private var timer: Timer?
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = Motion.base
    private var curve: Curve = .easeInOut

    init(_ initial: CGFloat = 1) { value = initial }

    /// Snap immediately (cancelling any run) — e.g. to reset before a fade-in.
    func jump(to v: CGFloat) {
        timer?.invalidate(); timer = nil
        value = v
        onChange?(v)
    }

    func animate(to target: CGFloat, duration: CFTimeInterval = Motion.base, curve: Curve = .easeInOut) {
        timer?.invalidate()
        from = value; to = target; self.duration = max(0.001, duration); self.curve = curve
        start = CACurrentMediaTime()
        // Target-action timer, added to .common modes so it keeps ticking smoothly during tracking.
        let t = Timer(timeInterval: 1.0 / 120.0, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let p = min(1, (CACurrentMediaTime() - start) / duration)
        let eased: Double
        switch curve {
        case .easeInOut:
            eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        case .easeOutBack:
            let c1 = 1.70158, c3 = c1 + 1, x = p - 1
            eased = 1 + c3 * x * x * x + c1 * x * x   // overshoots ~10% then settles
        }
        value = from + (to - from) * CGFloat(eased)
        onChange?(value)
        if p >= 1 { timer?.invalidate(); timer = nil }
    }
}
