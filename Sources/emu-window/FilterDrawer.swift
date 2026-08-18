import AppKit
import QuartzCore

/// A pull-up drawer holding the library scope (All Games / Hidden). It's tucked away
/// by default: a small grab handle fades in when the bottom bar is hovered; drag the handle up (or
/// click it) to reveal the options, and drag it back down — or pick one — to tuck it away.
///
/// The dashboard owns the hover (it tracks the whole bottom band and calls ``setBarHovered(_:)``);
/// this view owns the drag, the reveal animation, and the segmented control. It sits just above the
/// glass action bar and never overlaps it, so it never intercepts the bar's clicks.
@MainActor
final class FilterDrawer: NSView {
    /// Chosen index — 0 = All Games, 1 = Hidden.
    var onSelect: ((Int) -> Void)?

    private let titles: [String]
    private var selectedIndex: Int

    private var isOpen = false
    private var barHovered = false
    private let progress = ValueAnimator(0)        // 0 tucked … 1 open
    private let handleReveal = ValueAnimator(0)    // hover fade of the grab handle
    private let hintAlpha = ValueAnimator(0)       // brief "pull up" chevron on hover
    private var hintWork: DispatchWorkItem?
    private var hintShown = false                  // chevron flashes only on the first hover per launch
    private var clickMonitor: Any?                 // dismisses the open drawer on a click outside it

    // Geometry.
    private let handleStripH: CGFloat = 22
    private let drawerH: CGFloat = 46
    private let handleW: CGFloat = 30
    private let segH: CGFloat = 30
    private var segWidths: [CGFloat] = []
    private var segTotalW: CGFloat = 0

    // Drag state.
    private var draggingHandle = false
    private var dragStartY: CGFloat = 0
    private var dragStartProgress: CGFloat = 0
    private var dragMoved = false
    private var dragLastY: CGFloat = 0
    private var dragLastT: CFTimeInterval = 0
    private var dragVelocity: CGFloat = 0   // points/sec, +up

    init(titles: [String], selected: Int = 0) {
        self.titles = titles
        self.selectedIndex = selected
        super.init(frame: .zero)
        wantsLayer = true
        segWidths = titles.map { (DS.Text.label($0, size: 13).size().width + DS.Space.md).rounded() }
        segTotalW = segWidths.reduce(0, +)
        progress.onChange = { [weak self] _ in self?.needsDisplay = true }
        handleReveal.onChange = { [weak self] _ in self?.needsDisplay = true }
        hintAlpha.onChange = { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var isFlipped: Bool { true }

    /// Size the dashboard uses to place it.
    var preferredWidth: CGFloat { max(segTotalW + DS.Space.lg, 160) }
    var preferredHeight: CGFloat { drawerH + handleStripH }

    // MARK: - Hover / open state

    /// Called by the dashboard as the pointer enters/leaves the bottom band.
    func setBarHovered(_ on: Bool) {
        barHovered = on
        updateHandle()
        if on && !isOpen { flashHint() } else { cancelHint() }
    }

    private func setOpen(_ open: Bool) {
        isOpen = open
        progress.animate(to: open ? 1 : 0, duration: 0.42, curve: .easeOutBack)   // springy pop
        if open { cancelHint(); installClickAwayMonitor() } else { removeClickAwayMonitor() }
        updateHandle()
        window?.invalidateCursorRects(for: self)
    }

    /// While open, a click anywhere outside the drawer tucks it away (the click still passes through
    /// to whatever it hit).
    private func installClickAwayMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            let inside = event.window === self.window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !inside { self.setOpen(false) }
            return event
        }
    }

    private func removeClickAwayMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    /// Briefly show the up-chevron (fade in, hold, fade out) to teach the pull-up gesture — but only
    /// the first time the bar is hovered in this launch.
    private func flashHint() {
        guard !hintShown else { return }
        hintShown = true
        hintWork?.cancel()
        hintAlpha.animate(to: 1, duration: Motion.quick)
        let work = DispatchWorkItem { [weak self] in self?.hintAlpha.animate(to: 0, duration: Motion.quick) }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func cancelHint() {
        hintWork?.cancel()
        hintAlpha.animate(to: 0, duration: Motion.quick)
    }

    private func updateHandle() {
        handleReveal.animate(to: (barHovered || isOpen) ? 1 : 0, duration: Motion.quick)
    }

    // MARK: - Regions (flipped, y-down)

    private var handleRect: CGRect {   // generous grab strip
        CGRect(x: (bounds.width - handleW) / 2 - 12, y: drawerH, width: handleW + 24, height: handleStripH)
    }

    private func segmentRects() -> [CGRect] {
        let startX = (bounds.width - segTotalW) / 2
        let y = (drawerH - segH) / 2
        var x = startX
        return segWidths.map { w in defer { x += w }; return CGRect(x: x, y: y, width: w, height: segH) }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let p = progress.value

        // Grab handle — visible on hover or while open.
        // Slim grab handle, sitting close to the bar (near the bottom of the handle strip).
        let pillTop = drawerH + handleStripH - 8
        let hAlpha = max(handleReveal.value, p)
        if hAlpha > 0.01 {
            let pill = CGRect(x: (bounds.width - handleW) / 2, y: pillTop, width: handleW, height: 4)
            DS.Color.hairlineStrong.withAlphaComponent(hAlpha * 0.6).setFill()   // subtle
            NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
        }

        // Brief, faint "pull up" chevron just above the handle — a light hint, so lower and smaller.
        let hint = hintAlpha.value
        if hint > 0.01 && p < 0.5 {
            let cx = bounds.width / 2
            let apexY: CGFloat = pillTop - 10, aw: CGFloat = 5, ah: CGFloat = 4
            let chev = NSBezierPath()
            chev.move(to: CGPoint(x: cx - aw, y: apexY + ah))
            chev.line(to: CGPoint(x: cx, y: apexY))
            chev.line(to: CGPoint(x: cx + aw, y: apexY + ah))
            chev.lineWidth = 1.5
            chev.lineCapStyle = .round
            chev.lineJoinStyle = .round
            DS.Color.hairlineStrong.withAlphaComponent(hint * 0.32).setStroke()   // fainter than handle
            chev.stroke()
        }

        guard p > 0.01 else { return }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.translateBy(x: 0, y: (1 - p) * 8)   // a subtle rise as it opens
        ctx?.setAlpha(p)
        defer { ctx?.restoreGState() }

        // Panel behind the segmented control.
        let segY = (drawerH - segH) / 2
        let panel = CGRect(x: (bounds.width - segTotalW) / 2 - DS.Space.sm, y: segY - 4,
                           width: segTotalW + DS.Space.sm * 2, height: segH + 8)
        let bg = NSBezierPath(roundedRect: panel, xRadius: DS.Radius.control, yRadius: DS.Radius.control)
        DS.Color.surface.setFill(); bg.fill()
        DS.Color.hairline.setStroke(); bg.lineWidth = 1; bg.stroke()

        // Segments.
        for (i, r) in segmentRects().enumerated() {
            if i == selectedIndex {
                let chip = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 3),
                                        xRadius: DS.Radius.chip, yRadius: DS.Radius.chip)
                DS.Color.tileSelected.setFill(); chip.fill()
            } else if i > 0 {
                let sep = NSBezierPath()
                sep.move(to: CGPoint(x: r.minX, y: r.minY + 6))
                sep.line(to: CGPoint(x: r.minX, y: r.maxY - 6))
                DS.Color.hairline.setStroke(); sep.lineWidth = 1; sep.stroke()
            }
            let color = i == selectedIndex ? DS.Color.background : DS.Color.textSecondary
            let str = DS.Text.label(titles[i], size: 13, color: color)
            let sz = str.size()
            str.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }

    // MARK: - Interaction

    /// Interactive only on the handle (always) and the segments (when open); everything else passes
    /// through so the drawer never eats clicks meant for the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if handleRect.contains(local) { return self }
        if progress.value > 0.5, segmentRects().contains(where: { $0.contains(local) }) { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if progress.value > 0.5, let idx = segmentRects().firstIndex(where: { $0.contains(local) }) {
            if idx != selectedIndex { selectedIndex = idx; onSelect?(idx) }
            needsDisplay = true
            setOpen(false)   // tuck away after choosing
            return
        }
        if handleRect.contains(local) {
            draggingHandle = true
            dragStartY = event.locationInWindow.y
            dragStartProgress = progress.value
            dragMoved = false
            dragLastY = event.locationInWindow.y
            dragLastT = CACurrentMediaTime()
            dragVelocity = 0
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingHandle else { return }
        let y = event.locationInWindow.y                      // window coords are y-up
        let now = CACurrentMediaTime()
        let dt = now - dragLastT
        if dt > 0.001 { dragVelocity = (y - dragLastY) / CGFloat(dt) }
        dragLastY = y; dragLastT = now

        let deltaUp = y - dragStartY
        if abs(deltaUp) > 2 { dragMoved = true }
        var p = dragStartProgress + deltaUp / drawerH
        if p > 1 { p = 1 + (p - 1) * 0.35 } else if p < 0 { p = p * 0.35 }   // rubber-band past the ends
        progress.jump(to: p)
    }

    override func mouseUp(with event: NSEvent) {
        guard draggingHandle else { return }
        draggingHandle = false
        let open: Bool
        if dragVelocity > 350 { open = true }           // flick up → open
        else if dragVelocity < -350 { open = false }    // flick down → close
        else if dragMoved { open = progress.value > 0.45 }
        else { open = !isOpen }                          // tap toggles
        setOpen(open)
    }

    override func resetCursorRects() {
        addCursorRect(handleRect, cursor: .openHand)
        if progress.value > 0.5 { for r in segmentRects() { addCursorRect(r, cursor: .pointingHand) } }
    }
}
