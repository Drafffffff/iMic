import Foundation
import Metal
import simd

func check(_ condition:@autoclosure()->Bool,_ message:String){
    if !condition(){fatalError(message)}
}

check(MemoryLayout<PhosphorStroke>.stride==64,"Stroke ABI")
check(MemoryLayout<PhosphorUniforms>.stride==64,"Frame ABI")
for angle in stride(from:-2.0,through:2.0,by:0.25){
    let rotation=CGFloat(angle*0.3)
    let r=PhosphorMath.ring(center:CGPoint(x:120,y:80),radiusX:6,radiusY:42,rotation:rotation,depth:-18,opacity:0.7)
    check(abs(simd_dot(r.u,r.v))<0.00001,"Spatial axes must be orthogonal")
    check(abs(simd_length(r.u)-1)<0.00001 && abs(simd_length(r.v)-1)<0.00001,"Spatial axes must retain unit length")
    let p=r.point(Float(angle))
    let x=120+cos(angle)*6*cos(Double(rotation))-sin(angle)*42*sin(Double(rotation))
    let y=80+cos(angle)*6*sin(Double(rotation))+sin(angle)*42*cos(Double(rotation))
    check(abs(Double(p.x)-x)<0.0001 && abs(Double(p.y)-y)<0.0001,"Front projection must keep existing glyph anchors")
}
let ring=PhosphorMath.ring(center:CGPoint(x:0,y:0),radiusX:6,radiusY:42,rotation:0,depth:0,opacity:1)
check(abs(ring.point(0).z)>40,"Ring must have real z extent")
let side=PhosphorCamera(center:.zero,yaw:.pi/2).project(ring.point(0))
check(abs(side.x)>40,"Side view must reveal real spatial extent")
check(abs(PhosphorMath.decay(dt:1/60.0)*PhosphorMath.decay(dt:1/60.0)-PhosphorMath.decay(dt:1/30.0))<0.000001,"Persistence must be frame-rate independent")

guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else{fatalError("Metal device required")}
let path=CommandLine.arguments[1]
let shared=try String(contentsOfFile:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("PhosphorResponse.h").path,encoding:.utf8)
let source=try String(contentsOfFile:path,encoding:.utf8).replacingOccurrences(of:"#include \"PhosphorResponse.h\"",with:shared)
let lib=try device.makeLibrary(source:source,options:nil)
func texture(_ r:Float=0,_ g:Float=0,_ b:Float=0,_ a:Float=1)->MTLTexture{
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:32,height:32,mipmapped:false)
    d.storageMode = .shared;d.usage = [.shaderRead,.renderTarget]
    let t=device.makeTexture(descriptor:d)!
    var pixels=[Float16]();pixels.reserveCapacity(4096)
    for _ in 0..<1024{pixels.append(contentsOf:[Float16(r),Float16(g),Float16(b),Float16(a)])}
    pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32*8)}
    return t
}
func values(_ t:MTLTexture)->[Float]{
    var p=[UInt16](repeating:0,count:4096)
    p.withUnsafeMutableBytes{t.getBytes($0.baseAddress!,bytesPerRow:256,from:MTLRegionMake2D(0,0,32,32),mipmapLevel:0)}
    return p.map{Float(Float16(bitPattern:$0))}
}
func pipeline(_ fragment:String,mrt:Bool=false)throws->MTLRenderPipelineState{
    let d=MTLRenderPipelineDescriptor()
    d.vertexFunction=lib.makeFunction(name:mrt ? "phosphorStrokeVertex":"phosphorFullscreenVertex")
    d.fragmentFunction=lib.makeFunction(name:fragment);d.colorAttachments[0].pixelFormat = .rgba16Float
    if mrt{d.colorAttachments[1].pixelFormat = .rgba16Float;d.depthAttachmentPixelFormat = .depth32Float}
    return try device.makeRenderPipelineState(descriptor:d)
}
var u=PhosphorUniforms(viewport:SIMD4(32,32,1,0),timing:SIMD4(0.5,0,0,1),regions:SIMD4(-100,-90,-80,-70))
func full(_ name:String,textures:[MTLTexture],direction:SIMD2<Float> = .zero)throws->[Float]{
    let out=texture(0,0,0,0),p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=out;p.colorAttachments[0].loadAction = .dontCare;p.colorAttachments[0].storeAction = .store
    let c=queue.makeCommandBuffer()!,e=c.makeRenderCommandEncoder(descriptor:p)!
    e.setRenderPipelineState(try pipeline(name));e.setFragmentBytes(&u,length:64,index:1)
    for i in 0..<6{e.setFragmentTexture(i<textures.count ? textures[i]:textures[0],index:i)}
    var direction=direction;e.setFragmentBytes(&direction,length:8,index:0)
    e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding();c.commit();c.waitUntilCompleted()
    check(c.status == .completed,"GPU pass \(name) must complete")
    return values(out)
}
var press=PhosphorPressSpring()
press.set(pressed:true,at:1)
check(abs(press.value(at:1).0-1)<0.00001,"Press spring must start continuously")
check(abs(press.value(at:2).0-0.986)<0.00001,"Press spring must settle at the existing scale")
let before=press.value(at:1.08)
press.set(pressed:false,at:1.08)
check(abs(press.value(at:1.08).0-before.0)<0.000001,"Changing press direction must preserve position")
check(abs(press.value(at:1.08).1-before.1)<0.000001,"Changing press direction must preserve velocity")
let current=texture(0.2),previous=texture(2)
let persisted=try full("phosphorHistoryFragment",textures:[current,previous])
check(abs(persisted[0]-1)<0.01,"History must decay previous energy")
u.timing.y=1
let cleared=try full("phosphorHistoryFragment",textures:[current,previous])
check(abs(cleared[0]-0.2)<0.01,"Reset must remove stale history")

let blank=texture(0,0,0,0),ui=texture(0.25,0.1,0.01)
let clean=try full("phosphorCompositeFragment",textures:[blank,ui,blank,blank,blank])
check(abs(clean[(16*32+16)*4]-0.25)<0.001,"Clean mode must preserve linear UI colors")
u.viewport.w=0.82
let crt=try full("phosphorCompositeFragment",textures:[blank,ui,blank,blank,blank])
let rows=(3..<28).map{crt[($0*32+16)*4]}
check(rows.max()!-rows.min()!>0.025,"CRT must create measurable, visible scan modulation")

let impulse=texture(0,0,0,0)
var hot:[Float16]=[6,0,0,1]
hot.withUnsafeBytes{impulse.replace(region:MTLRegionMake2D(16,16,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:8)}
let blurred=try full("phosphorBlurFragment",textures:[impulse],direction:SIMD2(1/32,0))
check(blurred[(16*32+18)*4]>0.1,"HDR light must spread outside its source")
check(blurred[(16*32+16)*4]>1,"Blur intermediates must retain HDR values")

let core=texture(0,0,0,0),emission=texture(0,0,0,0)
let p=MTLRenderPassDescriptor()
for (i,t) in [core,emission].enumerated(){p.colorAttachments[i].texture=t;p.colorAttachments[i].loadAction = .clear;p.colorAttachments[i].storeAction = .store;p.colorAttachments[i].clearColor=MTLClearColorMake(0,0,0,0)}
let depthDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:32,height:32,mipmapped:false)
depthDescriptor.storageMode = .private;depthDescriptor.usage = .renderTarget
p.depthAttachment.texture=device.makeTexture(descriptor:depthDescriptor);p.depthAttachment.loadAction = .clear;p.depthAttachment.clearDepth=1
var stroke=PhosphorStroke(start:SIMD4(4,16,0,2),end:SIMD4(28,16,0,0),color:SIMD4(1,0.068,0,1),material:SIMD4(6,1,0,0))
let buffer=device.makeBuffer(bytes:&stroke,length:64)!,command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:p)!
encoder.setRenderPipelineState(try pipeline("phosphorStrokeFragment",mrt:true));encoder.setVertexBuffer(buffer,offset:0,index:0)
encoder.setVertexBytes(&u,length:64,index:1);encoder.setFragmentBytes(&u,length:64,index:1)
encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6);encoder.endEncoding();command.commit();command.waitUntilCompleted()
check(command.status == .completed,"Wireframe MRT draw must complete")
let coreValues=values(core),emitted=values(emission),center=(16*32+16)*4
check(coreValues[center]>0.7 && coreValues[center]<=1,"Sharp wire core must remain bounded")
check(emitted[center]>4,"Emission must retain energy beyond SDR white")
print("Phosphor: spatial geometry, original anchors, ABI, HDR MRT, decay/reset, blur halo, clean colors and visible CRT passed")
