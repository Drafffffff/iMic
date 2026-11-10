#include <metal_stdlib>
#include "PhosphorResponse.h"
using namespace metal;

struct PhosphorStroke {
    float4 start, end, color, material;
};
struct PhosphorUniforms {
    float4 viewport, timing, regions, interaction, collapse;
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

inline float collapsePeriphery(float2 p, constant PhosphorUniforms &u) {
    float2 c=u.collapse.yz,d=p-c;
    float2 q=d/max(float2(1),max(c,u.viewport.xy-c));
    return pow(smoothstep(0.30,0.95,length(q)*0.70710678),1.5);
}

inline float2 collapseUV(float2 p, constant PhosphorUniforms &u) {
    float2 c=u.collapse.yz,d=p-c;
    // A fixed focal area; no uniform zoom. Only the periphery folds inward.
    float pull=0.10*(u.collapse.x/0.08)*collapsePeriphery(p,u);
    return (c+d*(1+pull))/u.viewport.xy;
}

inline float2 artworkUV(float2 p, constant PhosphorUniforms &u) {
    if(p.y>u.regions.z-4 && p.y<u.regions.w+4 && p.x>18 && p.x<u.viewport.x-18){
        float2 center=float2(u.viewport.x*.5,(u.regions.z+u.regions.w)*.5);
        p=center+(p-center)/max(.95,u.interaction.y);
    }
    return p/u.viewport.xy;
}

inline bool insideTexture(float2 uv) { return all(uv>=0.0) && all(uv<=1.0); }
inline half4 sampleInside(texture2d<half> tex, float2 uv) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    return insideTexture(uv) ? tex.sample(s,uv):half4(0);
}

inline float3 phosphorBackdrop(float2 uv, float2 aa, constant PhosphorUniforms &u) {
    const float3 ink=float3(0.019/12.92);
    if(!insideTexture(uv))return ink;
    float2 p=uv*u.viewport.xy;
    float2 distance=abs(fract(p/26.0+0.5)-0.5)*26.0;
    float2 line=1-smoothstep(float2(0),aa,distance);
    // Same 26pt grid, 1 physical pixel and 6.5% white as TechBackground.
    float srgb=mix(0.019,0.019*0.935+0.065,max(line.x,line.y));
    float linear=srgb<=0.04045 ? srgb/12.92:pow((srgb+0.055)/1.055,2.4);
    return float3(linear);
}

inline float3 phosphorSharp(float2 uv, float2 p, float2 aa,
                            texture2d<half> core, texture2d<half> artwork,
                            constant PhosphorUniforms &u) {
    float4 ui=float4(sampleInside(artwork,artworkUV(uv*u.viewport.xy,u)));
    float3 base=ui.rgb+phosphorBackdrop(uv,aa,u)*(1-ui.a);
    base*=imicDisplayResponse(p,u.viewport.z,u.viewport.w);
    float4 scene=float4(sampleInside(core,uv));
    return scene.rgb+base*(1-scene.a);
}

// Optical sampling happens AFTER phosphor lighting, so bloom cannot wash out
// split RGB edges. The same sampler also works without bloom in clean material.
inline float3 phosphorLit(float2 uv, float2 p, float2 aa,
                         texture2d<half> core, texture2d<half> artwork,
                         texture2d<half> nearGlow, texture2d<half> mediumGlow,
                         texture2d<half> farGlow, texture2d<half> clearArtwork,
                         constant PhosphorUniforms &u) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float3 sharp=phosphorSharp(uv,p,aa,core,artwork,u);
    if(u.interaction.x>0.06 && p.y<84){
        float progress=u.interaction.x,opacity=.25+.75*progress;
        float3 orange=float3(1,.0685,0)*imicDisplayResponse(p,u.viewport.z,u.viewport.w);
        sharp=mix(sharp,orange,(.04+.20*progress)*opacity);
        float4 mark=float4(clearArtwork.sample(s,float2(p.x/u.viewport.x,p.y/84)));
        sharp=mark.rgb*opacity+sharp*(1-mark.a*opacity);
        if(p.y>83)sharp=mix(sharp,orange,progress*opacity);
    }
    float3 glow=float3(0);
    if(u.timing.z>0){
        glow=float3(sampleInside(nearGlow,uv).rgb)*0.46
            +float3(sampleInside(mediumGlow,uv).rgb)*0.25
            +float3(sampleInside(farGlow,uv).rgb)*0.08;
    }
    float3 light=1-exp(-glow*u.timing.z);
    return sharp+(1-min(sharp,float3(1)))*light;
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
    // Seed/blur remain in SOURCE space. Composite applies collapse exactly once to
    // the resulting halo, core and artwork; pre-warping UI here would warp it twice.
    half3 ui=sampleInside(artwork,artworkUV(in.uv*u.viewport.xy,u)).rgb;
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

inline float3 phosphorDisplay(float3 result, float2 p, constant PhosphorUniforms &u) {
    float2 screenUV=p/u.viewport.xy,d=p-u.collapse.yz;
    float2 extent=max(u.collapse.yz,u.viewport.xy-u.collapse.yz);
    float r2=clamp(dot(d,d)/max(1.0,dot(extent,extent)),0.0,1.0);
    float edge=pow(abs(screenUV.x-.5)*1.6,4.0)+pow(abs(screenUV.y-.5)*1.6,4.0);
    result*=1-edge*0.055*u.viewport.w;
    result*=1-0.12*u.collapse.w*collapsePeriphery(p,u);
    result*=1-u.interaction.z*smoothstep(0.12,0.85,r2);
    float grain=fract(sin(dot(floor(p*u.viewport.z),float2(127.1,311.7)))*43758.5453)-.5;
    result+=grain*0.003*u.viewport.w;
    return clamp(result,0.0,1.0);
}

fragment half4 phosphorCompositeFragment(PhosphorVertex in [[stage_in]],
                                        texture2d<half> core [[texture(0)]],
                                        texture2d<half> artwork [[texture(1)]],
                                        texture2d<half> nearGlow [[texture(2)]],
                                        texture2d<half> mediumGlow [[texture(3)]],
                                        texture2d<half> farGlow [[texture(4)]],
                                        texture2d<half> clearArtwork [[texture(5)]],
                                        constant PhosphorUniforms &u [[buffer(1)]]) {
    float2 p=in.uv*u.viewport.xy;
    float2 uv=collapseUV(p,u),samplePoint=uv*u.viewport.xy;
    float2 aa=max(fwidth(samplePoint),float2(1.0/max(1.0,u.viewport.z)));
    float3 result=phosphorLit(uv,p,aa,core,artwork,nearGlow,mediumGlow,farGlow,clearArtwork,u);
    return half4(half3(result),1);
}

fragment half4 phosphorDirectFragment(PhosphorVertex in [[stage_in]],
                                        texture2d<half> core [[texture(0)]],
                                        texture2d<half> artwork [[texture(1)]],
                                        texture2d<half> nearGlow [[texture(2)]],
                                        texture2d<half> mediumGlow [[texture(3)]],
                                        texture2d<half> farGlow [[texture(4)]],
                                        texture2d<half> clearArtwork [[texture(5)]],
                                        constant PhosphorUniforms &u [[buffer(1)]]) {
    float2 p=in.uv*u.viewport.xy;
    float2 uv=collapseUV(p,u),samplePoint=uv*u.viewport.xy;
    float2 aa=max(fwidth(samplePoint),float2(1.0/max(1.0,u.viewport.z)));
    float3 result=phosphorLit(uv,p,aa,core,artwork,nearGlow,mediumGlow,farGlow,clearArtwork,u);
    return half4(half3(phosphorDisplay(result,p,u)),1);
}

inline float3 phosphorLensSample(texture2d<half> page, float2 uv) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    return insideTexture(uv) ? float3(page.sample(s,uv).rgb):float3(0.019/12.92);
}

fragment half4 phosphorLensFragment(PhosphorVertex in [[stage_in]],
                                    texture2d<half> page [[texture(0)]],
                                    constant PhosphorUniforms &u [[buffer(1)]]) {
    float2 p=in.uv*u.viewport.xy,d=p-u.collapse.yz;
    float optics=u.collapse.w*collapsePeriphery(p,u);
    float3 result=phosphorLensSample(page,in.uv);
    if(optics>0.0001){
        float2 ray=d/max(1.0,length(d))/u.viewport.xy;
        float2 direction=ray*(7.0*optics/3.230769);
        float2 chroma=ray*(2.0*optics);
        constexpr float offsets[]={0,1.384615,-1.384615,3.230769,-3.230769};
        constexpr float weights[]={0.227027,0.316216,0.316216,0.070270,0.070270};
        // Each shifted RGB channel passes through the SAME Gaussian kernel.
        // Bilinear paired taps approximate nine smooth samples, not three copies.
        result=float3(0);
        for(int i=0;i<5;i++){
            float2 uv=in.uv+direction*offsets[i];
            result.r+=phosphorLensSample(page,uv+chroma).r*weights[i];
            result.g+=phosphorLensSample(page,uv).g*weights[i];
            result.b+=phosphorLensSample(page,uv-chroma).b*weights[i];
        }
    }
    return half4(half3(phosphorDisplay(result,p,u)),1);
}
