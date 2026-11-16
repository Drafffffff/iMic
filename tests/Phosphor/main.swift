import Foundation
import Metal
import simd

func check(_ condition:@autoclosure()->Bool,_ message:String){
    if !condition(){fatalError(message)}
}

check(MemoryLayout<PhosphorStroke>.stride==64,"Stroke ABI")
check(MemoryLayout<PhosphorUniforms>.stride==80,"Frame ABI")
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

// Exercise time, lifecycle and accessibility without a view or an audio device.
func recording(_ elapsed:Double, level:Double=0.5, reduced:Bool=false)->PhosphorCollapse {
    var state=PhosphorCollapse()
    state.configure(elapsed:0,ending:.cancelled,reduced:reduced,now:100)
    _=state.advance(level:level,now:100+elapsed)
    return state
}
var collapse=recording(0)
check(collapse.sample(at:100).amount==0,"Recording starts with zero collapse")
check(collapse.sample(at:100).needsFrames,"A newly started recording must wake the clock")
check(abs(recording(1000).sample(at:1100).amount-0.08)<0.000001,"Long holds converge to the bounded maximum")
let tenSecond=recording(10).sample(at:110).amount
check(tenSecond/0.08>0.35 && tenSecond/0.08<0.37,"Ten seconds shows a visible fraction of the gentle range")
check(recording(2).sample(at:102).amount/0.08>0.19 && recording(2).sample(at:102).amount/0.08<0.22,"A two-second recording already has a small visible cue")
let thirty=recording(30).sample(at:130),sixty=recording(60).sample(at:160)
check(thirty.amount/0.08>0.58 && thirty.amount/0.08<0.60,"The reminder grows gradually after prolonged speech")
check(sixty.amount/0.08>0.78 && sixty.amount/0.08<0.80,"A minute of speech approaches the gentle limit")
check(thirty.streak>thirty.amount/0.08+0.05,"Optics remain visible independently of the small geometry amount")
check(recording(2).sample(at:102).streak>0.25,"Two-second optical cue is not hidden behind a long delay")
check(recording(5).sample(at:105).streak>0.35,"Short recordings already have a visible optical gain")
for target in [0.0,1.0] {
    let a=recording(10,level:target).sample(at:110).amount
    check(a>=tenSecond*0.85 && a<=tenSecond*1.15,"Input-level pulse stays within fifteen percent")
}
var filtered=recording(10)
let unpulsed=filtered.sample(at:110).amount
let pulse=filtered.advance(level:1,now:110+1.0/120).amount
check(abs(pulse-unpulsed)<0.0005,"A sudden input-level change is low-pass filtered")

for ending in [PhosphorCollapse.Ending.sent,.cancelled] {
    var state=recording(10)
    state.configure(elapsed:nil,ending:ending,reduced:false,now:110)
    check(abs(state.sample(at:110).amount-tenSecond)<0.000001,"Release starts at the current amount")
    var negativeLobes=0,negative=false,previous=tenSecond
    for i in 0...1000 {
        let sample=state.advance(level:0,now:110+Double(i)/1000)
        if sample.amount<0 && !negative { negativeLobes+=1 }
        negative=sample.amount<0
        if ending == .cancelled { check(sample.amount>=0 && sample.amount<=previous+0.000001,"Cancel returns monotonically without overshoot") }
        previous=sample.amount
    }
    check(negativeLobes==(ending == .sent ? 1:0),"Send has exactly one negative lobe; cancel has none")
    let settled=state.sample(at:112)
    check(settled.amount==0 && !settled.needsFrames,"Completed return is exactly zero and releases the display clock")
}
var reducedCollapse=recording(100,reduced:true)
let reducedSample=reducedCollapse.sample(at:200)
check(reducedSample.amount==0 && reducedSample.streak==0,"Reduce Motion disables geometry and streaks")
check(reducedSample.vignette>0.22 && reducedSample.vignette<=0.25,"Reduce Motion bounds vignette to twenty-five percent")
reducedCollapse.configure(elapsed:nil,ending:.sent,reduced:true,now:200)
check(abs(reducedCollapse.sample(at:200.1).vignette-reducedSample.vignette*0.5)<0.00001,"Reduced-motion release is linear")
check(!reducedCollapse.sample(at:200.201).needsFrames,"Reduced-motion release ends in 0.2 seconds")
var interrupted=recording(10)
interrupted.configure(elapsed:nil,ending:.sent,reduced:false,now:110)
interrupted.configure(elapsed:nil,ending:.cancelled,reduced:false,now:110.03)
check(interrupted.sample(at:110.3).amount>=0,"Failure during send rebound switches to non-overshooting cancel")
var dropped=recording(10)
dropped.configure(elapsed:nil,ending:.sent,reduced:false,now:110)
let afterHitch=dropped.advance(level:.infinity,now:1000000)
check(afterHitch.amount.isFinite && afterHitch.amount==0 && !afterHitch.needsFrames,"Long frame gaps and invalid meters remain stable")
var waiting=PhosphorCollapse()
waiting.configure(elapsed:nil,ending:.cancelled,reduced:false,now:100)
check(waiting.sample(at:200).amount==0 && !waiting.sample(at:200).needsFrames,"Permission wait or unready capture never starts collapse")

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
var u=PhosphorUniforms(viewport:SIMD4(32,32,1,0),timing:SIMD4(0.5,0,0,1),regions:SIMD4(-1000,-900,-800,-700))
func render32(_ name:String,textures:[MTLTexture],direction:SIMD2<Float> = .zero)throws->MTLTexture{
    let out=texture(0,0,0,0),p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=out;p.colorAttachments[0].loadAction = .dontCare;p.colorAttachments[0].storeAction = .store
    let c=queue.makeCommandBuffer()!,e=c.makeRenderCommandEncoder(descriptor:p)!
    e.setRenderPipelineState(try pipeline(name));e.setFragmentBytes(&u,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
    for i in 0..<6{e.setFragmentTexture(i<textures.count ? textures[i]:textures[0],index:i)}
    var direction=direction;e.setFragmentBytes(&direction,length:8,index:0)
    e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding();c.commit();c.waitUntilCompleted()
    check(c.status == .completed,"GPU pass \(name) must complete")
    return out
}
func full(_ name:String,textures:[MTLTexture],direction:SIMD2<Float> = .zero)throws->[Float]{
    let base=try render32(name,textures:textures,direction:direction)
    if name == "phosphorCompositeFragment" {
        return values(try render32("phosphorLensFragment",textures:[base]))
    }
    return values(base)
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
let directClean=try full("phosphorDirectFragment",textures:[blank,ui,blank,blank,blank])
check(zip(clean,directClean).map{abs($0-$1)}.max()!<0.001,"Idle direct pass preserves the composed image without an extra optical pass")
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

// Coordinate-space regressions: a UI seed must not be warped before a second
// composite warp. Core, sharp UI and bloom must describe the same spatial point.
u.viewport.w=0
u.timing.z=1
let gradient=texture()
var gradientPixels=[Float16]()
for _ in 0..<32 { for x in 0..<32 { gradientPixels.append(contentsOf:[Float16(Float(x)/31),0,0,1]) } }
gradientPixels.withUnsafeBytes{gradient.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256)}
let originalSeed=try full("phosphorSeedFragment",textures:[blank,blank,gradient,blank])
u.collapse=SIMD4(0.08,16,16,0)
let collapsedSeed=try full("phosphorSeedFragment",textures:[blank,blank,gradient,blank])
check(originalSeed==collapsedSeed,"Bloom seed stays in source space; no double-warped UI halo")
let warpedUI=try full("phosphorCompositeFragment",textures:[blank,gradient,blank,blank,blank])
let warpedCore=try full("phosphorCompositeFragment",textures:[gradient,blank,blank,blank,blank])
let warpedBackground=try full("phosphorCompositeFragment",textures:[blank,blank,blank,blank,blank])
let warpedGlow=try full("phosphorCompositeFragment",textures:[blank,blank,gradient,blank,blank])
for y in 3..<29 { for x in 3..<29 {
    let i=(y*32+x)*4
    check(abs(warpedUI[i]-warpedCore[i])<0.001,"Core and artwork use one collapse map")
    check(abs(warpedGlow[i]-(warpedBackground[i]+(1-warpedBackground[i])*(1-exp(-warpedUI[i]*0.46))))<0.002,"Bloom and sharp content stay spatially aligned")
} }
check(abs(warpedUI[0]-Float(0.019/12.92))<0.0001,"Out-of-texture sharp samples return linear Theme.ink, not edge stripes")
check(abs(warpedGlow[0]-Float(0.019/12.92))<0.0001,"Out-of-texture bloom contributes no light beyond Theme.ink")
for status in [true,false] {
    u.regions=status ? SIMD4(12,20,-1000,-900):SIMD4(-1000,-900,12,20)
    let unpinned=try full("phosphorCompositeFragment",textures:[gradient,blank,blank,blank,blank])
    check(zip(unpinned,warpedCore).map{abs($0-$1)}.max()!<0.001,"Status and hold regions use the same global warp as the coil")
    check(abs(unpinned[(16*32+4)*4]-Float(4.0/31))>0.001,"Status, bar and timer follow the gentle global warp")
}
// Status regions must not flatten the background beneath them.
u.regions=SIMD4(0,32,-1000,-900)
let regionBackground=try full("phosphorCompositeFragment",textures:[blank,blank,blank,blank,blank])
u.collapse.x=0
let flatBackground=try full("phosphorCompositeFragment",textures:[blank,blank,blank,blank,blank])
check(zip(regionBackground,flatBackground).map{abs($0-$1)}.max()!>0.003,"Background bends through status and hold regions")
// Encode source coordinates as colors. A horizontal row must bow across the
// screen, not simply move/scale by one nearly constant affine transform.
u.regions=SIMD4(-1000,-900,-800,-700)
u.collapse.x=0.08
let coordinateGrid=texture()
var coordinatePixels=[Float16]()
for y in 0..<32 { for x in 0..<32 { coordinatePixels.append(contentsOf:[Float16(Float(x)/31),Float16(Float(y)/31),0,1]) } }
coordinatePixels.withUnsafeBytes{coordinateGrid.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256)}
let curved=try full("phosphorCompositeFragment",textures:[coordinateGrid,blank,blank,blank,blank])
let edgeIndex:Int=(8*32+26)*4+1
let middleIndex:Int=(8*32+16)*4+1
let bow:Float=abs(curved[edgeIndex]-curved[middleIndex])
check(bow>Float(0.001) && bow<Float(0.012),"Peripheral curvature is present but bounded to a gentle reminder")
// The focus must not retreat: verify an entire central patch, not one anchor.
for y in 12..<20 { for x in 12..<20 {
    let i=(y*32+x)*4
    check(abs(curved[i]-Float(x)/31)<0.001 && abs(curved[i+1]-Float(y)/31)<0.001,"Central focal area keeps its original size and coordinates")
} }
let checker=texture()
var checkerPixels=[Float16]()
for y in 0..<32 { for x in 0..<32 {
    let v:Float16=(x/2+y/2)%2 == 0 ? 0.1:0.7
    checkerPixels.append(contentsOf:[v,v,v,1])
} }
checkerPixels.withUnsafeBytes{checker.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256)}
let clearLens=try full("phosphorCompositeFragment",textures:[checker,blank,blank,blank,blank])
u.collapse.w=1
let softLens=try full("phosphorCompositeFragment",textures:[checker,blank,blank,blank,blank])
var chromatic:Float=0
for y in 0..<32 { for x in 0..<32 {
    let i=(y*32+x)*4
    chromatic=max(chromatic,abs(softLens[i]-softLens[i+1])+abs(softLens[i+2]-softLens[i+1]))
    if (12..<20).contains(x) && (12..<20).contains(y) {
        check(abs(softLens[i]-clearLens[i])<0.001,"Blur, dispersion and edge fade leave the focal area clear")
    }
} }
check(chromatic>0.004,"Peripheral blur separates RGB edges on a neutral source")
u.timing.z=0
let cleanLens=try full("phosphorCompositeFragment",textures:[checker,blank,blank,blank,blank])
var cleanChroma:Float=0
for i in stride(from:0,to:cleanLens.count,by:4){
    cleanChroma=max(cleanChroma,abs(cleanLens[i]-cleanLens[i+1])+abs(cleanLens[i+1]-cleanLens[i+2]))
}
check(cleanChroma>0.02,"Lens dispersion must remain visible with bloom disabled")
u.regions=SIMD4(-1000,-900,-800,-700)
u.collapse = SIMD4(0,16,16,0)
u.interaction.z=0.25
let darkened=try full("phosphorCompositeFragment",textures:[blank,ui,blank,blank,blank])
check(darkened[(16*32+16)*4]>0.249,"Reduced-motion vignette leaves the center sharp")
check(darkened[0]>=0.25*0.75-0.001 && darkened[0]<0.24,"Vignette dims edges by at most twenty-five percent")
u.interaction.z=0
u.timing.z=0

// Verify visibility at a real phone's point dimensions, not only a 32px fixture.
// A tiny test viewport made subpixel effects appear much larger than on-device.
let savedUniforms=u
let phoneWidth=390,phoneHeight=844
func phoneTexture()->MTLTexture{
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:phoneWidth,height:phoneHeight,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.renderTarget]
    return device.makeTexture(descriptor:descriptor)!
}
let phonePattern=phoneTexture()
var phonePixels=[Float16]()
phonePixels.reserveCapacity(phoneWidth*phoneHeight*4)
for y in 0..<phoneHeight { for x in 0..<phoneWidth {
    let v:Float16=(x%27<3 || y%34<2) ? 0.85:0.005
    phonePixels.append(contentsOf:[v,v,v,1])
} }
phonePixels.withUnsafeBytes{phonePattern.replace(region:MTLRegionMake2D(0,0,phoneWidth,phoneHeight),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:phoneWidth*8)}
func phonePass()->[Float]{
    let target=phoneTexture(),pass=MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
    let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:pass)!
    encoder.setRenderPipelineState(try! pipeline("phosphorCompositeFragment"))
    encoder.setFragmentBytes(&u,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
    for (i,texture) in [phonePattern,blank,blank,blank,blank,blank].enumerated(){encoder.setFragmentTexture(texture,index:i)}
    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
    let finished=phoneTexture(),optical=MTLRenderPassDescriptor()
    optical.colorAttachments[0].texture=finished;optical.colorAttachments[0].loadAction = .dontCare;optical.colorAttachments[0].storeAction = .store
    let lens=command.makeRenderCommandEncoder(descriptor:optical)!
    lens.setRenderPipelineState(try! pipeline("phosphorLensFragment"))
    lens.setFragmentBytes(&u,length:MemoryLayout<PhosphorUniforms>.stride,index:1);lens.setFragmentTexture(target,index:0)
    lens.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);lens.endEncoding()
    command.commit();command.waitUntilCompleted()
    check(command.status == .completed,"Phone-sized optical pass completes")
    var pixels=[UInt16](repeating:0,count:phoneWidth*phoneHeight*4)
    pixels.withUnsafeMutableBytes{finished.getBytes($0.baseAddress!,bytesPerRow:phoneWidth*8,from:MTLRegionMake2D(0,0,phoneWidth,phoneHeight),mipmapLevel:0)}
    return pixels.map{Float(Float16(bitPattern:$0))}
}
u.viewport=SIMD4(Float(phoneWidth),Float(phoneHeight),1,0)
u.timing.z=0 // Optical visibility is independent of the material's bloom.
u.collapse=SIMD4(Float(thirty.amount),195,440,0)
let phoneClear=phonePass()
u.collapse.w=Float(thirty.streak)
let phoneSoft=phonePass()
var visibleFringePixels=0,softenedPixels=0
var phoneChroma:Float=0
for y in 0..<phoneHeight { for x in 0..<phoneWidth {
    let i=(y*phoneWidth+x)*4
    let separation=max(abs(phoneSoft[i]-phoneSoft[i+1]),abs(phoneSoft[i+2]-phoneSoft[i+1]))
    phoneChroma=max(phoneChroma,separation)
    if separation>0.035 { visibleFringePixels+=1 }
    if phoneClear[i+1]<0.02 && phoneSoft[i+1]>0.08 { softenedPixels+=1 }
    if (155..<235).contains(x) && (400..<480).contains(y){
        check(abs(phoneSoft[i]-phoneClear[i])<0.001,"Phone-sized focal patch remains unchanged")
    }
} }
check(phoneChroma>0.05 && visibleFringePixels>500,"Thirty-second RGB fringes are visible at phone point scale")
check(softenedPixels>500,"Radial Gaussian softening spreads into neighboring pixels at phone point scale")
// Short speech must show optics too; a 30-second-only fixture missed the bug.
let fiveSecond=recording(5).sample(at:105)
u.collapse=SIMD4(Float(fiveSecond.amount),195,440,0)
let phoneShortClear=phonePass()
u.collapse.w=Float(fiveSecond.streak)
let phoneShortSoft=phonePass()
var shortFringes=0
var shortChroma:Float=0
for y in 0..<phoneHeight { for x in 0..<phoneWidth {
    let i=(y*phoneWidth+x)*4
    let separation=max(abs(phoneShortSoft[i]-phoneShortSoft[i+1]),abs(phoneShortSoft[i+2]-phoneShortSoft[i+1]))
    shortChroma=max(shortChroma,separation)
    if separation>0.025 { shortFringes+=1 }
    if (155..<235).contains(x) && (400..<480).contains(y){
        check(abs(phoneShortSoft[i]-phoneShortClear[i])<0.001,"Short-speech optics keep the focal patch clear")
    }
} }
check(shortChroma>0.06 && shortFringes>500,"Five-second RGB fringes are visible at actual phone point scale")
// A single thin feature must soften into ONE lobe per channel, not detached
// replicas. This catches the previous three-copy "mirror" ghosting.
var linePixels=[Float16]()
linePixels.reserveCapacity(phoneWidth*phoneHeight*4)
for _ in 0..<phoneHeight { for x in 0..<phoneWidth {
    let v:Float16=(22...24).contains(x) ? 0.85:0.005
    linePixels.append(contentsOf:[v,v,v,1])
} }
linePixels.withUnsafeBytes{phonePattern.replace(region:MTLRegionMake2D(0,0,phoneWidth,phoneHeight),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:phoneWidth*8)}
u.collapse=SIMD4(0,195,440,1)
let softenedLine=phonePass()
for channel in 0..<3 {
    var groups=0,inside=false
    for x in 8..<41 {
        let bright=softenedLine[(440*phoneWidth+x)*4+channel]>0.12
        if bright && !inside { groups+=1 }
        inside=bright
    }
    check(groups==1,"RGB blur must form a single soft feature rather than separated ghost copies")
}
// Test the user's short recordings at actual point scale. Merely having a
// mathematically nonzero UV offset is insufficient: horizontal rows must bow.
var phoneCoordinates=[Float16]()
phoneCoordinates.reserveCapacity(phoneWidth*phoneHeight*4)
for y in 0..<phoneHeight { for x in 0..<phoneWidth {
    phoneCoordinates.append(contentsOf:[Float16(Float(x)/Float(phoneWidth-1)),Float16(Float(y)/Float(phoneHeight-1)),0,1])
} }
phoneCoordinates.withUnsafeBytes{phonePattern.replace(region:MTLRegionMake2D(0,0,phoneWidth,phoneHeight),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:phoneWidth*8)}
u.collapse.x=Float(recording(5).sample(at:105).amount)
u.collapse.w=0
let shortSpeechGeometry=phonePass()
for y in [110,760] {
    let edge:Int=(y*phoneWidth+30)*4+1
    let middle:Int=(y*phoneWidth+195)*4+1
    let bowInPoints=abs(shortSpeechGeometry[edge]-shortSpeechGeometry[middle])*Float(phoneHeight-1)
    check(bowInPoints>1.5 && bowInPoints<9,"Five-second speech visibly bows top and bottom rows while staying gentle")
}
print("Phone-sized optics and visible five-second curvature passed")
u=savedUniforms

let core=texture(0,0,0,0),emission=texture(0,0,0,0)
let p=MTLRenderPassDescriptor()
for (i,t) in [core,emission].enumerated(){p.colorAttachments[i].texture=t;p.colorAttachments[i].loadAction = .clear;p.colorAttachments[i].storeAction = .store;p.colorAttachments[i].clearColor=MTLClearColorMake(0,0,0,0)}
let depthDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:32,height:32,mipmapped:false)
depthDescriptor.storageMode = .private;depthDescriptor.usage = .renderTarget
p.depthAttachment.texture=device.makeTexture(descriptor:depthDescriptor);p.depthAttachment.loadAction = .clear;p.depthAttachment.clearDepth=1
var stroke=PhosphorStroke(start:SIMD4(4,16,0,2),end:SIMD4(28,16,0,0),color:SIMD4(1,0.068,0,1),material:SIMD4(6,1,0,0))
let buffer=device.makeBuffer(bytes:&stroke,length:64)!,command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:p)!
encoder.setRenderPipelineState(try pipeline("phosphorStrokeFragment",mrt:true));encoder.setVertexBuffer(buffer,offset:0,index:0)
encoder.setVertexBytes(&u,length:MemoryLayout<PhosphorUniforms>.stride,index:1);encoder.setFragmentBytes(&u,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6);encoder.endEncoding();command.commit();command.waitUntilCompleted()
check(command.status == .completed,"Wireframe MRT draw must complete")
let coreValues=values(core),emitted=values(emission),center=(16*32+16)*4
check(coreValues[center]>0.7 && coreValues[center]<=1,"Sharp wire core must remain bounded")
check(emitted[center]>4,"Emission must retain energy beyond SDR white")
print("Phosphor: collapse lifecycle, single overshoot, reduced motion, GPU warp/halo alignment, fixed focus, peripheral stretch/blur/RGB dispersion, whole-page UI warp, border ink, spatial geometry, original anchors, ABI, HDR MRT, decay/reset, blur halo, clean colors and visible CRT passed")
