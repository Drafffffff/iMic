#include <metal_stdlib>
using namespace metal;

struct WaveGlyphInstance {
    float4 bounds;
    float4 uvRect;
    uint2 sampleRange;
};

struct WaveGlyphSample {
    float4 geometry;
    float4 appearance;
};

struct WaveGlyphVertex {
    float4 position [[position]];
    float2 screenPoint;
    float4 uvRect [[flat]];
    uint2 sampleRange [[flat]];
};

vertex WaveGlyphVertex waveGlyphVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      const device WaveGlyphInstance *glyphs [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]]) {
    constexpr float2 corners[] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    const WaveGlyphInstance glyph = glyphs[instanceID];
    float2 point = glyph.bounds.xy + corners[vertexID] * glyph.bounds.zw;
    WaveGlyphVertex out;
    out.position = float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1);
    out.screenPoint = point;
    out.uvRect = glyph.uvRect;
    out.sampleRange = glyph.sampleRange;
    return out;
}

inline float glyphCoverage(float2 screenPoint, WaveGlyphSample pose, float4 uvRect,
                           texture2d<float> atlas) {
    float2 relative = screenPoint - pose.geometry.xy;
    float2 orientation = pose.appearance.xy;
    float2 local = float2(dot(relative, orientation),
                         dot(relative, float2(-orientation.y, orientation.x))) / pose.geometry.zw + 0.5;
    if (any(local < 0) || any(local > 1)) return 0;
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    return atlas.sample(sampling, uvRect.xy + local * uvRect.zw).r;
}

fragment float4 waveGlyphFragment(WaveGlyphVertex in [[stage_in]],
                                 const device WaveGlyphSample *samples [[buffer(0)]],
                                 texture2d<float> atlas [[texture(0)]]) {
    float4 exposure = 0;
    for (uint index = 0; index < in.sampleRange.y; ++index) {
        const WaveGlyphSample pose = samples[in.sampleRange.x + index];
        float alpha = glyphCoverage(in.screenPoint, pose, in.uvRect, atlas) * pose.appearance.z;
        float warmth = pose.appearance.w;
        float3 color = float3(1 - warmth * 0.05, 0.29 + warmth * 0.65, warmth * 0.88);
        exposure += float4(color * alpha, alpha);
    }
    // Average premultiplied images over the shutter. No extra sharp image, gain or history.
    return exposure / float(in.sampleRange.y);
}
