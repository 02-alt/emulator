import SwiftUI
import Vision
import LibraryKit

/// A pan/zoom cropper for a game's cover art. The crop window is fixed at the cartridge label's
/// aspect (`GBACartridgeView.labelAspect`); the player drags to pan and pinches to zoom the source
/// behind it, or taps **Auto** to let Vision frame the box art's subject. The result is a normalized
/// `CoverCrop` (top-left origin) applied non-destructively at display time — the source image is
/// never modified, so the crop can always be redone.
struct CoverCropEditor: View {
    let image: UIImage
    let initial: CoverCrop?
    /// The cart the crop is authored for — sets the crop window's aspect (GBA landscape, Game Boy square).
    var system: GameSystem = .gba
    let onSave: (CoverCrop) -> Void

    @Environment(\.dismiss) private var dismiss

    // Crop model: a center in [0,1] plus a normalized width; the height is derived so the crop always
    // holds the label aspect (so it fills the window without distortion).
    @State private var cx: CGFloat = 0.5
    @State private var cy: CGFloat = 0.5
    @State private var nw: CGFloat = 1
    @State private var dragBase: CGPoint?
    @State private var zoomBase: CGFloat?

    private let windowWidth: CGFloat = 300

    private var aspect: CGFloat { CartridgeView.labelAspect(for: system) }
    private var imgAspect: CGFloat { image.size.width / max(1, image.size.height) }
    /// Height that holds the label aspect for the current width.
    private var nh: CGFloat { min(1, nw * imgAspect / aspect) }
    /// Widest crop that still fits (height ≤ 1) — this centered is the plain aspect-fill framing.
    private var maxNW: CGFloat { min(1, aspect / imgAspect) }
    private var minNW: CGFloat { maxNW * 0.35 }

    private var crop: CoverCrop {
        let w = nw, h = nh
        let x = min(max(cx - w / 2, 0), 1 - w)
        let y = min(max(cy - h / 2, 0), 1 - h)
        return CoverCrop(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Drag to pan · pinch to zoom")
                    .font(DS.mono(12)).foregroundStyle(DS.textSecondary)

                cropWindow

                HStack(spacing: 12) {
                    Button { autoFrame() } label: {
                        Label("Auto", systemImage: "wand.and.stars")
                    }
                    Button { reset() } label: {
                        Label("Center", systemImage: "arrow.counterclockwise")
                    }
                }
                .font(DS.mono(13, .medium))
                .tint(.green)

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background)
            .navigationTitle("Frame Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(crop); dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear(perform: syncFromInitial)
        }
        .preferredColorScheme(.dark)
    }

    private var cropWindow: some View {
        let size = CGSize(width: windowWidth, height: windowWidth / aspect)
        return preview(size: size)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(dragGesture(window: size))
            .simultaneousGesture(zoomGesture)
    }

    /// The live crop, rendered with the same scale/offset math `GBACartridgeView` uses at display time.
    private func preview(size: CGSize) -> some View {
        let iw = image.size.width, ih = image.size.height
        let c = crop
        let scale = size.width / (CGFloat(c.width) * iw)
        return Image(uiImage: image)
            .resizable()
            .frame(width: iw * scale, height: ih * scale)
            .offset(x: -CGFloat(c.x) * iw * scale, y: -CGFloat(c.y) * ih * scale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - Gestures

    private func dragGesture(window: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragBase == nil { dragBase = CGPoint(x: cx, y: cy) }
                guard let base = dragBase else { return }
                cx = clampX(base.x - (value.translation.width / window.width) * nw)
                cy = clampY(base.y - (value.translation.height / window.height) * nh)
            }
            .onEnded { _ in dragBase = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomBase == nil { zoomBase = nw }
                guard let base = zoomBase else { return }
                nw = min(maxNW, max(minNW, base / value.magnification))
                cx = clampX(cx); cy = clampY(cy)   // re-fit the center for the new crop size
            }
            .onEnded { _ in zoomBase = nil }
    }

    private func clampX(_ x: CGFloat) -> CGFloat { min(max(x, nw / 2), 1 - nw / 2) }
    private func clampY(_ y: CGFloat) -> CGFloat { min(max(y, nh / 2), 1 - nh / 2) }

    // MARK: - Actions

    private func syncFromInitial() {
        if let c = initial, c != .full {
            adopt(x: CGFloat(c.x), y: CGFloat(c.y), w: CGFloat(c.width), h: CGFloat(c.height))
        } else {
            reset()
        }
    }

    private func reset() { nw = maxNW; cx = 0.5; cy = 0.5 }

    /// Vision attention-based saliency → the largest label-aspect crop around the box art's subject.
    private func autoFrame() {
        guard let cg = image.cgImage, let c = CoverAutoCrop.bestCrop(for: cg, targetAspect: aspect) else { return }
        adopt(x: CGFloat(c.x), y: CGFloat(c.y), w: CGFloat(c.width), h: CGFloat(c.height))
    }

    private func adopt(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        nw = min(maxNW, max(minNW, w))
        cx = clampX(x + w / 2)
        cy = clampY(y + h / 2)
    }
}

/// Content-aware "best crop" via Vision saliency — the iOS port of the macOS `CoverAutoCrop`. Finds
/// the region the eye is drawn to (subject/logo) and frames the largest `targetAspect` rectangle
/// around it. Returns nil when saliency finds nothing, so the caller keeps the centered default.
enum CoverAutoCrop {
    static func bestCrop(for image: CGImage, targetAspect: CGFloat) -> CoverCrop? {
        guard targetAspect > 0, let salient = saliencyRect(for: image) else { return nil }
        return fit(salient: salient, aspect: targetAspect)
    }

    /// Union of Vision's salient-object boxes, normalized with a **top-left** origin (matching CoverCrop).
    private static func saliencyRect(for image: CGImage) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects, !objects.isEmpty else { return nil }
        var box = objects[0].boundingBox
        for object in objects.dropFirst() { box = box.union(object.boundingBox) }
        // Vision boxes use a bottom-left origin; flip y.
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private static func fit(salient: CGRect, aspect: CGFloat, minSize: CGFloat = 0.5) -> CoverCrop {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let padded = salient.insetBy(dx: -0.06, dy: -0.06).intersection(unit)
        let region = padded.isNull ? salient : padded

        var w = region.width, h = region.height
        if w / h > aspect { h = w / aspect } else { w = h * aspect }

        w = max(w, minSize); h = w / aspect
        if h < minSize { h = minSize; w = h * aspect }
        if w > 1 { w = 1; h = w / aspect }
        if h > 1 { h = 1; w = h * aspect }

        var x = region.midX - w / 2
        var y = region.midY - h / 2
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        return CoverCrop(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }
}
