import AppKit
import Metal
import MetalKit
import QuartzCore

/// A small, self-contained live preview of the "Display Filter" setting, shown in Settings. It runs
/// an animated procedural sample scene (a gradient sky, a moving sun, primary-color swatches and a
/// fine checker) through the **exact same shader** the play window uses (``Renderer/shaderSource``),
/// reading ``Settings`` every frame — so switching Sharp / Smooth / LCD and toggling Backlit /
/// Ghosting all show their effect immediately. The moving sun leaves a ghost trail when LCD ghosting
/// is on, which is otherwise invisible on a still image.
final class LCDPreviewView: NSView {
    private let mtkView = MTKView()
    private var renderer: LCDPreviewRenderer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.tile
        layer?.masksToBounds = true
        layer?.borderWidth = DS.Stroke.hairline
        layer?.borderColor = DS.Color.hairline.cgColor

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        mtkView.device = device
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.layer?.cornerRadius = DS.Radius.tile
        mtkView.preferredFramesPerSecond = 30
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        let r = LCDPreviewRenderer(device: device, view: mtkView)
        mtkView.delegate = r
        self.renderer = r

        addSubview(mtkView)
        NSLayoutConstraint.activate([
            // 3:2, matching the GBA — no letterbox needed inside the preview.
            widthAnchor.constraint(equalToConstant: 300),
            heightAnchor.constraint(equalToConstant: 200),
            mtkView.topAnchor.constraint(equalTo: topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Drives ``LCDPreviewView``: fills a 240×160 sample framebuffer each frame and presents it through
/// the shared display shader, honoring the live ``Settings`` (filter + LCD knobs). Mirrors the
/// relevant bits of ``Renderer`` (two samplers, ping-pong textures for ghosting, matching uniforms).
@MainActor
final class LCDPreviewRenderer: NSObject, MTKViewDelegate {
    private static let w = 240, h = 160

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private let textures: [MTLTexture]
    private var writeIndex = 0
    private var frame = [UInt32](repeating: 0, count: w * h)
    private let start = CACurrentMediaTime()

    init(device: MTLDevice, view: MTKView) {
        guard let queue = device.makeCommandQueue() else { fatalError("No command queue") }
        self.commandQueue = queue

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Renderer.shaderSource, options: nil) }
        catch { fatalError("Preview shader compile failed: \(error)") }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "v_main")
        desc.fragmentFunction = library.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do { self.pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { fatalError("Preview pipeline creation failed: \(error)") }

        let sd = MTLSamplerDescriptor()
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sd.minFilter = .nearest; sd.magFilter = .nearest
        guard let nearest = device.makeSamplerState(descriptor: sd) else { fatalError("Sampler") }
        sd.minFilter = .linear; sd.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sd) else { fatalError("Sampler") }
        self.nearestSampler = nearest; self.linearSampler = linear

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.w, height: Self.h, mipmapped: false)
        td.usage = [.shaderRead]
        self.textures = (0..<2).map { _ in
            guard let t = device.makeTexture(descriptor: td) else { fatalError("Texture") }
            return t
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t = CACurrentMediaTime() - start
        fillSample(into: &frame, time: t)

        let current = textures[writeIndex]
        let previous = textures[1 - writeIndex]
        frame.withUnsafeBytes { raw in
            current.replace(region: MTLRegionMake2D(0, 0, Self.w, Self.h), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: Self.w * 4)
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let filter = Settings.shared.displayFilter
        var uniforms = Renderer.Uniforms(
            texSize: SIMD2(Float(Self.w), Float(Self.h)),
            outSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            lcd: filter == .lcd ? 1 : 0,
            backlit: Settings.shared.lcdBacklit ? 1 : 0,
            ghost: Settings.shared.lcdGhosting ? 1 : 0)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(current, index: 0)
        enc.setFragmentTexture(previous, index: 1)
        enc.setFragmentSamplerState(filter == .smooth ? linearSampler : nearestSampler, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Renderer.Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        writeIndex = 1 - writeIndex
    }

    // MARK: - Sample scene

    /// A colorful 240×160 test scene: a graded sky, a furrowed green ground, a row of primary-color
    /// swatches (to read the color correction), a fine checker patch (to read the subpixel grid), and
    /// a bright sun sweeping left↔right (to read the ghosting trail).
    private func fillSample(into buf: inout [UInt32], time: Double) {
        @inline(__always) func px(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
            let ri = UInt32(max(0, min(255, r))); let gi = UInt32(max(0, min(255, g)))
            let bi = UInt32(max(0, min(255, b)))
            return ri | (gi << 8) | (bi << 16) | (0xFF << 24)
        }
        @inline(__always) func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

        let sunX = 120.0 + 92.0 * sin(time * 1.25)
        let sunY = 44.0
        let swatches: [(Double, Double, Double)] = [
            (220, 40, 40), (40, 200, 70), (50, 90, 230), (235, 205, 40),
            (210, 60, 200), (40, 205, 210), (240, 240, 240), (235, 180, 150),
        ]

        for y in 0..<Self.h {
            for x in 0..<Self.w {
                var r: Double, g: Double, b: Double
                if y < 96 {                                   // sky, top ~60%
                    let f = Double(y) / 96.0
                    r = lerp(66, 150, f); g = lerp(128, 206, f); b = lerp(226, 240, f)
                } else {                                      // ground
                    r = 42; g = 150; b = 70
                    if (y - 96) % 11 == 0 { r = 28; g = 112; b = 52 }   // furrows
                }

                // Primary-color swatch row near the top (reads the color correction).
                if y >= 8 && y < 26 {
                    let idx = (x - 8) / 26
                    if x >= 8, idx >= 0, idx < swatches.count, (x - 8) % 26 < 22 {
                        (r, g, b) = swatches[idx]
                    }
                }

                // Fine 2px checker patch, bottom-right (reads the subpixel grid clearly).
                if x >= 196 && y >= 112 {
                    let on = (((x - 196) / 2) + ((y - 112) / 2)) % 2 == 0
                    r = on ? 235 : 20; g = on ? 235 : 20; b = on ? 235 : 20
                }

                // Bright sun with a soft falloff (moving → ghost trail when ghosting is on).
                let dx = Double(x) - sunX, dy = Double(y) - sunY
                let d = (dx * dx + dy * dy).squareRoot()
                if d < 20 {
                    let k = max(0, 1 - d / 20) * (d < 12 ? 1 : 0.7)
                    r = lerp(r, 255, k); g = lerp(g, 244, k); b = lerp(b, 190, k)
                }

                buf[y * Self.w + x] = px(r, g, b)
            }
        }
    }
}
