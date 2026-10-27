#ifndef IMIC_PHOSPHOR_RESPONSE_H
#define IMIC_PHOSPHOR_RESPONSE_H
#include <metal_stdlib>
using namespace metal;
inline float imicScanResponse(float y,float strength){
    return 1-strength*0.28*(0.5+0.5*cos(y*3.4906585));
}
inline float3 imicDisplayResponse(float2 point,float scale,float strength){
    float beam=imicScanResponse(point.y,strength);
    float channel=fmod(floor(point.x*scale),3.0);
    float3 mask=channel<1?float3(1,.94,.94):channel<2?float3(.94,1,.94):float3(.94,.94,1);
    return beam*mix(float3(1),mask,strength);
}
// A brighter beam spot is wider and fills the gap between scan lines, as on a real tube:
// dim orange wire keeps the full texture, white-hot text and arcs no longer break into rungs.
inline float3 imicAdaptiveResponse(float2 point,float scale,float strength,float3 linearColor){
    float luminance=dot(linearColor,float3(0.2126,0.7152,0.0722));
    return imicDisplayResponse(point,scale,strength*(1-0.75*smoothstep(0.35,0.9,luminance)));
}
// Bloom is blurred anyway; give it the scan pattern's mean energy instead of its stripes.
inline float imicMeanScan(float strength){return 1-strength*0.14;}
#endif
