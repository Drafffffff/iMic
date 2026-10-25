#include <metal_stdlib>
using namespace metal;

struct WaveGlyphInstance {
    float2 center;
    float2 size;
    float4 uvRect;
    float2 orientation;
    float4 color;
};

struct WaveGlyphVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex WaveGlyphVertex waveGlyphVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      const device WaveGlyphInstance *glyphs [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]]) {
    constexpr float2 corners[] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    const WaveGlyphInstance glyph = glyphs[instanceID];
    float2 corner = corners[vertexID];
    float2 local = (corner - 0.5) * glyph.size;
    float2 point = glyph.center + float2(
        local.x * glyph.orientation.x - local.y * glyph.orientation.y,
        local.x * glyph.orientation.y + local.y * glyph.orientation.x);
    WaveGlyphVertex out;
    out.position = float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, 0, 1);
    out.uv = glyph.uvRect.xy + corner * glyph.uvRect.zw;
    out.color = glyph.color;
    return out;
}

fragment float4 waveGlyphFragment(WaveGlyphVertex in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler sampling(filter::linear, address::clamp_to_edge);
    float alpha = atlas.sample(sampling, in.uv).a * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}
