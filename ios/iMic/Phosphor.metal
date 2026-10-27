#include <metal_stdlib>
#include "PhosphorResponse.h"
using namespace metal;

// Static, physical-pixel display material. Alpha stays premultiplied, including
// the transparent area around the waveform. No time input or feedback texture.
[[ stitchable ]] half4 imicPhosphorCRT(float2 position, half4 color,
                                      float displayScale, float strength) {
    float2 pixel = floor(position * max(displayScale, 1.0));
    float amount = clamp(strength, 0.0, 1.0);
    float grain = fract(sin(dot(pixel, float2(127.1, 311.7))) * 43758.5453) - 0.5;
    float3 rgb = float3(color.rgb) * imicDisplayResponse(position, displayScale, amount);
    rgb += grain * 0.008 * amount * float(color.a);
    return half4(half3(clamp(rgb, float3(0.0), float3(color.a))), color.a);
}

[[ stitchable ]] half4 imicPhosphorGlass(float2 position, float originY, float strength) {
    return half4(0,0,0,half(1-imicScanResponse(position.y+originY,strength)));
}
