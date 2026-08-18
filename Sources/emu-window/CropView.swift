import AppKit
import LibraryKit

/// An aspect-locked crop control: shows a source image aspect-fit, with a draggable/resizable crop
/// rectangle over it. Everything outside the crop is dimmed, and a rule-of-thirds grid + corner
/// handles sit on the selection. The crop's aspect is fixed to `targetAspect` (the cartridge label
/// shape), so what the user frames is exactly what the cartridge shows.
///
/// The **normalized** crop (top-left origin, matching CGImage) is the source of truth, so the framing
/// survives window resizes and reopening the editor; the on-screen rectangle is derived from it.
@MainActor
final class CropView: NSView {
    /// Fired whenever the user adjusts the crop — lets the host enable its Save button.
    var onEdited: (() -> Void)?

    private var image: NSImage?
    private var targetAspect: CGFloat        // width / height
    private var crop: CoverCrop = .full       // normalized, the source of truth

    // Interaction
    private enum Handle { case tl, tr, bl, br }   // corners (view coords: b = bottom, minY)
    private enum Mode { case none, move, resize(Handle) }
    private var mode: Mode = .none
    private var dragStart: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero
    private let handleHit: CGFloat = 18
    private let minCrop: CGFloat = 44          // view-space minimum, so the handles stay grabbable

    init(targetAspect: CGFloat) {
        self.targetAspect = max(0.05, targetAspect)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.Color.surface.cgColor
        layer?.cornerRadius = DS.Radius.tile
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Content

    /// Load a new source image and set the crop to `initial` (or a centered default if nil).
    func setImage(_ image: NSImage?, initialCrop: CoverCrop?) {
        self.image = image
        crop = image != nil ? (initialCrop ?? defaultCrop()) : .full
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Reset the crop to the largest centered rectangle of the target aspect.
    func resetCrop() {
        guard image != nil else { return }
        crop = defaultCrop()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onEdited?()
    }

    /// The current source image (for callers that want to run content-aware analysis on it).
    var sourceImage: NSImage? { image }

    /// The aspect the crop is locked to (width / height).
    var aspect: CGFloat { targetAspect }

    /// Apply an externally-computed crop (e.g. auto-detected), clamped to `[0,1]`.
    func applyCrop(_ newCrop: CoverCrop) {
        guard image != nil else { return }
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        crop = CoverCrop(x: clamp(newCrop.x), y: clamp(newCrop.y),
                         width: clamp(newCrop.width), height: clamp(newCrop.height))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onEdited?()
    }

    /// The current selection as a normalized crop over the source image (top-left origin).
    var normalizedCrop: CoverCrop { crop }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // the crop is normalized, so it just needs re-deriving at the new size
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Geometry

    /// The rect within the view where the image is drawn (aspect-fit, with a small inset margin).
    private func imageFrame() -> CGRect {
        let inset = bounds.insetBy(dx: 14, dy: 14)
        guard let s = image?.size, s.width > 0, s.height > 0,
              inset.width > 0, inset.height > 0 else { return inset }
        let scale = min(inset.width / s.width, inset.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
    }

    /// The selection as a view-space rect, derived from the normalized crop and current image frame.
    private var cropRect: CGRect {
        let f = imageFrame()
        let w = CGFloat(crop.width) * f.width
        let h = CGFloat(crop.height) * f.height
        let x = f.minX + CGFloat(crop.x) * f.width
        let maxY = f.maxY - CGFloat(crop.y) * f.height   // crop.y is measured from the image top
        return CGRect(x: x, y: maxY - h, width: w, height: h)
    }

    /// Convert a view-space rect back to a normalized crop (clamped to `[0,1]`), and store it.
    private func commit(_ r: CGRect) {
        let f = imageFrame()
        guard f.width > 0, f.height > 0 else { return }
        func clamp(_ v: CGFloat) -> Double { Double(max(0, min(1, v))) }
        crop = CoverCrop(
            x: clamp((r.minX - f.minX) / f.width),
            y: clamp((f.maxY - r.maxY) / f.height),
            width: clamp(r.width / f.width),
            height: clamp(r.height / f.height))
    }

    /// The largest centered crop of the target aspect, as normalized coords.
    private func defaultCrop() -> CoverCrop {
        guard let s = image?.size, s.width > 0, s.height > 0 else { return .full }
        var w = s.width, h = w / targetAspect
        if h > s.height { h = s.height; w = h * targetAspect }
        return CoverCrop(x: Double((s.width - w) / 2 / s.width),
                         y: Double((s.height - h) / 2 / s.height),
                         width: Double(w / s.width),
                         height: Double(h / s.height))
    }

    // MARK: - Corners

    private func corner(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: r.minX, y: r.maxY)
        case .tr: return CGPoint(x: r.maxX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.minY)
        case .br: return CGPoint(x: r.maxX, y: r.minY)
        }
    }
    /// The fixed corner opposite the one being dragged (stays anchored during a resize).
    private func anchor(for h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: return corner(.br, in: r)
        case .tr: return corner(.bl, in: r)
        case .bl: return corner(.tr, in: r)
        case .br: return corner(.tl, in: r)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = cropRect
        dragStart = p
        rectAtDragStart = r
        mode = .none
        for h in [Handle.tl, .tr, .bl, .br]
        where hypot(p.x - corner(h, in: r).x, p.y - corner(h, in: r).y) <= handleHit {
            mode = .resize(h); return
        }
        if r.contains(p) { mode = .move }
    }

    override func mouseDragged(with event: NSEvent) {
        guard image != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .none: return
        case .move: commit(movedRect(to: p))
        case .resize(let h): commit(resizedRect(handle: h, to: p))
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onEdited?()
    }

    override func mouseUp(with event: NSEvent) { mode = .none }

    private func movedRect(to p: CGPoint) -> CGRect {
        let f = imageFrame()
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        var r = rectAtDragStart.offsetBy(dx: dx, dy: dy)
        r.origin.x = max(f.minX, min(r.origin.x, f.maxX - r.width))
        r.origin.y = max(f.minY, min(r.origin.y, f.maxY - r.height))
        return r
    }

    private func resizedRect(handle: Handle, to p: CGPoint) -> CGRect {
        let f = imageFrame()
        let a = anchor(for: handle, in: rectAtDragStart)
        let leftSide = (handle == .tl || handle == .bl)   // moving corner is left of the anchor
        let bottomSide = (handle == .bl || handle == .br) // moving corner is below the anchor
        let maxW = leftSide ? (a.x - f.minX) : (f.maxX - a.x)
        let maxH = bottomSide ? (a.y - f.minY) : (f.maxY - a.y)
        // Desired width from the pointer, aspect-locked, clamped to the image and a sensible minimum.
        var w = abs(p.x - a.x)
        w = min(w, maxW, maxH * targetAspect)
        w = max(w, minCrop)
        if w > maxW || w / targetAspect > maxH { w = min(maxW, maxH * targetAspect) }   // tiny frame
        let h = w / targetAspect
        let x = leftSide ? a.x - w : a.x
        let y = bottomSide ? a.y - h : a.y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func resetCursorRects() {
        guard image != nil else { return }
        let r = cropRect
        addCursorRect(r, cursor: .openHand)
        for h in [Handle.tl, .tr, .bl, .br] {
            let c = corner(h, in: r)
            addCursorRect(CGRect(x: c.x - handleHit / 2, y: c.y - handleHit / 2,
                                 width: handleHit, height: handleHit), cursor: .crosshair)
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let image else {
            let msg = DS.Text.plain("No image — choose one below", size: 14, color: DS.Color.textTertiary)
            let sz = msg.size()
            msg.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
            return
        }

        let f = imageFrame()
        image.draw(in: f, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

        let r = cropRect

        // Dim everything outside the crop selection.
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
        ctx.addRect(f)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // Rule-of-thirds grid.
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(1)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()

        // Selection border + corner handles.
        ctx.setStrokeColor(DS.Color.hairlineStrong.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
        ctx.setFillColor(NSColor.white.cgColor)
        for h in [Handle.tl, .tr, .bl, .br] {
            let c = corner(h, in: r)
            ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        }
    }
}
