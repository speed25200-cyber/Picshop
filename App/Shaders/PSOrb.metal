// Picshop Live's orb as one SwiftUI colour effect (W2, D19): a soft spectral sphere. Four colour lobes turn
// around the centre at time × 0.35, the radius breathes with the voice level, a specular highlight sits at the
// top left, and the alpha falls off at the edge. Compiled into the app's default library (project.yml's
// `path: App`); LiveOrb uses it through `ShaderLibrary.default.psOrb` only when `metalOrb` is on and the
// library has the function (OrbShader.isAvailable).
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// One lobe's weight at `p`: a Gaussian around `centre`.
static float lobe(float2 p, float2 centre, float spread) {
    float2 d = p - centre;
    return exp(-spread * dot(d, d));
}

[[ stitchable ]] half4 psOrb(float2 position, half4 color, float2 size, float time, float level,
                             half4 c0, half4 c1, half4 c2, half4 c3) {
    // Centred, −1 … 1 across the shorter side.
    float side = max(1.0, min(size.x, size.y));
    float2 p = (position - size * 0.5) / (side * 0.5);
    float r = length(p);

    // The radius breathes with the level (0 … 1); the alpha falls off over the last 8 %.
    float lvl = clamp(level, 0.0, 1.0);
    float radius = 0.90 + 0.08 * lvl;
    float edge = 1.0 - smoothstep(radius - 0.08, radius, r);
    if (edge <= 0.0) {
        return half4(0.0h);
    }

    // The sphere's normal: z from the disc, for the limb shading.
    float q = clamp(r / radius, 0.0, 1.0);
    float z = sqrt(max(0.0, 1.0 - q * q));

    // Four lobes on a turning cross; the third and fourth turn the other way a little slower.
    float a = time * 0.35;
    float wobble = 0.08 * sin(time * 0.9);
    float2 l0 = float2(cos(a), sin(a)) * (0.50 + wobble);
    float2 l1 = float2(cos(a + 1.5708), sin(a + 1.5708)) * (0.50 - wobble);
    float2 l2 = float2(cos(-a * 0.8 + 3.1416), sin(-a * 0.8 + 3.1416)) * 0.46;
    float2 l3 = float2(cos(-a * 0.8 + 4.7124), sin(-a * 0.8 + 4.7124)) * 0.46;
    float spread = 2.6 - 0.8 * lvl;
    float w0 = lobe(p, l0, spread);
    float w1 = lobe(p, l1, spread);
    float w2 = lobe(p, l2, spread);
    float w3 = lobe(p, l3, spread);
    float total = w0 + w1 + w2 + w3 + 1e-4;
    float3 base = (float3(c0.rgb) * w0 + float3(c1.rgb) * w1 + float3(c2.rgb) * w2 + float3(c3.rgb) * w3) / total;

    // Limb darkening, a soft specular highlight from the top left, and a faint rim of light.
    float shade = 0.58 + 0.42 * z;
    float2 h = p - float2(-0.34, -0.40);
    float specular = 0.30 * exp(-9.0 * dot(h, h)) + 0.10 * lvl * exp(-4.0 * dot(h, h));
    float rim = 0.12 * smoothstep(radius - 0.22, radius - 0.04, r) * (1.0 - smoothstep(radius - 0.04, radius, r));
    float3 rgb = clamp(base * shade + specular + rim, 0.0, 1.0);

    // Premultiplied, clipped to the shape the effect is applied to.
    float alpha = edge * float(color.a);
    return half4(half3(rgb * alpha), half(alpha));
}
