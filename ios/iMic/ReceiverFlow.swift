import SwiftUI
import UIKit
import QuartzCore
import simd

/// Visual history is independent of the complete recognition result. Corrections never
/// pull a launched word backwards; every newly appended grapheme enters the next load.
@MainActor
final class ReceiverFlowStore: ObservableObject {
    @Published private(set) var unifiedAvailable = true
    fileprivate func unavailable() { unifiedAvailable = false }
    fileprivate weak var renderer: ReceiverFlowSurface?
    private var previous = ""
    private var previousCount = 0
    private var pending: [Character] = []
    private var pendingHead = 0
    private var suspended = false
    fileprivate var hasPending: Bool { pendingHead < pending.count }
    fileprivate var sourceTouchFraction: CGFloat?

    func updateTouch(xFraction: CGFloat) {
        sourceTouchFraction = xFraction.isFinite ? min(1, max(0, xFraction)) : nil
    }

    func update(text: String) {
        guard !suspended, text != previous else { return }
        let revision = TextRevision(from: previous, to: text)
        let count = previousCount - revision.deleteCount + revision.insertion.count
        let appended = max(0, count - previousCount)
        if appended > 0 {
            if pendingHead == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingHead = 0
            } else if pendingHead > 512, pendingHead > pending.count / 2 {
                pending.removeFirst(pendingHead)
                pendingHead = 0
            }
            for character in revision.insertion.suffix(appended)
                where !character.isWhitespace && !character.isPunctuation {
                pending.append(character)
            }
        }
        previous = text
        previousCount = count
        renderer?.wake()
    }

    func reset() {
        // Keep the touch anchor: listening resets after touchDown, and recognition can
        // continue delivering text after touchUp. The next press supplies a new anchor.
        previous = ""
        previousCount = 0
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        suspended = false
        renderer?.reset()
    }

    /// The caller has validated and queued Return at the first upward neutral crossing.
    func fire() { renderer?.fire() }

    func cancelFlight() {
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        suspended = true
        renderer?.reset()
    }

    fileprivate func peekCharacter(offset: Int = 0) -> Character? {
        let index = pendingHead + offset
        return index < pending.count ? pending[index] : nil
    }

    fileprivate func consumeCharacter() { pendingHead += 1 }
}

struct ReceiverFlowView: UIViewRepresentable {
    let store: ReceiverFlowStore
    let spectrum: SpectrumStore
    let torusFrame: CGRect
    let sourceFrame: CGRect
    var artwork: PhosphorArtworkState? = nil
    var dimmed = false
    var effect: PhosphorEffect = .crt
    var clearEnabled = false
    var pressed = false
    var processing = false
    var ready = false
    var attach: PhosphorAttachStyle = .flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context: Context) -> ReceiverFlowSurface {
        let view = ReceiverFlowSurface()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ReceiverFlowSurface, context: Context) {
        view.configure(store: store, spectrum: spectrum, torus: torusFrame,
                       source: sourceFrame, reduced: reduceMotion, artwork: artwork,
                       dimmed: dimmed, effect: effect, reduceTransparency: reduceTransparency,
                       clearEnabled: clearEnabled, pressed: pressed,
                       processing: processing, ready: ready, attach: attach)
    }

    static func dismantleUIView(_ view: ReceiverFlowSurface, coordinator: ()) { view.detach() }
}

/// The wave retains its fixed endpoints. Only text receives the release impulse.
/// State and atlas capacity grow on ingestion; normal frames reuse all CPU/GPU storage.
@MainActor
final class ReceiverFlowSurface: UIView, StringMotionRendering {
    var needsStringMotionFrames: Bool {
        guard drawing != nil, window != nil, positioned else { return false }
        return store?.hasPending == true || spectrum?.ink.releaseWaveActive == true
            || (artworkState != nil && scene.needsStatusFrames(at: CACurrentMediaTime()))
            || particles.contains { $0.phase != .attached || CGFloat(CACurrentMediaTime() - $0.started) < $0.duration + 0.3 }
            || !debris.isEmpty
    }

    func wake() { spectrum?.wake() }
    // Large enough to read on the coil (≈11.5pt), still smaller than the ring spacing.
    nonisolated private static let attachedScale: CGFloat = 0.72
    nonisolated private static let entryScale: CGFloat = 2.4
    nonisolated private static let baseSide: CGFloat = 16
    // A glyph shot from its arc starts small and grows into the readable exit size.
    nonisolated private static let launchSide: CGFloat = 7

    private enum Phase { case incoming, attached, projectile }
    private struct Particle {
        let glyph: WaveGlyphTexture
        let ring: Int
        let angle: CGFloat
        let seed: CGFloat
        var phase: Phase = .incoming
        var origin: CGPoint
        var position: CGPoint
        var started: Double
        var duration: Double
        var scale: CGFloat = ReceiverFlowSurface.entryScale
        var flightProgress: CGFloat = 0
        var opacity: CGFloat = 0
        var startScale: CGFloat = ReceiverFlowSurface.entryScale
        var startOpacity: CGFloat = 0
        var rotation: CGFloat = 0
        var velocity = CGVector.zero
        var arrow = ReceiverArrowFlight(speed: 0)
        var launchRotation: CGFloat = 0
        var flightTilt: CGFloat = 0
        var flightBend: CGFloat = 0
        var flightSpin: CGFloat = 0
        var exitScale: CGFloat = ReceiverFlowSurface.attachedScale
        var emphasis: CGFloat = 1
        var squash: CGFloat = 1
        var thickness: CGFloat = 1
        var landPhase: Double = 0
    }

    /// Embers shed by a release. They pop out of the launch point or break off a
    /// glyph early in its flight, then fall under gravity while cooling from
    /// near-white to orange, so the burst keeps weight after the text has gone.
    private struct Debris {
        var origin: CGPoint
        var velocity: CGVector
        var born: Double
        var life: Double
        var side: CGFloat
        var spin: CGFloat
        var heat: CGFloat
    }
    nonisolated private static let debrisGlyph: Character = "■"
    nonisolated private static let debrisBudget = 140
    nonisolated private static let gravity: CGFloat = 1500

    /// Where an attached glyph sits on its projected wire. The glyph's up axis follows the
    /// ring tangent and is foreshortened with it, so text wraps around the coil in 3D.
    private struct WirePose {
        var center: CGPoint
        var rotation: CGFloat
        var squash: CGFloat
        var facing: CGFloat
        var normal: CGVector
    }

    private weak var store: ReceiverFlowStore?
    private weak var spectrum: SpectrumStore?
    private let canvas = WaveTextCanvas()
    private var drawing: WaveTextRenderer?
    private let scene = PhosphorScene()
    private var artworkState: PhosphorArtworkState?
    private var pendingArtwork: PhosphorArtworkState?
    private var artworkFailures=0
    private var elapsedText=""
    private var clearArtworkWidth:CGFloat=0
    private var clearEnabled=false
    private var dimmed = false
    private var textClearOpacity: Float = 1
    private var particles: [Particle] = []
    private var debris: [Debris] = []
    private var draws: [WaveGlyphDraw] = []
    private var exposures: [WaveGlyphSample] = []
    private let shutter = ReceiverShutter()
    private var rings: [TorusGeometry.Ring] = []
    private var torus = CGRect.zero
    private var source = CGRect.zero
    private var reduced = false
    private var positioned = false
    private var hadVisibleText = false
    private var wasPendingReturn = false
    private var ordinal: UInt64 = 0
    private var placementSeed = UInt64.random(in: .min ... .max)
    private var reportedRenderFailure = false
    private let cpuMetrics = PhosphorMetrics(label: "frame CPU")

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        addSubview(canvas)
        particles.reserveCapacity(512)
        draws.reserveCapacity(1024)
        exposures.reserveCapacity(512 + 64 * ReceiverShutter.maximumSamples)
        do { drawing = try WaveTextRenderer(view: canvas) }
        catch { IMicLog.write("iphone.visual", "text renderer unavailable: \(error)") }
        debris.reserveCapacity(Self.debrisBudget)
        drawing?.prepare(Self.debrisGlyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
    }

    func configure(store: ReceiverFlowStore, spectrum: SpectrumStore,
                   torus: CGRect, source: CGRect, reduced: Bool,
                   artwork: PhosphorArtworkState? = nil, dimmed: Bool = false,
                   effect: PhosphorEffect = .crt, reduceTransparency: Bool = false,
                   clearEnabled:Bool=false, pressed:Bool=false,
                   processing:Bool=false, ready:Bool=false, attach:PhosphorAttachStyle = .flow) {
        if scene.attachStyle != attach { scene.attachStyle = attach; spectrum.wake() }
        let changed = self.store !== store || self.spectrum !== spectrum || self.torus != torus
            || self.source != source || self.reduced != reduced
        if self.store !== store || self.spectrum !== spectrum {
            detach()
            self.store = store
            self.spectrum = spectrum
            store.renderer = self
            spectrum.stringMotion.renderer = self
        }
        self.torus = torus
        self.source = source
        self.dimmed = dimmed
        self.clearEnabled=clearEnabled
        scene.setPressed(pressed,now:CACurrentMediaTime())
        scene.setStatus(processing:processing,ready:ready,now:CACurrentMediaTime())
        if scene.needsStatusFrames(at:CACurrentMediaTime()) { spectrum.wake() }
        let materialChanged = scene.effect != effect || scene.reduceTransparency != reduceTransparency
        scene.effect = effect
        scene.reduceTransparency = reduceTransparency
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-display=clean") { scene.effect = .clean }
        if ProcessInfo.processInfo.arguments.contains("--debug-display=glow") { scene.effect = .glow }
        #endif
        if let artwork {
            if artwork.listening {
                if elapsedText != artwork.elapsed { elapsedText=artwork.elapsed;spectrum.wake() }
                for character in "0123456789.s" { drawing?.prepare(character) }
            }else{elapsedText=""}
            if artworkState?.sameRaster(as:artwork) != true { pendingArtwork=artwork;spectrum.wake() }
        }
        if drawing == nil {
            DispatchQueue.main.async { [weak store] in store?.unavailable() }
        }
        spectrum.ink.reduceMotion = reduced
        if self.reduced != reduced {
            self.reduced = reduced
            if reduced {
                particles.removeAll { $0.phase == .projectile }
                for index in particles.indices where particles[index].phase == .incoming {
                    particles[index].phase = .attached
                    particles[index].landPhase = spectrum.frame.time
                    spectrum.ink.deposit(at: particles[index].ring, angle: particles[index].angle, weight: 0.65,
                                         phase: spectrum.frame.time)
                }
            }
        }
        positioned = torus.width > 0 && torus.height > 0
        if changed || materialChanged { spectrum.wake() }
    }

    func detach() {
        if store?.renderer === self { store?.renderer = nil }
        if spectrum?.stringMotion.renderer === self {
            spectrum?.stringMotion.renderer = nil
            spectrum?.ink.reset()
        }
        store = nil
        spectrum = nil
    }

    private func updateArtwork(_ artwork:PhosphorArtworkState,drawing:WaveTextRenderer){
        guard artwork.size.width>10,artwork.size.height>10 else{return}
        let began=CACurrentMediaTime()
        defer{
            let ms=(CACurrentMediaTime()-began)*1000
            if ms>8{IMicLog.write("iphone.visual",String(format:"artwork raster %.1fms",ms))}
        }
        let scale=window?.screen.scale ?? traitCollection.displayScale
        if let old=artworkState,clearArtworkWidth==artwork.size.width,let dirty=artwork.dirtyRegions(from:old){
            do{
                for region in dirty{ try patchArtwork(artwork,region:region,scale:scale,drawing:drawing) }
                artworkState=artwork;pendingArtwork=nil;artworkFailures=0
                return
            }catch{
                IMicLog.write("iphone.visual","artwork patch failed, redrawing: \(error)")
            }
        }
        let image=ImageRenderer(content:PhosphorArtwork(state:artwork).environment(\.displayScale,scale))
        image.scale=scale;image.isOpaque=true;image.colorMode = .nonLinear
        image.proposedSize=ProposedViewSize(artwork.size)
        do{
            guard let cg=image.cgImage else{throw WaveTextRenderer.RenderError.allocation}
            try drawing.setArtwork(cg,status:artwork.statusBounds,action:artwork.actionBounds)
            if clearArtworkWidth != artwork.size.width{
                let clear=ImageRenderer(content:PhosphorClearArtwork(width:artwork.size.width))
                clear.scale=scale;clear.proposedSize=ProposedViewSize(width:artwork.size.width,height:84)
                if let cg=clear.cgImage{try drawing.setClearArtwork(cg);clearArtworkWidth=artwork.size.width}
            }
            artworkState=artwork;pendingArtwork=nil;artworkFailures=0
            canvas.metalLayer.isOpaque=true;canvas.isOpaque=true
        }catch{
            artworkFailures+=1
            if artworkFailures==3 {
                IMicLog.write("iphone.visual","artwork failed at \(artwork.size): \(error)")
                DispatchQueue.main.async { [weak store] in store?.unavailable() }
            }
        }
    }

    /// Rasterize only `region` of the full artwork: the same view, offset and clipped, so the
    /// grid and every element stay aligned with the untouched pixels around it.
    private func patchArtwork(_ artwork:PhosphorArtworkState,region:CGRect,scale:CGFloat,drawing:WaveTextRenderer)throws{
        let bounds=CGRect(origin:.zero,size:artwork.size)
        let r=region.intersection(bounds)
        let snapped=CGRect(x:floor(r.minX),y:floor(r.minY),width:ceil(r.maxX)-floor(r.minX),height:ceil(r.maxY)-floor(r.minY))
        guard snapped.width>0,snapped.height>0 else{return}
        let view=PhosphorArtwork(state:artwork).environment(\.displayScale,scale)
            .frame(width:artwork.size.width,height:artwork.size.height)
            .offset(x:-snapped.minX,y:-snapped.minY)
            .frame(width:snapped.width,height:snapped.height,alignment:.topLeading)
            .clipped()
        let image=ImageRenderer(content:view)
        image.scale=scale;image.isOpaque=true;image.colorMode = .nonLinear
        image.proposedSize=ProposedViewSize(snapped.size)
        guard let cg=image.cgImage else{throw WaveTextRenderer.RenderError.allocation}
        try drawing.replaceArtwork(cg,at:(Int((snapped.minX*scale).rounded()),Int((snapped.minY*scale).rounded())))
    }

    func reset() {
        wake()
        particles.removeAll(keepingCapacity: true)
        debris.removeAll(keepingCapacity: true)
        draws.removeAll(keepingCapacity: true)
        exposures.removeAll(keepingCapacity: true)
        drawing?.resetAtlas()
        spectrum?.ink.reset()
        wasPendingReturn = false
        ordinal = 0
        placementSeed = .random(in: .min ... .max)
        if window != nil { _ = drawing?.draw(draws, size: bounds.size, scene: artworkState == nil ? nil:scene) }
        hadVisibleText = false
    }

    private func updateGeometry(_ spectrum: SpectrumStore) {
        let motion = spectrum.stringMotion
        let layout = TorusGeometry.Layout(size: torus.size, frame: spectrum.frame,
                                          pull: motion.pull, anchor: motion.anchor, reducedMotion: reduced, extendedUpward: true,
                                          upwardTravel: motion.upwardTravel ?? max(1, torus.midY - 84))
        if rings.isEmpty {
            rings = (0..<TorusGeometry.ringCount).map { layout.ring(at: $0) }
        } else {
            for index in rings.indices { rings[index] = layout.ring(at: index) }
        }
        if artworkState != nil {
            scene.clearProgress=Float(motion.clearPreview(distance:torus.midY-84,enabled:clearEnabled))
            scene.update(spectrum:spectrum,torus:torus,size:bounds.size,reduced:reduced,
                         dimmed:dimmed,scale:window?.screen.scale ?? traitCollection.displayScale)
            if let artworkState {
                scene.headerSignal(content:artworkState.content,connected:!dimmed,
                    ambient:spectrum.frame.ambientIntensity,reduced:reduced)
            }
        }
    }

    private func wirePose(_ particle: Particle) -> WirePose {
        if artworkState != nil, scene.rings.indices.contains(particle.ring) {
            // A flowing arc carries its glyph: launch from where the arc is now.
            let flowing = scene.attachStyle == .flow && particle.phase == .attached
            let angle = Float(flowing ? PhosphorAttachStyle.flowAngle(particle.angle, phase: particle.landPhase,
                now: spectrum?.frame.time ?? 0) : particle.angle)
            let ring = scene.rings[particle.ring]
            let point = ring.point(angle)
            let p = scene.camera.project(point)
            let q = scene.camera.project(point + (-sin(angle) * ring.u + cos(angle) * ring.v))
            let tangent = SIMD2(q.x - p.x, q.y - p.y)
            let length = simd_length(tangent)
            let direction = length > 0.001 ? tangent / length : SIMD2<Float>(0, 1)
            // Up along the tangent, wrapped so a glyph is never drawn upside down.
            var rotation = CGFloat(atan2(direction.y, direction.x)) - .pi / 2
            rotation -= .pi * (rotation / .pi).rounded()
            return WirePose(center: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), rotation: rotation,
                            squash: CGFloat(min(1, max(0.45, length))), facing: CGFloat(cos(angle)),
                            normal: CGVector(dx: CGFloat(-direction.y), dy: CGFloat(direction.x)))
        }
        let point = rings[particle.ring].point(at: particle.angle)
        return WirePose(center: CGPoint(x: torus.minX + point.x, y: torus.minY + point.y),
                        rotation: rings[particle.ring].rotation + sin(particle.angle) * 0.10,
                        squash: 1, facing: 1, normal: CGVector(dx: 1, dy: 0))
    }

    func fire() {
        guard positioned, let spectrum else { return }
        let motion = spectrum.stringMotion
        let now = CACurrentMediaTime()
        let strength = motion.releaseStrength
        updateGeometry(spectrum)
        spectrum.ink.release(strength: strength, anchor: motion.anchor)
        if reduced {
            particles.removeAll(keepingCapacity: true)
            draws.removeAll(keepingCapacity: true)
            exposures.removeAll(keepingCapacity: true)
            _ = drawing?.draw(draws, size: bounds.size, scene: artworkState == nil ? nil:scene)
            hadVisibleText = false
            return
        }
        let count = particles.reduce(0) { $0 + ($1.phase == .attached ? 1 : 0) }
        let layout = ReceiverFlightLayout(count: count, width: bounds.width)
        var attachedIndex = 0
        var shotIndex = 0
        // Retire an earlier visual flight before a repeated release, keeping the budget global.
        particles.removeAll { $0.phase == .projectile }
        debris.removeAll(keepingCapacity: true)
        drawing?.prepare(Self.debrisGlyph)
        // Attached text is the released load. Speech still arriving joins the next load.
        // No texture creation, allocations, command sending or audio work in this loop.
        for index in particles.indices where particles[index].phase == .attached {
            var particle = particles[index]
            let selected = shotIndex < layout.visibleCount
                && attachedIndex == layout.sourceIndex(for: shotIndex)
            attachedIndex += 1
            guard selected else {
                // Invisible visual samples are reclaimed below, never removed from the transcript.
                particles[index].phase = .projectile
                particles[index].opacity = 0
                continue
            }
            let wire = wirePose(particle)
            let origin = wire.center
            let progress = CGFloat(particle.ring) / CGFloat(TorusGeometry.ringCount - 1)
            let bowVelocity = TorusGeometry.stringDisplacement(
                progress: progress, anchor: motion.anchor, pull: motion.velocity)
            let clearance = max(1, origin.y + 32)
            let speed = ReceiverArrowFlight.launchSpeed(
                height: bounds.height, clearance: clearance, strength: strength,
                bowVelocity: bowVelocity, variation: layout.speedMultiplier(for: shotIndex))
            // Different impulse directions/speeds and a small smooth bow change each burst.
            let targetX = layout.targetX(for: shotIndex)
            particle.velocity = CGVector(dx: (targetX - origin.x) * speed / max(1, origin.y), dy: -speed)
            particle.arrow = ReceiverArrowFlight(speed: hypot(particle.velocity.dx, particle.velocity.dy))
            particle.exitScale = layout.exitSide / Self.baseSide
            particle.emphasis = layout.emphasis
            particle.origin = origin
            particle.position = origin
            particle.started = now + layout.delay(for: shotIndex)
            particle.scale = Self.attachedScale
            particle.flightProgress = 0
            particle.startOpacity = max(0.94, particle.opacity)
            particle.opacity = particle.startOpacity
            particle.rotation = wire.rotation
            particle.launchRotation = particle.rotation
            particle.flightTilt = layout.tilt(for: shotIndex)
            particle.flightBend = layout.bend(for: shotIndex)
            particle.flightSpin = layout.spin(for: shotIndex)
            particle.thickness = 1
            particle.phase = .projectile
            particles[index] = particle
            shed(from: particle, shot: shotIndex, shots: layout.visibleCount, strength: strength)
            shotIndex += 1
        }
        particles.removeAll { $0.phase == .projectile && $0.opacity == 0 }
    }

    func renderStringMotion(_ motion: StringMotionStore, now: Double, dt: Double) {
        let began = CACurrentMediaTime()
        defer { cpuMetrics.record(start: began, end: CACurrentMediaTime()) }
        canvas.alpha = 1
        textClearOpacity = Float(motion.clearLoadOpacity)
        guard window != nil, positioned, let spectrum, let drawing else { return }
        if let pendingArtwork { updateArtwork(pendingArtwork,drawing:drawing) }
        guard artworkState != nil || !particles.isEmpty || !debris.isEmpty || store?.hasPending == true || hadVisibleText else { return }
        updateGeometry(spectrum)
        // Use the short physical return as the final intake, not an artificial hit-stop.
        if motion.pendingReturn, !wasPendingReturn {
            for index in particles.indices where particles[index].phase == .incoming {
                particles[index].origin = particles[index].position
                particles[index].startScale = particles[index].scale
                particles[index].startOpacity = particles[index].opacity
                particles[index].started = now
                particles[index].duration = 0.045
            }
        }
        wasPendingReturn = motion.pendingReturn
        do {
            // Bounded lookahead shapes into upload buffers on a serial worker, never this clock.
            for offset in 0..<16 {
                guard let character = store?.peekCharacter(offset: offset) else { break }
                drawing.prepare(character)
            }
            for _ in 0..<8 {
                guard let character = store?.peekCharacter() else { break }
                let glyph: WaveGlyphTexture
                do {
                    guard let prepared = try drawing.texture(for: character) else { break }
                    glyph = prepared
                } catch {
                    store?.consumeCharacter()
                    throw error
                }
                store?.consumeCharacter()
                ordinal &+= 1
                let (ring, angle) = placement()
                let seed = Self.unit(ordinal ^ placementSeed, stream: 3)
                let origin = ReceiverEmission.origin(source: source, touchFraction: store?.sourceTouchFraction,
                    glyphSide: Self.baseSide * Self.entryScale, canvasWidth: bounds.width, seed: seed)
                if reduced {
                    // Keep the whole load visible without entry flight, drift or looping effects.
                    particles.append(Particle(glyph: glyph, ring: ring, angle: angle, seed: seed,
                        phase: .attached, origin: origin, position: origin, started: now, duration: 0))
                    particles[particles.count - 1].landPhase = spectrum.frame.time
                    spectrum.ink.deposit(at: ring, angle: angle, weight: 0.65, phase: spectrum.frame.time)
                } else {
                    particles.append(Particle(glyph: glyph, ring: ring,
                        angle: angle, seed: seed, origin: origin, position: origin,
                        started: now + Double(seed) * 0.035,
                        duration: motion.pendingReturn ? 0.035 : 0.36 + Double(seed) * 0.06))
                }
            }
            let sampleBudget = particles.count + 64 * (ReceiverShutter.maximumSamples - 1) + 32
            try drawing.reserve(instances: max(1024, particles.count + debris.count + 32), samples: sampleBudget + debris.count)
            if exposures.capacity < sampleBudget { exposures.reserveCapacity(sampleBudget) }
            if draws.capacity < particles.count {
                draws.reserveCapacity(max(draws.capacity * 2, particles.count))
            }
        } catch {
            if !reportedRenderFailure {
                reportedRenderFailure = true
                IMicLog.write("iphone.visual", "glyph preparation failed: \(error)")
            }
        }
        draws.removeAll(keepingCapacity: true)
        exposures.removeAll(keepingCapacity: true)
        var index = 0
        while index < particles.count {
            var particle = particles[index]
            let age = CGFloat(now - particle.started)
            if particle.phase == .projectile {
                if age < 0 {
                    // Waiting its turn, the glyph rises out of its arc before it is shot.
                    var waiting = particle
                    let rise = Self.smooth(1 + age / 0.05)
                    waiting.opacity = particle.startOpacity * (0.35 + 0.65 * rise)
                    waiting.thickness = 0.3 + 0.7 * rise
                    append(waiting, warmth: 1, glow: Float(0.08 + 0.12 * rise))
                    index += 1
                    continue
                }
                if !appendProjectile(particle, age: age) {
                    particles.swapAt(index, particles.count - 1)
                    particles.removeLast()
                    continue
                }
            } else if particle.phase == .incoming {
                let t = min(1, max(0, age / CGFloat(particle.duration)))
                let wire = wirePose(particle)
                let target = wire.center
                let travel = t * t * (1.6 - 0.6 * t)
                let distance = particle.origin.y - target.y
                let p1 = CGPoint(x: particle.origin.x + (particle.seed - 0.5) * 22,
                                 y: particle.origin.y - distance * 0.22)
                let p2 = CGPoint(x: target.x + (particle.seed - 0.5) * 32,
                                 y: target.y + distance * 0.25)
                particle.position = Self.cubic(particle.origin, p1, p2, target, travel)
                let fusion = Self.smooth(t)
                particle.scale = particle.startScale + (Self.attachedScale - particle.startScale) * fusion
                let entrance = particle.startOpacity + (0.98 - particle.startOpacity) * Self.smooth(t / 0.10)
                particle.opacity = entrance
                // Turn to the wire only on the final approach. The glyph is never squashed:
                // the arc on the ring carries the 3D fit, a squeezed glyph only aliases.
                particle.rotation = wire.rotation * Self.smooth((t - 0.6) / 0.4)
                particle.squash = 1
                if t >= 1 {
                    particle.phase = .attached
                    particle.landPhase = spectrum.frame.time
                    spectrum.ink.deposit(at: particle.ring, angle: particle.angle, weight: 0.65,
                                         phase: spectrum.frame.time)
                }
                // One monotonic warm-up into the landing: no separate strike spike that could
                // disagree in timing with the arc's own flash and read as flicker.
                append(particle, warmth: fusion, glow: Float(0.3 * fusion * fusion), depth: 0.05)
            } else if artworkState != nil {
                // The glyph sinks into the light arc the scene draws on the same ring: it shrinks
                // evenly and fades while the arc grows, so after 0.12s only the arc remains.
                let wire = wirePose(particle)
                let collapse = reduced ? 1 : Self.smooth(max(0, age - CGFloat(particle.duration)) / 0.12)
                particle.position = wire.center
                particle.rotation = wire.rotation
                particle.squash = 1
                particle.thickness = 1
                particle.scale = Self.attachedScale * (1 - 0.4 * collapse)
                particle.opacity = 0.98 * pow(1 - collapse, 1.6)
                if collapse < 1 { append(particle, warmth: 1, glow: Float(0.3 * (1 - collapse)), depth: 0.05) }
            } else {
                let wire = wirePose(particle)
                let charge = spectrum.ink.chargeGlow
                let impact = reduced ? 0 : 1 - Self.smooth(max(0, age - CGFloat(particle.duration)) / 0.16)
                particle.position = wire.center
                particle.rotation = wire.rotation
                particle.squash = 1
                particle.scale = Self.attachedScale
                let resting = 0.6 + spectrum.ink.intensity(at: particle.ring) * 0.12
                particle.opacity = min(1, resting + (1 - resting) * max(charge, impact))
                append(particle, warmth: 0.82 + 0.18 * max(charge, impact))
            }
            particles[index] = particle
            index += 1
        }
        appendDebris(now: now, drawing: drawing)
        appendElapsed(drawing)
        if artworkState != nil || !draws.isEmpty || hadVisibleText {
            _ = drawing.draw(draws, samples: exposures, size: bounds.size, scene: artworkState == nil ? nil:scene)
        }
        hadVisibleText = !draws.isEmpty
    }

    /// Irregular, not patterned: most glyphs land within reach of the finger, the rest
    /// anywhere on the coil, and a landing avoids sitting on top of a recent one.
    private func placement() -> (Int, CGFloat) {
        let key = ordinal ^ placementSeed
        let last = CGFloat(TorusGeometry.ringCount - 1)
        let anchor = (store?.sourceTouchFraction ?? 0.5) * last
        var best: (Int, CGFloat) = (0, 0)
        var bestGap: CGFloat = -1
        for attempt in UInt64(0)..<4 {
            let stream = attempt * 4
            let u = Self.unit(key, stream: stream), v = Self.unit(key, stream: stream + 1)
            let position: CGFloat
            if Self.unit(key, stream: stream + 2) < 0.68 {
                // Box-Muller: a soft cluster around the finger, about nine rings wide.
                let gaussian = sqrt(-2 * log(max(1e-6, u))) * cos(2 * .pi * v)
                position = anchor + gaussian * 9
            } else {
                position = u * last
            }
            let ring = Int(min(last, max(0, position.rounded())))
            let angle = (Self.unit(key, stream: stream + 3) * 2 - 1) * .pi
            var gap = CGFloat.pi
            for particle in particles.suffix(96) where particle.phase != .projectile && abs(particle.ring - ring) <= 1 {
                let delta = abs(remainder(Double(particle.angle - angle), 2 * .pi))
                gap = min(gap, CGFloat(delta) + CGFloat(abs(particle.ring - ring)) * 0.35)
            }
            if gap > bestGap { best = (ring, angle); bestGap = gap }
            if gap > 0.55 { break }
        }
        return best
    }

    private static func unit(_ key: UInt64, stream: UInt64) -> CGFloat {
        var value = key &+ (stream &+ 1) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return CGFloat(Double(value >> 11) / 9_007_199_254_740_992)
    }

    /// A few embers per shot, fewer when many glyphs fly, within one global budget.
    private func shed(from particle: Particle, shot: Int, shots: Int, strength: CGFloat) {
        let perShot = shots <= 8 ? 4 : shots <= 24 ? 2 : (shot % 2 == 0 ? 1 : 0)
        let key = ordinal ^ placementSeed ^ UInt64(shot &* 7919)
        let lift = 0.7 + 0.5 * min(1, max(0, strength))
        for piece in 0..<perShot where debris.count < Self.debrisBudget {
            let stream = UInt64(piece * 8)
            let u = Self.unit(key, stream: stream), v = Self.unit(key, stream: stream + 1)
            let w = Self.unit(key, stream: stream + 2), z = Self.unit(key, stream: stream + 3)
            if piece % 2 == 0 {
                // Popped out of the launch point: a small hop, then the fall.
                debris.append(Debris(
                    origin: particle.origin,
                    velocity: CGVector(dx: (u - 0.5) * 280 + particle.velocity.dx * 0.05, dy: -(120 + v * 220) * lift),
                    born: particle.started, life: 0.9 + Double(w) * 0.5,
                    side: 2.5 + z * 2.5, spin: (u - 0.5) * 14, heat: 0.75))
            } else {
                // Broken off the glyph early in flight, keeping a little of its speed.
                let t = 0.06 + v * 0.16
                let here = projectilePose(particle, at: t).center
                let next = projectilePose(particle, at: t + 0.012).center
                let carried = CGVector(dx: (next.x - here.x) / 0.012 * 0.12, dy: (next.y - here.y) / 0.012 * 0.12)
                debris.append(Debris(
                    origin: here,
                    velocity: CGVector(dx: carried.dx + (u - 0.5) * 180, dy: carried.dy - 40 + w * 80),
                    born: particle.started + Double(t), life: 0.8 + Double(z) * 0.4,
                    side: 2 + w * 2, spin: (v - 0.5) * 18, heat: 1))
            }
        }
    }

    private func appendDebris(now: Double, drawing: WaveTextRenderer) {
        guard !debris.isEmpty else { return }
        debris.removeAll { now - $0.born > $0.life }
        // The atlas may have been reset since the release; the ember shape comes back next frame.
        guard let glyph = try? drawing.texture(for: Self.debrisGlyph) else {
            drawing.prepare(Self.debrisGlyph); return
        }
        for piece in debris {
            let t = CGFloat(now - piece.born)
            guard t >= 0 else { continue }
            // Light air drag sideways, full gravity downwards.
            let x = piece.origin.x + piece.velocity.dx * (1 - exp(-2.2 * t)) / 2.2
            let y = piece.origin.y + piece.velocity.dy * t + 0.5 * Self.gravity * t * t
            guard y < bounds.height + 12, x > -12, x < bounds.width + 12 else { continue }
            let remaining = max(0, 1 - t / CGFloat(piece.life))
            let flicker = 0.82 + 0.18 * sin(t * 38 + piece.spin)
            let heat = piece.heat * max(0, 1 - t * 1.8)
            let pose = ReceiverFlightPose(center: CGPoint(x: x, y: y), size: CGSize(width: piece.side, height: piece.side),
                                          rotation: piece.spin * t, opacity: pow(remaining, 1.4) * flicker, warmth: heat)
            let offset = exposures.count
            var sample = WaveGlyphSample(pose)
            sample.appearance.z *= textClearOpacity
            exposures.append(sample)
            appendDraw(glyph, bounds: pose.bounds, sampleOffset: offset, sampleCount: 1, depth: 0.04, style: Float(0.2 * heat))
        }
    }

    private func projectilePose(_ particle: Particle, at age: CGFloat) -> ReceiverFlightPose {
        particle.arrow.pose(at: age, origin: particle.origin,
            velocity: CGPoint(x: particle.velocity.dx, y: particle.velocity.dy),
            exitSide: Self.baseSide * particle.exitScale, emphasis: particle.emphasis,
            launchSide: Self.launchSide, spin: particle.flightSpin,
            rotation: particle.launchRotation, tilt: particle.flightTilt, opacity: particle.startOpacity,
            bend: particle.flightBend)
    }

    private func appendElapsed(_ drawing:WaveTextRenderer){
        guard let artworkState,artworkState.listening,!elapsedText.isEmpty else{return}
        let scale=CGFloat(scene.pressScale(at:CACurrentMediaTime()))
        let advance:CGFloat=7.2,side:CGFloat=12*128/88*scale
        // Centered in the bar's accessory zone, clear of its separator.
        let center=artworkState.actionBounds.maxX-HoldBarLayout.accessoryWidth/2
        let start=center-CGFloat(elapsedText.count-1)*advance/2
        for (i,char) in elapsedText.enumerated() where !char.isWhitespace{
            guard let glyph=try? drawing.texture(for:char)else{continue}
            let x=artworkState.actionBounds.midX+(start+CGFloat(i)*advance-artworkState.actionBounds.midX)*scale
            let pose=ReceiverFlightPose(center:CGPoint(x:x,y:artworkState.actionBounds.midY),
                size:CGSize(width:side,height:side),rotation:0,opacity:0.8,warmth:0)
            let offset=exposures.count;exposures.append(WaveGlyphSample(pose))
            appendDraw(glyph,bounds:pose.bounds,sampleOffset:offset,sampleCount:1,depth:0.02,style:1)
        }
    }

    /// Full transforms are evaluated at each subframe, just like a layer shutter.
    /// Normalized exposure includes scale, rotation, deformation, flash and opacity.
    private func appendProjectile(_ particle: Particle, age: CGFloat) -> Bool {
        let start = projectilePose(particle, at: age - shutter.duration / 2)
        let end = projectilePose(particle, at: age + shutter.duration / 2)
        let count = shutter.sampleCount(start: start, end: end)
        let offset = exposures.count
        var swept = CGRect.null
        for index in 0..<count {
            let pose = projectilePose(particle, at: shutter.sampleAge(index, count: count, at: age))
            swept = swept.union(pose.bounds)
            var sample=WaveGlyphSample(pose)
            sample.appearance.z *= textClearOpacity
            exposures.append(sample)
        }
        // The shutter can still see a glyph whose current position has left the screen.
        guard swept.maxY >= 0 else {
            exposures.removeLast(count)
            return false
        }
        // The release flash blooms for the first frames of flight, then the glyph is plain ink.
        appendDraw(particle.glyph, bounds: swept, sampleOffset: offset, sampleCount: count,
                   style: Float(0.24 * max(0, 1 - age / 0.12)))
        return true
    }

    /// `depth` pins a glyph in front of the wires. Landing glyphs use it: occlusion by
    /// neighboring rings that breathe with the audio would cut pieces in and out each frame.
    private func append(_ particle: Particle, warmth: CGFloat, glow: Float = 0, depth fixedDepth: Float? = nil) {
        let side = Self.baseSide * particle.scale
        let pose = ReceiverFlightPose(center: particle.position,
            size: CGSize(width: side * particle.thickness, height: side * particle.squash),
            rotation: particle.rotation, opacity: particle.opacity, warmth: warmth)
        let offset = exposures.count
        var sample=WaveGlyphSample(pose)
        sample.appearance.z *= textClearOpacity
        exposures.append(sample)
        var depth:Float=0.05
        if fixedDepth == nil, artworkState != nil, scene.rings.indices.contains(particle.ring) {
            let target=scene.camera.depth(scene.rings[particle.ring].point(Float(particle.angle)))
            let fusion=Float(min(1,max(0,(Self.entryScale-particle.scale)/(Self.entryScale-Self.attachedScale))))
            depth=0.05+(target-0.05)*fusion
        }
        appendDraw(particle.glyph, bounds: pose.bounds, sampleOffset: offset, sampleCount: 1, depth:depth,
                   style: min(0.45, max(0, glow)))
    }

    private func appendDraw(_ glyph: WaveGlyphTexture, bounds: CGRect, sampleOffset: Int, sampleCount: Int, depth: Float = 0.05, style: Float = 0) {
        var instance = WaveGlyphInstance(
            bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height)),
            uvRect: glyph.uv, sampleRange: SIMD2(UInt32(sampleOffset), UInt32(sampleCount)))
        instance.depth=depth
        instance.reserved=style
        draws.append(WaveGlyphDraw(instance: instance, page: glyph.page))
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
        let s = 1 - t
        return CGPoint(x: s * s * s * a.x + 3 * s * s * t * b.x + 3 * s * t * t * c.x + t * t * t * d.x,
                       y: s * s * s * a.y + 3 * s * s * t * b.y + 3 * s * t * t * c.y + t * t * t * d.y)
    }
}
