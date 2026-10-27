#include <metal_stdlib>
#include "PhosphorResponse.h"
using namespace metal;

struct PhosphorStroke {
    float4 start, end, color, material;
};
struct PhosphorUniforms {
    float4 viewport, timing, regions, interaction;
};
struct PhosphorVertex {
    float4 position [[position]];
    float2 uv;
};
struct StrokeVertex {
    float4 position [[position]];
    float4 color [[flat]];
    float4 material [[flat]];
    float2 point;
    float edge;
};
struct PhosphorOutput {
    half4 core [[color(0)]];
    half4 emission [[color(1)]];
};
struct PhosphorStrokeOutput {
    half4 core [[color(0)]];
    half4 emission [[color(1)]];
    // Only the solid core occludes. Anti-aliased fringes writing depth cut dark notches
    // into the next segment of the same ring and into lines crossing it.
    float depth [[depth(any)]];
};

inline float beamResponse(float2 p, float strength) {
    // Point-based pitch remains perceptible on a high-density iPhone screen.
    return imicScanResponse(p.y,strength);
}

vertex StrokeVertex phosphorStrokeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        const device PhosphorStroke *strokes [[buffer(0)]],
                                        constant PhosphorUniforms &u [[buffer(1)]]) {
    constexpr float2 corners[] = {float2(0,-1),float2(1,-1),float2(1,1),
                                  float2(0,-1),float2(1,1),float2(0,1)};
    PhosphorStroke s=strokes[iid];float2 corner=corners[vid];
    float2 delta=s.end.xy-s.start.xy;
    float2 n=normalize(float2(-delta.y,delta.x)+float2(0.00001));
    float3 p=mix(s.start.xyz,s.end.xyz,corner.x);
    p.xy+=n*corner.y*(s.start.w*0.5+0.75/u.viewport.z);
    StrokeVertex out;
    out.position=float4(p.x/u.viewport.x*2-1,1-p.y/u.viewport.y*2,clamp(0.5-p.z/4096,0.05,0.95),1);
    out.color=s.color;out.material=s.material;out.edge=corner.y;out.point=p.xy;
    return out;
}

fragment PhosphorStrokeOutput phosphorStrokeFragment(StrokeVertex in [[stage_in]],
                                              constant PhosphorUniforms &u [[buffer(1)]]) {
    float aa=max(fwidth(in.edge),0.08);
    float coverage=(1-smoothstep(1-aa,1,abs(in.edge)))*in.color.a;
    if(coverage<0.0001)discard_fragment();
    float3 beam=imicAdaptiveResponse(in.point,u.viewport.z,u.viewport.w,in.color.rgb);
    PhosphorStrokeOutput out;
    out.depth=coverage>0.5*in.color.a?in.position.z:1.0;
    out.core=half4(half3(in.color.rgb*coverage*beam),half(coverage));
    // Linear emission energy can exceed 1; it is never stored in an 8-bit target.
    out.emission=half4(half3(in.color.rgb*coverage*in.material.x*imicMeanScan(u.viewport.w)),half(coverage));
    return out;
}

vertex PhosphorVertex phosphorFullscreenVertex(uint vid [[vertex_id]]) {
    float2 p=float2(float((vid<<1)&2),float(vid&2));
    PhosphorVertex out;out.position=float4(p*float2(2,-2)+float2(-1,1),0,1);out.uv=p;
    return out;
}

fragment half4 phosphorHistoryFragment(PhosphorVertex in [[stage_in]],
                                      texture2d<half> current [[texture(0)]],
                                      texture2d<half> previous [[texture(1)]],
                                      constant PhosphorUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    half3 energy=current.sample(s,in.uv).rgb;
    half3 old=half3(0);
    if(u.timing.y<0.5)old=previous.sample(s,in.uv).rgb*half(u.timing.x);
    return half4(min(max(energy,old),half3(12)),1);
}

fragment half4 phosphorSeedFragment(PhosphorVertex in [[stage_in]],
                                   texture2d<half> emission [[texture(0)]],
                                   texture2d<half> history [[texture(1)]],
                                   texture2d<half> artwork [[texture(2)]],
                                   texture2d<half> clearArtwork [[texture(3)]],
                                   constant PhosphorUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    // Afterglow only feeds the halo, at half strength, so a moving wire leaves no trail.
    half3 e=max(emission.sample(s,in.uv).rgb,history.sample(s,in.uv).rgb*half(0.5));
    half3 ui=artwork.sample(s,in.uv).rgb;
    float y=in.uv.y*u.viewport.y;
    float status=smoothstep(u.regions.x-4,u.regions.x+4,y)*(1-smoothstep(u.regions.y-4,u.regions.y+4,y));
    float action=smoothstep(u.regions.z-3,u.regions.z+3,y)*(1-smoothstep(u.regions.w-3,u.regions.w+3,y));
    // Masks prevent the filled recording bar and Chinese copy from flooding the screen.
    half weight=half(mix(0.09,0.85,status)*(1-action*0.96));
    e+=ui*weight*half(beamResponse(in.uv*u.viewport.xy,u.viewport.w));
    if(u.interaction.x>0.06 && y<84){
        float opacity=.25+.75*u.interaction.x;
        e+=clearArtwork.sample(s,float2(in.uv.x,y/84)).rgb*half(3*opacity);
    }
    return half4(e,1);
}

fragment half4 phosphorDownsampleFragment(PhosphorVertex in [[stage_in]],
                                         texture2d<half> source [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 d=1.0/float2(source.get_width(),source.get_height());
    half3 c=source.sample(s,in.uv).rgb*half(0.2);
    for(int y=-1;y<=1;y+=2)for(int x=-1;x<=1;x+=2)c+=source.sample(s,in.uv+float2(x,y)*d).rgb*half(0.2);
    return half4(c,1);
}

fragment half4 phosphorBlurFragment(PhosphorVertex in [[stage_in]],
                                   texture2d<half> source [[texture(0)]],
                                   constant float2 &direction [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    half3 c=source.sample(s,in.uv).rgb*half(0.227027);
    c+=(source.sample(s,in.uv+direction*1.384615).rgb+source.sample(s,in.uv-direction*1.384615).rgb)*half(0.316216);
    c+=(source.sample(s,in.uv+direction*3.230769).rgb+source.sample(s,in.uv-direction*3.230769).rgb)*half(0.070270);
    return half4(c,1);
}

fragment half4 phosphorCompositeFragment(PhosphorVertex in [[stage_in]],
                                        texture2d<half> core [[texture(0)]],
                                        texture2d<half> artwork [[texture(1)]],
                                        texture2d<half> nearGlow [[texture(2)]],
                                        texture2d<half> mediumGlow [[texture(3)]],
                                        texture2d<half> farGlow [[texture(4)]],
                                        texture2d<half> clearArtwork [[texture(5)]],
                                        constant PhosphorUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 p=in.uv*u.viewport.xy;
    float2 samplePoint=p;
    if(p.y>u.regions.z-4 && p.y<u.regions.w+4 && p.x>18 && p.x<u.viewport.x-18){
        float2 center=float2(u.viewport.x*.5,(u.regions.z+u.regions.w)*.5);
        samplePoint=center+(p-center)/max(.95,u.interaction.y);
    }
    float3 base=float3(artwork.sample(s,samplePoint/u.viewport.xy).rgb);
    float strength=u.viewport.w;
    base*=imicDisplayResponse(p,u.viewport.z,strength);
    float4 scene=float4(core.sample(s,in.uv));
    float3 sharp=scene.rgb+base*(1-scene.a);
    if(u.interaction.x>0.06 && p.y<84){
        float progress=u.interaction.x,opacity=.25+.75*progress;
        float3 orange=float3(1,.0685,0)*imicDisplayResponse(p,u.viewport.z,strength);
        sharp=mix(sharp,orange,(.04+.20*progress)*opacity);
        float4 mark=float4(clearArtwork.sample(s,float2(in.uv.x,p.y/84)));
        sharp=mark.rgb*opacity+sharp*(1-mark.a*opacity);
        if(p.y>83)sharp=mix(sharp,orange,progress*opacity);
    }
    float3 glow=float3(nearGlow.sample(s,in.uv).rgb)*0.46
        +float3(mediumGlow.sample(s,in.uv).rgb)*0.25
        +float3(farGlow.sample(s,in.uv).rgb)*0.08;
    // Display-referred rolloff preserves the existing UI colors without auto exposure.
    float3 light=1-exp(-glow*u.timing.z);
    float3 result=sharp+(1-min(sharp,float3(1)))*light;
    float edge=pow(abs(in.uv.x-.5)*1.6,4.0)+pow(abs(in.uv.y-.5)*1.6,4.0);
    result*=1-edge*0.055*strength;
    float grain=fract(sin(dot(floor(p*u.viewport.z),float2(127.1,311.7)))*43758.5453)-.5;
    result+=grain*0.003*strength;
    // Drawable uses sRGB; linear output is encoded exactly once by Metal.
    return half4(half3(clamp(result,0.0,1.0)),1);
}
