#include <metal_stdlib>
#include "PhosphorResponse.h"
using namespace metal;

struct WaveGlyphInstance {
    float4 bounds;
    float4 uvRect;
    uint2 sampleRange;
    float depth;
    float reserved;
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
    float style [[flat]];
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
    out.position = float4(point.x / viewport.x * 2 - 1, 1 - point.y / viewport.y * 2, glyph.depth, 1);
    out.screenPoint = point;
    out.uvRect = glyph.uvRect;
    out.sampleRange = glyph.sampleRange;
    out.style = glyph.reserved;
    return out;
}

inline float glyphCoverage(float2 screenPoint, WaveGlyphSample pose, float4 uvRect,
                           texture2d<float> atlas, float displayScale) {
    float2 relative = screenPoint - pose.geometry.xy;
    float2 orientation = pose.appearance.xy;
    float2 local = float2(dot(relative, orientation),
                         dot(relative, float2(-orientation.y, orientation.x))) / pose.geometry.zw + 0.5;
    if (any(local < 0) || any(local > 1)) return 0;
    // Explicit LOD from the glyph's on-screen footprint (implicit derivatives are undefined
    // inside this per-sample loop). The more compressed axis wins, so small, squashed or
    // rotated glyphs filter softly instead of breaking into fragments. Level 3.5 keeps the
    // atlas cell padding intact.
    float2 texels = uvRect.zw * float2(atlas.get_width(), atlas.get_height());
    float2 perPixel = texels / max(pose.geometry.zw * displayScale, float2(1e-3));
    float lod = clamp(log2(max(perPixel.x, perPixel.y)), 0.0, 3.5);
    constexpr sampler sampling(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return atlas.sample(sampling, uvRect.xy + local * uvRect.zw, level(lod)).r;
}

fragment float4 waveGlyphFragment(WaveGlyphVertex in [[stage_in]],
                                 const device WaveGlyphSample *samples [[buffer(0)]],
                                 texture2d<float> atlas [[texture(0)]]) {
    float4 exposure = 0;
    for (uint index = 0; index < in.sampleRange.y; ++index) {
        const WaveGlyphSample pose = samples[in.sampleRange.x + index];
        // This path has no display uniforms; 3x matches current iPhones and only biases blur.
        float alpha = glyphCoverage(in.screenPoint, pose, in.uvRect, atlas, 3.0) * pose.appearance.z;
        float warmth = pose.appearance.w;
        float3 color = float3(1 - warmth * 0.05, 0.29 + warmth * 0.65, warmth * 0.88);
        exposure += float4(color * alpha, alpha);
    }
    // Average premultiplied images over the shutter. No extra sharp image, gain or history.
    return exposure / float(in.sampleRange.y);
}

struct WaveDisplayOutput {
    half4 core [[color(0)]];
    half4 emission [[color(1)]];
};

fragment WaveDisplayOutput waveGlyphDisplayFragment(WaveGlyphVertex in [[stage_in]],
                                  const device WaveGlyphSample *samples [[buffer(0)]],
                                  constant float4 *uniforms [[buffer(1)]],
                                  texture2d<float> atlas [[texture(0)]]) {
    float4 exposure=0;
    for(uint i=0;i<in.sampleRange.y;i++){
        WaveGlyphSample pose=samples[in.sampleRange.x+i];
        float a=glyphCoverage(in.screenPoint,pose,in.uvRect,atlas,max(uniforms[0].z,1.0))*pose.appearance.z;
        float w=pose.appearance.w;
        float3 srgb=float3(1-w*.05,.29+w*.65,w*.88);
        if(in.style>0.5)srgb=float3(.019);
        float3 linear=select(srgb/12.92,pow((srgb+.055)/1.055,float3(2.4)),srgb>float3(.04045));
        exposure+=float4(linear*a,a);
    }
    exposure/=float(in.sampleRange.y);
    float strength=uniforms[0].w;
    float3 tint=exposure.a>0.001?exposure.rgb/exposure.a:float3(0);
    float3 beam=imicAdaptiveResponse(in.screenPoint,uniforms[0].z,strength,tint);
    WaveDisplayOutput out;
    out.core=half4(half3(exposure.rgb*beam),half(exposure.a));
    // style 1 is dark ink; 0..<0.5 adds bloom so attached text glows above its wire.
    // Local light only, with no history feedback or extra sharp exposure.
    float glow=in.style>0.5?0:.32+in.style*8;
    out.emission=half4(half3(exposure.rgb*glow*imicMeanScan(strength)),0);
    return out;
}
