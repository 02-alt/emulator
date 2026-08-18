import CoreGraphics
import LibraryKit
import Vision

/// Content-aware "best crop" for a cover image. Uses Vision's attention-based saliency to find the
/// region a person's eye is drawn to (the box art's subject/logo), then frames the largest
/// cartridge-aspect rectangle around it — so the label shows the interesting part instead of a
/// blindly-centered slice. Falls back to `nil` when saliency finds nothing, letting the caller keep
/// the plain centered default.
enum CoverAutoCrop {
    /// Compute a suggested crop of `targetAspect` (width / height) over `image`. Returns a normalized
    /// `CoverCrop` (top-left origin, matching CGImage), or nil if no salient region was found.
    static func bestCrop(for image: CGImage, targetAspect: CGFloat) -> CoverCrop? {
        guard targetAspect > 0, let salient = saliencyRect(for: image) else { return nil }
        return fit(salient: salient, aspect: targetAspect)
    }

    /// The union of Vision's salient-object boxes, as a normalized rect with a **top-left** origin.
    private static func saliencyRect(for image: CGImage) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects, !objects.isEmpty else { return nil }
        var box = objects[0].boundingBox
        for object in objects.dropFirst() { box = box.union(object.boundingBox) }
        // Vision boxes are normalized with a bottom-left origin; flip y to match CoverCrop.
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Frame the smallest `aspect` rectangle that contains the (padded) salient region, centered on
    /// it, then clamp inside the image. Never crops tighter than `minSize` so a small subject doesn't
    /// zoom in absurdly.
    private static func fit(salient: CGRect, aspect: CGFloat, minSize: CGFloat = 0.5) -> CoverCrop {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let padded = salient.insetBy(dx: -0.06, dy: -0.06).intersection(unit)
        let region = padded.isNull ? salient : padded

        // Smallest aspect-locked rect that covers the salient region.
        var w = region.width, h = region.height
        if w / h > aspect { h = w / aspect } else { w = h * aspect }

        // Enforce a floor, then cap to the image while preserving aspect.
        w = max(w, minSize); h = w / aspect
        if h < minSize { h = minSize; w = h * aspect }
        if w > 1 { w = 1; h = w / aspect }
        if h > 1 { h = 1; w = h * aspect }

        // Center on the salient region, then slide fully inside [0, 1].
        var x = region.midX - w / 2
        var y = region.midY - h / 2
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        return CoverCrop(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }
}
