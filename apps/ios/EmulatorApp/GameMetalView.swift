import SwiftUI
import MetalKit

/// SwiftUI wrapper over an `MTKView` that draws the emulation session's framebuffer through one of
/// three display filters:
///   • **Sharp** — nearest-neighbour, pixel-perfect;
///   • **Smooth** — bilinear;
///   • **LCD** — a physically-modelled GBA panel (Pokefan531/hunterk "Color Mangler" correction +
///     cgwg lcd-grid-v2 subpixel grid + optional interframe ghosting).
///
/// The shader is the same one the macOS app uses (ported verbatim). The `MTKView` is already sized
/// 3:2 by SwiftUI, so no in-shader aspect-fit is needed — a full-screen triangle maps uv→drawable.
struct GameMetalView: UIViewRepresentable {
    let session: EmulationSession
    var filter: DisplayFilter = .sharp
    var lcdBacklit: Bool = true
    var lcdGhosting: Bool = false

    func makeCoordinator() -> GameRenderer {
        GameRenderer(session: session, filter: filter, backlit: lcdBacklit, ghosting: lcdGhosting)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.filter = filter
        context.coordinator.backlit = lcdBacklit
        context.coordinator.ghosting = lcdGhosting
    }
}

final class GameRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var texSize: SIMD2<Float>
        var outSize: SIMD2<Float>
        var lcd: Float
        var backlit: Float
        var ghost: Float
        var _pad: Float = 0
    }

    let device: MTLDevice
    var filter: DisplayFilter
    var backlit: Bool
    var ghosting: Bool

    private let session: EmulationSession
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState
    // Two textures ping-ponged each frame so the LCD path can read the previous frame for ghosting.
    private var texCurrent: MTLTexture
    private var texPrev: MTLTexture
    private var drawableSize: CGSize = .zero

    init(session: EmulationSession, filter: DisplayFilter, backlit: Bool, ghosting: Bool) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        self.session = session
        self.filter = filter
        self.backlit = backlit
        self.ghosting = ghosting
        self.queue = device.makeCommandQueue()!

        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "v_main")
        desc.fragmentFunction = library.makeFunction(name: "f_main")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let ns = MTLSamplerDescriptor(); ns.minFilter = .nearest; ns.magFilter = .nearest
        self.nearest = device.makeSamplerState(descriptor: ns)!
        let ls = MTLSamplerDescriptor(); ls.minFilter = .linear; ls.magFilter = .linear
        self.linear = device.makeSamplerState(descriptor: ls)!

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: session.width, height: session.height, mipmapped: false)
        td.usage = .shaderRead
        self.texCurrent = device.makeTexture(descriptor: td)!
        self.texPrev = device.makeTexture(descriptor: td)!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawableSize = size }

    func draw(in view: MTKView) {
        let region = MTLRegionMake2D(0, 0, session.width, session.height)
        session.withLatestFrame { ptr in
            texCurrent.replace(region: region, mipmapLevel: 0, withBytes: ptr, bytesPerRow: session.width * 4)
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = drawableSize == .zero ? view.drawableSize : drawableSize
        var u = Uniforms(
            texSize: SIMD2(Float(session.width), Float(session.height)),
            outSize: SIMD2(Float(size.width), Float(size.height)),
            lcd: filter == .lcd ? 1 : 0,
            backlit: backlit ? 1 : 0,
            ghost: (filter == .lcd && ghosting) ? 1 : 0)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texCurrent, index: 0)
        enc.setFragmentTexture(texPrev, index: 1)
        // LCD reconstructs its own grid from crisp texels (nearest); Smooth uses bilinear.
        enc.setFragmentSamplerState(filter == .smooth ? linear : nearest, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        swap(&texCurrent, &texPrev)   // this frame becomes next frame's "previous" for ghosting
    }

    /// Ported verbatim from the macOS `Renderer` so iOS renders identically.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    struct Uniforms {
        float2 texSize;
        float2 outSize;
        float lcd;
        float backlit;
        float ghost;
        float _pad;
    };

    vertex VOut v_main(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y); // flip Y: texture row 0 at top of screen
        return o;
    }

    // --- GBA color correction: Pokefan531 / hunterk "Color Mangler" (public domain) ---
    static float3 gba_color(float3 s, float darken) {
        float3 v = pow(s, float3(2.2 + darken));
        v = clamp(v * 0.94, 0.0, 1.0);
        float3 o;
        o.r = 0.820 * v.r + 0.240 * v.g - 0.060 * v.b;
        o.g = 0.125 * v.r + 0.665 * v.g + 0.210 * v.b;
        o.b = 0.195 * v.r + 0.075 * v.g + 0.730 * v.b;
        return pow(o, float3(1.0 / 2.2));
    }

    // --- cgwg lcd-grid-v2 subpixel reconstruction (public domain) ---
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

    static float3 fetch_offset(texture2d<float> tex, texture2d<float> prevTex,
                               int2 coord, int2 offset, float2 texSize,
                               float ghost, float darken) {
        int2 c = clamp(coord + offset, int2(0), int2(texSize) - 1);
        float3 raw = tex.read(uint2(c)).rgb;
        if (ghost > 0.5) raw = mix(prevTex.read(uint2(c)).rgb, raw, 0.5);
        float3 col = gba_color(raw, darken);
        const float gain = 1.0, blacklevel = 0.05, gamma = 3.0;
        return pow(gain * col + float3(blacklevel), float3(gamma));
    }

    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           texture2d<float> prevTex [[texture(1)]],
                           sampler s [[sampler(0)]],
                           constant Uniforms &u [[buffer(0)]]) {
        if (u.lcd < 0.5) return tex.sample(s, in.uv);

        const float outgamma = 2.2;
        float darken = u.backlit > 0.5 ? 0.0 : 1.0;
        float2 uv = in.uv;
        float2 texelSize = 1.0 / u.texSize;
        float2 range = 1.0 / u.outSize;

        int2 tli = int2(floor(uv / texelSize - float2(0.4999)));

        float subpix = (uv.x / texelSize.x - 0.4999 - float(tli.x)) * 3.0;
        float rsubpix = range.x / texelSize.x * 3.0;
        float3 lcol = float3(intsmear(subpix + 1.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix,       rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 1.0, rsubpix, 1.5, coeffs_x));
        float3 rcol = float3(intsmear(subpix - 2.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 3.0, rsubpix, 1.5, coeffs_x),
                             intsmear(subpix - 4.0, rsubpix, 1.5, coeffs_x));

        float subpiy = uv.y / texelSize.y - 0.4999 - float(tli.y);
        float rsubpiy = range.y / texelSize.y;
        float tcol = intsmear(subpiy,       rsubpiy, 0.63, coeffs_y);
        float bcol = intsmear(subpiy - 1.0, rsubpiy, 0.63, coeffs_y);

        float3 tl = fetch_offset(tex, prevTex, tli, int2(0, 0), u.texSize, u.ghost, darken) * lcol * tcol;
        float3 br = fetch_offset(tex, prevTex, tli, int2(1, 1), u.texSize, u.ghost, darken) * rcol * bcol;
        float3 bl = fetch_offset(tex, prevTex, tli, int2(0, 1), u.texSize, u.ghost, darken) * lcol * bcol;
        float3 tr = fetch_offset(tex, prevTex, tli, int2(1, 0), u.texSize, u.ghost, darken) * rcol * tcol;

        float3 avg = tl + br + bl + tr;
        return float4(pow(avg, float3(1.0 / outgamma)), 1.0);
    }
    """
}
