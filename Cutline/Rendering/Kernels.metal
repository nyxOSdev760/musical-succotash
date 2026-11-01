#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

    /// Chroma key: removes pixels close to `key` in CbCr space, with a soft edge
    /// and spill suppression on the remaining pixels.
    float4 chromaKey(sample_t s, float3 key, float tolerance, float softness) {
        float4 c = unpremultiply(s);
        float3 rgb = c.rgb;

        float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
        float cr = 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;
        float kcb = -0.168736 * key.r - 0.331264 * key.g + 0.5 * key.b;
        float kcr = 0.5 * key.r - 0.418688 * key.g - 0.081312 * key.b;

        float d = distance(float2(cb, cr), float2(kcb, kcr));
        float lo = tolerance * 0.45;
        float hi = lo + softness * 0.35 + 0.002;
        float a = smoothstep(lo, hi, d);

        // Spill suppression: pull the dominant key channel toward the average of the others.
        float3 outRGB = rgb;
        if (key.g >= key.r && key.g >= key.b) {
            float limit = (rgb.r + rgb.b) * 0.5;
            outRGB.g = mix(min(rgb.g, limit), rgb.g, a);
        } else if (key.b >= key.r && key.b >= key.g) {
            float limit = (rgb.r + rgb.g) * 0.5;
            outRGB.b = mix(min(rgb.b, limit), rgb.b, a);
        }
        return premultiply(float4(outRGB, c.a * a));
    }

    /// Per-channel multiply used by the glitch transition (RGB split).
    float4 channelTint(sample_t s, float3 mask) {
        return float4(s.rgb * mask, s.a);
    }
}
}
