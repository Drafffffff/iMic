import SwiftUI
import QuartzCore
import simd

/// One geometry snapshot drives both the GPU wireframe and CPU glyph anchors.
@MainActor
final class PhosphorScene {
    private(set) var rings: [PhosphorRing] = []
    private(set) var strokes: [PhosphorStroke] = []
    private(set) var camera = PhosphorCamera(center: .zero)
    var frameTime: Double = 0
    var clearOpacity: Float = 1
    var effect: PhosphorEffect = .crt
    var reduceTransparency = false
    var clearProgress:Float=0
    var attachStyle:PhosphorAttachStyle = .flow
    private var press=PhosphorPressSpring()

    func setPressed(_ pressed:Bool,now:Double){press.set(pressed:pressed,at:now)}

    /// Processing: the Mac is still receiving, recognizing or polishing the load. Ready: it is
    /// done and the load can be shot. Both are drawn on the coil itself, never as extra UI.
    private var processing=false,processingChanged = -10.0
    private var ready=false,readyChanged = -10.0
    func setStatus(processing:Bool,ready:Bool,now:Double){
        if processing != self.processing {self.processing=processing;processingChanged=now}
        if ready != self.ready {self.ready=ready;readyChanged=now}
    }
    /// The sweep needs the display clock; the ready breath rides the ambient clock instead.
    func needsStatusFrames(at now:Double)->Bool{
        processing || now-processingChanged<0.3 || (ready && now-readyChanged<0.7)
    }
    func pressScale(at now:Double)->Float{Float(press.value(at:now).0)}

    private let orange = SIMD3<Float>(1, PhosphorMath.linear(0.29), 0)
    private let ivory = SIMD3<Float>(PhosphorMath.linear(0.95), PhosphorMath.linear(0.94), PhosphorMath.linear(0.90))
    /// Attached text: a hot spot on the orange phosphor rather than a white mark on it.
    private let amber = SIMD3<Float>(1, PhosphorMath.linear(0.66), PhosphorMath.linear(0.36))

    /// Older landings on a long load still exist as glyphs; only the newest light the wire.
    static let contactsPerRing=10
    static let arcLength:Float=14
    static let arcSegments=10

    init() { rings.reserveCapacity(44); strokes.reserveCapacity(7000) }

    func update(spectrum: SpectrumStore, torus: CGRect, size: CGSize,
                reduced: Bool, dimmed: Bool, scale: CGFloat) {
        let motion=spectrum.stringMotion
        let layout=TorusGeometry.Layout(size:torus.size,frame:spectrum.frame,pull:motion.pull,
            anchor:motion.anchor,reducedMotion:reduced,extendedUpward:true,
            upwardTravel:motion.upwardTravel ?? max(1,torus.midY-84))
        camera=PhosphorCamera(center:SIMD2(Float(torus.midX),Float(torus.midY)))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-scene-view=side") { camera.yaw = .pi/2 }
        if ProcessInfo.processInfo.arguments.contains("--debug-scene-view=oblique") { camera.yaw = .pi/5 }
        #endif
        frameTime=spectrum.frame.time;clearOpacity=Float(motion.clearOpacity)
        strokes.removeAll(keepingCapacity:true);rings.removeAll(keepingCapacity:true)
        let color=dimmed ? SIMD3<Float>(repeating:0.27) : orange
        var depth:Float=0
        var last:CGPoint?
        for i in 0..<TorusGeometry.ringCount {
            let r=layout.ring(at:i)
            if let last {
                let ratio=min(0.8,Float(r.radiusX/max(1,r.radiusY)))
                depth-=Float(hypot(r.center.x-last.x,r.center.y-last.y))*ratio/sqrt(1-ratio*ratio)
            }
            last=r.center
            rings.append(PhosphorMath.ring(center:CGPoint(x:torus.minX+r.center.x,y:torus.minY+r.center.y),
                radiusX:r.radiusX,radiusY:r.radiusY,rotation:r.rotation,depth:depth,opacity:r.opacity))
        }
        let phase=reduced ? 0.28 : CGFloat(spectrum.frame.time.truncatingRemainder(dividingBy:6)/6)
        let ambient=reduced || dimmed ? 0 : spectrum.frame.ambientIntensity
        let status=statusFrame(at:CACurrentMediaTime(),reduced:reduced||dimmed,ambient:Float(ambient))
        for i in rings.indices {
            let r=rings[i]
            let ink=dimmed ? 0 : spectrum.ink.intensity(at:i)
            let distance=CGFloat(i)/43-phase
            let scan=exp(-distance*distance/0.004)*0.20*ambient
            let alpha=Float(min(1,CGFloat(r.opacity)+0.12+(1-CGFloat(r.opacity))*ink*0.82+scan))*clearOpacity
            // The release shockwave turns whole rings white-hot as it travels along the coil.
            let wave=reduced || dimmed ? 0 : Float(min(1,spectrum.ink.releaseWave(at:i)))
            let band=status.band(at:Float(i)/Float(TorusGeometry.ringCount-1))
            let heat=max(wave,band*0.6,status.burst*0.65)
            let charge=dimmed ? 0 : spectrum.ink.chargeGlow
            let contacts=dimmed ? 0 : spectrum.ink.contactCount(at:i)
            let now=CACurrentMediaTime()
            // Ring charge: landed text warms its whole ring instead of leaving a spot. The load
            // spreads to neighbors, so a long passage heats the coil as one continuous gradient.
            var loaded:Float=0
            if attachStyle == .charge && !dimmed {
                let stored=1-exp(-Float(spectrum.ink.load(at:i))*2.4)
                let newest=contacts>0 ? spectrum.ink.contact(at:i,slot:contacts-1)?.born:nil
                let hit=reduced ? 0:newest.map{exp(-Float(now-$0)/0.14)} ?? 0
                loaded=min(1,stored*(1-0.5*status.processing)*status.breath*(1+Float(charge)*0.6)+hit*0.4)
            }
            var base=color+(amber-color)*loaded*0.6
            base+=(ivory-base)*loaded*Float(charge)*0.45
            let ringColor=base+(ivory-base)*heat
            var previous=r.point(0)
            for j in 1...96 {
                let angle=Float(j)*2 * .pi/96,p=r.point(angle)
                let front=0.62+0.38*(0.5+0.5*cos(angle))
                line(previous,p,color:ringColor,alpha:min(1,alpha*front+heat*0.5+loaded*0.15),width:1.3+heat*0.9,
                     energy:dimmed ? 0 : 2.9+Float(ink)*2+heat*5+loaded*1.8)
                previous=p
            }
            let accent=reduced || dimmed ? 0 : spectrum.ink.accent(at:i)
            if accent>0.01 {
                arc(r,from:-Float.pi/2-0.28,to:-Float.pi/2+0.28,color:ivory,
                    alpha:Float(accent)*0.68*clearOpacity,width:1.3,energy:4)
            }
            if contacts>0 && attachStyle != .charge {
                // The arc pushed past the limit by the newest landing fades out instead of popping.
                let evicted=contacts-Self.contactsPerRing-1
                let newest=spectrum.ink.contact(at:i,slot:contacts-1)?.born ?? now
                let fadeOut=reduced ? 0:1-PhosphorMath.smooth(Float(now-newest)/0.3)
                for slot in max(0,evicted)..<contacts {
                    guard let c=spectrum.ink.contact(at:i,slot:slot) else {continue}
                    let gain=status.arcGain(band:band)*(slot==evicted ? fadeOut:1)
                    guard gain>0.001 else {continue}
                    let angle=attachStyle == .flow ? PhosphorAttachStyle.flowAngle(c.angle,phase:c.phase,now:frameTime):c.angle
                    lightArc(r,angle:Float(angle),age:Float(now-c.born),charge:Float(charge),reduced:reduced,gain:gain)
                }
            }
            // The landing flash belongs to the light arc alone; a second, wider impact arc
            // at a different timing made each arrival flicker. The fallback Canvas keeps it.
        }
        // Peripheral orbit tracks keep their existing fixed-end bend and timing.
        for offset in [CGFloat(-0.62),CGFloat(0.62)] {
            let separation=offset*layout.baseRy*(0.72+0.28*layout.relief.presence)*(1-layout.longStretch*0.94)
            var previous:SIMD3<Float>?
            for j in 0...96 {
                let angle=CGFloat(j)*2 * .pi/96
                let x=layout.cx+cos(angle)*layout.bar/2
                let y=layout.stringY(at:x)+separation+sin(angle)*layout.orbitHeight*(1-layout.longStretch*0.94)/2
                let p=SIMD3(Float(torus.minX+x),Float(torus.minY+y),sin(Float(angle))*8)
                if let previous {
                    let light=Float(PhosphorOrbitLight.depthGain(angle - .pi/96))
                    line(previous,p,color:color,alpha:0.26*light*clearOpacity,width:0.7,energy:0.9)
                }
                previous=p
            }
            // The two glints from the original Canvas: they circle the upper and lower orbits in
            // opposite directions on the ambient clock and rest with it. A tapered tail
            // reads in either direction; the far half is dimmer than the near half.
            if ambient>0 {
                let direction:CGFloat=offset<0 ? 1:-1
                let head=phase*2 * .pi*direction
                var last:SIMD3<Float>?
                for sample in 0...PhosphorOrbitLight.segments {
                    let t=CGFloat(sample)/CGFloat(PhosphorOrbitLight.segments)
                    let a=PhosphorOrbitLight.angle(head:head,direction:direction,progress:t)
                    let x=layout.cx+cos(a)*layout.bar/2
                    let y=layout.stringY(at:x)+separation+sin(a)*layout.orbitHeight*(1-layout.longStretch*0.94)/2
                    // A tiny depth offset prevents the glint fighting its own orbit track.
                    let p=SIMD3(Float(torus.minX+x),Float(torus.minY+y),sin(Float(a))*8+0.25)
                    if let last {
                        let fade=PhosphorOrbitLight.tailGain(t)*PhosphorOrbitLight.depthGain(a)
                        line(last,p,color:color,alpha:Float(0.9*ambient*fade)*clearOpacity,
                             width:Float(0.8+0.7*t),energy:Float(1+3.5*t))
                    }
                    last=p
                }
            }
        }
        var previous:SIMD3<Float>?
        for x in stride(from:layout.leftRail,through:layout.rightRail,by:2) {
            let p=SIMD3(Float(torus.minX+x),Float(torus.minY+layout.stringY(at:x)),0)
            if let previous {line(previous,p,color:color,alpha:Float(0.38+0.4*(motion.armed ? 1:0.35+0.65*layout.level))*clearOpacity,width:0.8,energy:1.6)}
            previous=p
        }
        // HUD marks are screen-space and snapped identically on both sides.
        let pixel=1/max(1,scale),width=Float(2*pixel)
        func snap(_ p:CGFloat)->Float{Float((p*scale).rounded()/scale)}
        let cy=snap(torus.minY+layout.cy),top=snap(torus.minY+layout.rulerTop),bottom=snap(torus.minY+layout.rulerBottom)
        for (side,x) in [layout.leftRail,layout.rightRail].enumerated() {
            let x=snap(torus.minX+x)
            flat(SIMD2(x,top),SIMD2(x,bottom),color:color,alpha:0.48,width:width,energy:0.32)
            let count=Int(floor(min(cy-top,bottom-cy)/10))
            for ordinal in -count...count where ordinal != 0 {
                let y=cy+Float(ordinal)*10
                guard y>top+5 && y<bottom-5 else{continue}
                let major=abs(ordinal)%5==0,length:Float=major ? 7:4
                flat(SIMD2(side==0 ? x:x-length,y),SIMD2(side==0 ? x+length:x,y),color:color,
                     alpha:major ? 0.48:0.30,width:width,energy:0.22)
            }
            for y in [top,bottom,cy] {
                flat(SIMD2(x-2.5,y),SIMD2(x+2.5,y),color:color,alpha:clearOpacity,width:5,energy:y==cy ? 2:0.7)
            }
        }
    }

    func attachment(ring:Int,angle:CGFloat)->SIMD3<Float>{camera.project(rings[ring].point(Float(angle)))}
    func headerSignal(content:CGRect,connected:Bool,ambient:CGFloat,reduced:Bool){
        let width=Float(content.width-48),y=Float(content.minY+85)
        let alpha:Float=reduced ? 0.3:0.24+0.12*sin(Float(frameTime)*Float.pi/3)*Float(ambient)
        flat(SIMD2(24+width*0.67,y),SIMD2(24+width*0.90,y),
             color:connected ? orange:SIMD3(repeating:0.27),alpha:alpha,width:0.7,energy:0.5)
    }
    /// An attached glyph is a short light on its own ring, sampled from the exact ring
    /// equation so it lies on the wire at any pull, depth or camera yaw. Its angular span
    /// keeps a constant on-screen length, matching the glyph that collapsed into it.
    private struct StatusFrame {
        var processing:Float=0,sweep:Float = -1,confirm:Float=0,confirmAt:Float = -1,breath:Float=1
        /// Whole-coil flash when polishing completes: unmistakable, then gone within 0.4s.
        var burst:Float=0
        func band(at position:Float)->Float{
            let s=(position-sweep)/0.07,c=(position-confirmAt)/0.09
            return max(processing*exp(-s*s),confirm*exp(-c*c))
        }
        /// Arcs wait at half light while processing and light up as the sweep reads them.
        func arcGain(band:Float)->Float{(1-0.5*processing+0.9*band+1.6*burst)*breath}
    }

    private func statusFrame(at now:Double,reduced:Bool,ambient:Float)->StatusFrame{
        var frame=StatusFrame()
        let fade=PhosphorMath.smooth(Float((now-processingChanged)/0.25))
        frame.processing=reduced ? (processing ? 1:0) : (processing ? fade:1-fade)
        guard !reduced else {return frame}
        // A left-to-right reading sweep, entering and leaving beyond both ends of the coil.
        frame.sweep=Float(now.truncatingRemainder(dividingBy:1.2)/1.2)*1.3-0.15
        if ready {
            let age=Float(now-readyChanged)
            frame.confirmAt=age/0.45*1.3-0.15
            frame.confirm=1-PhosphorMath.smooth(age/0.6)
            frame.burst=pow(1-PhosphorMath.smooth(age/0.4),2)
            frame.breath=1+0.1*sin(Float(now)*2 * .pi*0.5)*ambient*PhosphorMath.smooth((age-0.5)/0.4)
        }
        return frame
    }

    private func lightArc(_ r:PhosphorRing,angle:Float,age:Float,charge:Float,reduced:Bool,gain:Float=1){
        let tangent = -sin(angle)*r.u+cos(angle)*r.v
        let perRadian=max(1,r.radius*simd_length(SIMD2(tangent.x,tangent.y)))
        let grow=reduced ? 1:PhosphorMath.smooth(age/0.13)
        let half=min(0.6,max(0.05,Self.arcLength/2/perRadian))*(0.2+0.8*grow)
        let facing=0.5+0.5*max(0,cos(angle))
        let flash=reduced ? 0:exp(-max(0,age)/0.09)
        let level=min(1,(0.72+0.28*charge+0.5*flash)*facing*gain)*clearOpacity
        var a=r.point(angle-half)
        for j in 1...Self.arcSegments {
            let t=Float(j)/Float(Self.arcSegments)
            let b=r.point(angle-half+2*half*t)
            // A soft-edged spot: brightest at the landing point, fading to both tips.
            let mid=t-0.5/Float(Self.arcSegments),bell=exp(-pow((mid-0.5)/0.32,2))
            // Amber at rest; pulling the string heats it toward white. Arcs share one flat depth in
            // front of every wire: breathing neighbors cannot cut them frame by frame, and their
            // own segments cannot punch holes into each other at the joints.
            let core=amber+(ivory-amber)*min(1,charge*0.8+flash*0.5)
            let pa=camera.project(a),pb=camera.project(b)
            let sa=SIMD2(pa.x,pa.y),sb=SIMD2(pb.x,pb.y)
            flat(sa,sb,color:orange,alpha:level*0.45*bell,width:3.4+charge,energy:1.4)
            flat(sa,sb,color:core,alpha:level*bell,width:1.7+charge*0.5,energy:3.4+charge*2.5+flash*3)
            a=b
        }
    }
    private func arc(_ r:PhosphorRing,from:Float,to:Float,color:SIMD3<Float>,alpha:Float,width:Float,energy:Float){
        var a=r.point(from)
        for j in 1...8{let b=r.point(from+(to-from)*Float(j)/8);line(a,b,color:color,alpha:alpha,width:width,energy:energy);a=b}
    }
    private func line(_ a:SIMD3<Float>,_ b:SIMD3<Float>,color:SIMD3<Float>,alpha:Float,width:Float,energy:Float){
        let a=camera.project(a),b=camera.project(b)
        strokes.append(PhosphorStroke(start:SIMD4(a,width),end:SIMD4(b,0),color:SIMD4(color,alpha),material:SIMD4(energy,1,0,0)))
    }
    private func flat(_ a:SIMD2<Float>,_ b:SIMD2<Float>,color:SIMD3<Float>,alpha:Float,width:Float,energy:Float){
        strokes.append(PhosphorStroke(start:SIMD4(a.x,a.y,1024,width),end:SIMD4(b.x,b.y,1024,0),color:SIMD4(color,alpha),material:SIMD4(energy,0,0,0)))
    }
}

/// How landed text stays on the coil until it is shot. A display preference for comparison.
enum PhosphorAttachStyle: String, CaseIterable {
    case charge, flow, arc
    static let preferenceKey="imic.display.attach"
    var label:String{switch self{case .charge:return "CHARGE";case .flow:return "FLOW";case .arc:return "ARC"}}
    var title:String{switch self{case .charge:return L10n.text("Full ring");case .flow:return L10n.text("Flowing arc");case .arc:return L10n.text("Fixed arc")}}

    /// Flowing arcs circle their ring on the ambient clock (it slows to rest with the HUD and
    /// never runs under Reduce Motion). Half go each way, at slightly different speeds; the
    /// angle equals the landing angle at landing, so the glyph meets its arc exactly.
    static func flowAngle(_ angle:CGFloat,phase:Double,now:Double)->CGFloat{
        let hash=abs((sin(Double(angle)*12.9898)*43758.5453).truncatingRemainder(dividingBy:1))
        let direction:Double=hash<0.5 ? 1:-1
        return angle+CGFloat(direction*(0.35+0.3*hash)*max(0,now-phase))
    }
}

enum PhosphorEffect: String, CaseIterable {
    case clean, glow, crt
    static let preferenceKey="imic.display.material"
    var crtStrength:Float{self == .crt ? 0.82:0}
    var bloomStrength:Float{self == .clean ? 0:0.5}
    var title:String{switch self{case .clean:return L10n.text("Clear");case .glow:return L10n.text("Phosphor");case .crt:return L10n.text("Phosphor CRT")}}
    var label:String{rawValue.uppercased()}
}
