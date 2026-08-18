import AppKit
import ImageIO
import LibraryKit
import UniformTypeIdentifiers

/// Disk layout + pixel work for per-game cover editing. Three files can exist per game hash under
/// `AppPaths.coversDir`:
///   • `<hash>.png`        — the plain downloaded box art (written by `CoverArtService`).
///   • `<hash>-source.png` — a user-chosen source image, when they replaced the art.
///   • `<hash>-cover.png`  — the rendered, cropped cover actually drawn on the cartridge.
/// Sources are never mutated, so a crop can always be redone (or reverted to the downloaded art).
enum CoverImaging {
    static func downloadedURL(hash: String) -> URL {
        AppPaths.coversDir.appendingPathComponent("\(hash).png")
    }
    static func customSourceURL(hash: String) -> URL {
        AppPaths.coversDir.appendingPathComponent("\(hash)-source.png")
    }
    static func displayURL(hash: String) -> URL {
        AppPaths.coversDir.appendingPathComponent("\(hash)-cover.png")
    }

    /// True when a plain downloaded box art exists to revert to.
    static func hasDownloadedArt(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: downloadedURL(hash: hash).path)
    }

    // MARK: - Load

    static func cgImage(atPath path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Import a chosen image as a game's source

    /// Copy the user-picked image into `<hash>-source.png` (re-encoded as PNG so the format is
    /// predictable). Returns the stored path, or nil if the file couldn't be read as an image.
    static func importSource(from url: URL, hash: String) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let dest = customSourceURL(hash: hash)
        guard writePNG(image, to: dest) else { return nil }
        return dest.path
    }

    // MARK: - Render the cropped cover

    /// Crop `sourcePath` by the normalized `crop` and write the result to `<hash>-cover.png`. Returns
    /// the output path, or nil on failure.
    static func renderCrop(sourcePath: String, crop: CoverCrop, hash: String) -> String? {
        guard let image = cgImage(atPath: sourcePath) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Map the [0,1] crop onto pixels (top-left origin, matching CGImage), clamped to the image.
        var rect = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h)
            .integral
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else { return nil }
        let dest = displayURL(hash: hash)
        guard writePNG(cropped, to: dest) else { return nil }
        return dest.path
    }

    // MARK: - Encode

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
