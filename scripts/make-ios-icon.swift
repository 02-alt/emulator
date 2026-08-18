import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Flatten the shared brand icon (icon/master-1024.png — a free-form macOS icon with transparency)
// onto an opaque 1024² square for the iOS app icon (iOS requires no alpha; the system applies the
// rounded-rect mask). Usage: swift make-ios-icon.swift <master.png> <out.png>

let master = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])

guard let src = CGImageSourceCreateWithURL(master as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("could not load \(master.path)")
}

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}
let F = CGFloat(S)

// Opaque near-black background (matches the icon's dark body; pure black reads as a hole).
ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: F, height: F))

// Draw the master slightly enlarged so the device fills the frame under the iOS mask (trims the
// transparent padding the free-form macOS icon carries).
let scale: CGFloat = 1.12
let w = F * scale, h = F * scale
ctx.interpolationQuality = .high
ctx.draw(image, in: CGRect(x: (F - w) / 2, y: (F - h) / 2, width: w, height: h))

guard let result = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("output")
}
CGImageDestinationAddImage(dest, result, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
