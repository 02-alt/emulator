#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// A single hue (0…1) as RGB — the classic piecewise ramp, no saturation/value handling needed since
// the fringe is tinted pastel afterwards.
static half3 hue2rgb(float h) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return half3(clamp(float3(r, g, b), 0.0, 1.0));
}

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// A CD/DVD-style iridescent sheen, added directly onto the cartridge's own pixels (via SwiftUI
/// `.colorEffect`). `color` is the cart's premultiplied colour, `size` the view size in points, `tilt`
/// the −1…1 device lean, `time` a wrapped seconds value for the sparkle. Light is composited additively
/// and scaled by the cart's own alpha, so it never spills past the silhouette.
[[ stitchable ]]
half4 plasticSheen(float2 position, half4 color, float2 size, float2 tilt, float time) {
    float2 uv = position / size;

    // Diffraction pattern radiates from a centre that drifts with the lean. Aspect-correct so the
    // rainbow fans out in round arcs on the wide cart instead of stretched ellipses.
    float2 c = float2(0.5) + tilt * 0.32;
    float2 v = (uv - c);
    v.x *= size.x / size.y;
    float r = length(v);
    float a = atan2(v.y, v.x);                                  // −π…π around the centre

    // The spectral colour of an optical disc sweeps around the surface (angular) and cycles through
    // the radius (the concentric grooves), the whole field panning as the disc is tilted. Doubling
    // the angular term gives the tell-tale crossed "X" of spectra.
    float hue = fract(a / (2.0 * M_PI_F) * 2.0 + r * 1.5 + tilt.x * 0.6 + tilt.y * 0.35);
    half3 spectrum = mix(hue2rgb(hue), half3(1.0h), 0.18h);      // vivid, barely softened

    // Broad soft rays fanning from the centre (a rotating two-lobe cross), faded near the hub and rim
    // so the colour lives in a mid-band like a real disc.
    float rays = 0.55 + 0.45 * cos(a * 2.0 - tilt.x * 3.0 - tilt.y * 1.5);
    float band = smoothstep(0.04, 0.30, r) * smoothstep(1.15, 0.45, r);
    float irid = rays * band;

    // A bright specular sweep near the light, the silver glint over the rainbow.
    float d = distance(uv, float2(0.5) + tilt * 0.5);
    float glare = pow(smoothstep(0.72, 0.0, d), 1.8);

    // Faint sparkle, only where the surface is already lit.
    float2 cell = floor(uv * 90.0);
    float seed = hash21(cell);
    float twinkle = smoothstep(0.988, 1.0, seed) * (0.5 + 0.5 * sin(time * 3.0 + seed * 30.0));
    float sparkle = twinkle * max(glare, irid * 0.6);

    // Real iridescence only flares as the disc angles into the light: faint flat-on, blooming at a lean.
    float bloom = 0.30 + 0.70 * smoothstep(0.0, 0.7, clamp(length(tilt), 0.0, 1.0));

    half3 white = half3(1.0h);
    half3 sheen = spectrum * half(irid * 0.55)
                + white * half(glare * 0.35)
                + white * half(sparkle * 0.5);
    sheen *= half(bloom);

    // Additive, confined to the cart by its own coverage; keep the original alpha.
    return half4(color.rgb + sheen * color.a, color.a);
}
