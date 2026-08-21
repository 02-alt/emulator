import EmulatorCore
import Foundation
import Metal
import MetalKit

/// Displays the driver's latest framebuffer in an MTKView: uploads the RGBA8888 pixels to a
/// texture and blits a full-screen triangle, letterboxed to preserve the GBA's 3:2 aspect ratio.
/// Sampling is picked per frame from the "Display Filter" setting: **Sharp** (nearest-neighbor —
/// crisp, unfiltered), **Smooth** (bilinear), or **LCD** — a physically-modelled Game Boy Advance
/// panel that runs the framebuffer through the community-standard GBA color correction (Pokefan531 /
/// hunterk "Color Mangler"), the cgwg `lcd-grid-v2` subpixel grid, and optional interframe blending
/// for the panel's characteristic ghosting.
/// It does NOT run the core — the emulation thread does that; the renderer only presents frames.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    /// Uniforms handed to the fragment shader — must match `struct Uniforms` in the Metal source.
    /// Shared with ``LCDPreviewRenderer`` so the Settings preview stays byte-identical.
    struct Uniforms {
        var texSize: SIMD2<Float>   // framebuffer size (240×160)
        var outSize: SIMD2<Float>   // on-screen size of the fitted image, in pixels
        var lcd: Float              // 1 = LCD panel path, 0 = plain sampled passthrough
        var backlit: Float          // LCD only: 1 = bright SP (AGS-101), 0 = dim original GBA
        var ghost: Float            // LCD only: 1 = blend with the previous frame
        var _pad: Float = 0
    }

    private let driver: EmulationDriver
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState   // Sharp / LCD — crisp texel fetches
    private let linearSampler: MTLSamplerState    // Smooth — bilinear softening
    /// Two textures ping-ponged each frame so the LCD path can read the previous frame for ghosting.
    private let textures: [MTLTexture]
    private var writeIndex = 0
    private let bytesPerRow: Int
    private var frameBuffer: [UInt32]

    /// When set, pins the display filter for this surface regardless of the global setting — used by the
    /// per-game filter override. `nil` falls back to `Settings.shared.displayFilter`.
    var filterOverride: Settings.DisplayFilter?

    /// Total frames actually presented to the screen. Sampled over time by the stats overlay to show
    /// the on-screen draw rate (distinct from the emulation rate the driver reports).
    private(set) var presentedFrames = 0

    init(driver: EmulationDriver, view: MTKView) {
        self.driver = driver
        self.frameBuffer = [UInt32](repeating: 0, count: driver.width * driver.height)
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device")
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else { fatalError("No command queue") }
        self.commandQueue = queue

        // Shaders compiled at runtime from source — no .metallib/bundle plumbing needed.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "v_main")
        desc.fragmentFunction = library.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }

        // Two samplers so the "Display Filter" setting can switch crispness live, per frame.
        let sd = MTLSamplerDescriptor()
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sd.minFilter = .nearest; sd.magFilter = .nearest
        guard let nearest = device.makeSamplerState(descriptor: sd) else {
            fatalError("Sampler creation failed")
        }
        sd.minFilter = .linear; sd.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sd) else {
            fatalError("Sampler creation failed")
        }
        self.nearestSampler = nearest
        self.linearSampler = linear

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: driver.width, height: driver.height, mipmapped: false)
        td.usage = [.shaderRead]
        self.textures = (0..<2).map { _ in
            guard let t = device.makeTexture(descriptor: td) else { fatalError("Texture creation failed") }
            return t
        }
        self.bytesPerRow = driver.width * MemoryLayout<UInt32>.size

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        driver.copyLatestFrame(into: &frameBuffer)

        // Ping-pong: upload the new frame into one texture; the other still holds the previous frame
        // (for LCD ghosting). Flip after presenting so next frame reads this one as its "previous".
        let current = textures[writeIndex]
        let previous = textures[1 - writeIndex]
        frameBuffer.withUnsafeBytes { raw in
            current.replace(
                region: MTLRegionMake2D(0, 0, driver.width, driver.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow)
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let viewport = aspectFitViewport(drawableSize: view.drawableSize)
        let filter = filterOverride ?? Settings.shared.displayFilter
        let isLCD = filter == .lcd

        var uniforms = Uniforms(
            texSize: SIMD2(Float(driver.width), Float(driver.height)),
            outSize: SIMD2(Float(viewport.width), Float(viewport.height)),
            lcd: isLCD ? 1 : 0,
            backlit: Settings.shared.lcdBacklit ? 1 : 0,
            ghost: Settings.shared.lcdGhosting ? 1 : 0)

        enc.setViewport(viewport)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(current, index: 0)
        enc.setFragmentTexture(previous, index: 1)
        // LCD reconstructs its own grid from crisp texels, so it wants nearest; Smooth is the only
        // path that softens with bilinear.
        let sampler = filter == .smooth ? linearSampler : nearestSampler
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        presentedFrames += 1
        writeIndex = 1 - writeIndex
    }

    /// Centered viewport preserving the GBA 3:2 aspect ratio (letterbox/pillarbox).
    private func aspectFitViewport(drawableSize: CGSize) -> MTLViewport {
        let target = Double(driver.width) / Double(driver.height)
        let dw = Double(drawableSize.width)
        let dh = Double(drawableSize.height)
        var vw = dw
        var vh = dw / target
        if vh > dh { vh = dh; vw = dh * target }
        return MTLViewport(
            originX: (dw - vw) / 2, originY: (dh - vh) / 2,
            width: vw, height: vh, znear: 0, zfar: 1)
    }

    /// The Metal source for the display pipeline — shared with ``LCDPreviewRenderer`` so the Settings
    /// preview renders through the exact same shader the play window uses.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    struct Uniforms {
        float2 texSize;   // framebuffer size (240x160)
        float2 outSize;   // on-screen size of the fitted image, in pixels
        float lcd;        // 1 = LCD panel path, 0 = plain sampled passthrough
        float backlit;    // LCD only: 1 = bright SP (AGS-101), 0 = dim original GBA
        float ghost;      // LCD only: 1 = blend with the previous frame
        float _pad;
    };

    vertex VOut v_main(uint vid [[vertex_id]]) {
        // Full-screen triangle from vertex id; uv in [0,2].
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y); // flip Y: texture row 0 at top of screen
        return o;
    }

    // --- GBA color correction: Pokefan531 / hunterk "Color Mangler" (public domain) ---
    // Reproduces the AGB panel's washed, warm, low-saturation response. `darken` is the shader's
    // "Darken Screen" knob: ~1.0 = dim non-backlit original, ~0.0 = bright backlit SP (AGS-101).
    static float3 gba_color(float3 s, float darken) {
        float3 v = pow(s, float3(2.2 + darken));  // to linear-ish, with the darken bias
        v = clamp(v * 0.94, 0.0, 1.0);            // luminance
        float3 o;                                 // channel bleed matrix (sat = 1)
        o.r = 0.820 * v.r + 0.240 * v.g - 0.060 * v.b;
        o.g = 0.125 * v.r + 0.665 * v.g + 0.210 * v.b;
        o.b = 0.195 * v.r + 0.075 * v.g + 0.730 * v.b;
        return pow(o, float3(1.0 / 2.2));         // re-encode to display gamma
    }

    // --- cgwg lcd-grid-v2 subpixel reconstruction (public domain) ---
    // Integrals of the subpixel smear profiles, x horizontal / y vertical.
    constant float coeffs_x[7] = { 1.0, -2.0/3.0, -1.0/5.0, 4.0/7.0, -1.0/9.0, -2.0/11.0, 1.0/13.0 };
    constant float coeffs_y[7] = { 1.0,      0.0, -4.0/5.0, 2.0/7.0,  4.0/9.0, -4.0/11.0, 1.0/13.0 };

    static float intsmear_func(float z, constant float *c) {
        float z2 = z * z, zn = z, ret = 0.0;
        for (int i = 0; i < 7; i++) { ret += zn * c[i]; zn *= z2; }
        return ret;
    }
    static float intsmear(float x, float dx, float d, constant float *c) {
        float zl = clamp((x - dx * 0.5) / d, -1.0, 1.0);
        float zh = clamp((x + dx * 0.5) / d, -1.0, 1.0);
        return d * (intsmear_func(zh, c) - intsmear_func(zl, c)) / dx;
    }

    // One source texel — color-corrected, optionally ghost-blended, then taken to LCD input gamma.
    static float3 fetch_offset(texture2d<float> tex, texture2d<float> prevTex,
                               int2 coord, int2 offset, float2 texSize,
                               float ghost, float darken) {
        int2 c = clamp(coord + offset, int2(0), int2(texSize) - 1);
        float3 raw = tex.read(uint2(c)).rgb;
        if (ghost > 0.5) raw = mix(prevTex.read(uint2(c)).rgb, raw, 0.5);   // interframe blend
        float3 col = gba_color(raw, darken);
        const float gain = 1.0, blacklevel = 0.05, gamma = 3.0;            // LCD input transfer
        return pow(gain * col + float3(blacklevel), float3(gamma));
    }

    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           texture2d<float> prevTex [[texture(1)]],
                           sampler s [[sampler(0)]],
                           constant Uniforms &u [[buffer(0)]]) {
        if (u.lcd < 0.5) return tex.sample(s, in.uv);   // Sharp / Smooth: sampler does the work

        const float outgamma = 2.2;
        float darken = u.backlit > 0.5 ? 0.0 : 1.0;
        float2 uv = in.uv;
        float2 texelSize = 1.0 / u.texSize;
        float2 range = 1.0 / u.outSize;                 // texels covered per output pixel

        int2 tli = int2(floor(uv / texelSize - float2(0.4999)));

        // Horizontal RGB subpixel weights for the left and right source columns.
        float subpix = (uv.x / texelSize.x - 0.4999 - float(tli.x)) * 3.0;
        float rsubpix = range.x / texelSize.x * 3.0;
        float3 lcol = float3(intsmear(subpix + 1.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix,       rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 1.0, rsubpix, 1.5, coeffs_x));
        float3 rcol = float3(intsmear(subpix - 2.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 3.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 4.0, rsubpix, 1.5, coeffs_x));

        // Vertical row weights (top / bottom).
        float subpiy = uv.y / texelSize.y - 0.4999 - float(tli.y);
        float rsubpiy = range.y / texelSize.y;
        float tcol = intsmear(subpiy,       rsubpiy, 0.63, coeffs_y);
        float bcol = intsmear(subpiy - 1.0, rsubpiy, 0.63, coeffs_y);

        float3 tl = fetch_offset(tex, prevTex, tli, int2(0, 0), u.texSize, u.ghost, darken) * lcol * tcol;
        float3 br = fetch_offset(tex, prevTex, tli, int2(1, 1), u.texSize, u.ghost, darken) * rcol * bcol;
        float3 bl = fetch_offset(tex, prevTex, tli, int2(0, 1), u.texSize, u.ghost, darken) * lcol * bcol;
        float3 tr = fetch_offset(tex, prevTex, tli, int2(1, 0), u.texSize, u.ghost, darken) * rcol * tcol;

        float3 avg = tl + br + bl + tr;                 // default RGB subpixel primaries = identity
        return float4(pow(avg, float3(1.0 / outgamma)), 1.0);
    }
    """
}
