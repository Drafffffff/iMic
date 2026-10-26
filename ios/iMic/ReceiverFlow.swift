import SwiftUI
import UIKit
import QuartzCore

/// Visual history is independent of the complete recognition result. Corrections never
/// pull a launched word backwards; every newly appended grapheme enters the next load.
@MainActor
final class ReceiverFlowStore: ObservableObject {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> ReceiverFlowSurface {
        let view = ReceiverFlowSurface()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ReceiverFlowSurface, context: Context) {
        view.configure(store: store, spectrum: spectrum, torus: torusFrame,
                       source: sourceFrame, reduced: reduceMotion)
    }

    static func dismantleUIView(_ view: ReceiverFlowSurface, coordinator: ()) { view.detach() }
}

/// The wave retains its fixed endpoints. Only text receives the release impulse.
/// State and atlas capacity grow on ingestion; normal frames reuse all CPU/GPU storage.
@MainActor
final class ReceiverFlowSurface: UIView, StringMotionRendering {
    var needsStringMotionFrames: Bool {
        guard drawing != nil, window != nil, positioned else { return false }
        return store?.hasPending == true || particles.contains { $0.phase != .attached }
    }

    func wake() { spectrum?.wake() }
    nonisolated private static let attachedScale: CGFloat = 0.38
    nonisolated private static let entryScale: CGFloat = 2.4
    nonisolated private static let baseSide: CGFloat = 16

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
        var exitScale: CGFloat = ReceiverFlowSurface.attachedScale
        var emphasis: CGFloat = 1
    }

    private weak var store: ReceiverFlowStore?
    private weak var spectrum: SpectrumStore?
    private let canvas = WaveTextCanvas()
    private var drawing: WaveTextRenderer?
    private var particles: [Particle] = []
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
    private var reportedRenderFailure = false

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
    }

    func configure(store: ReceiverFlowStore, spectrum: SpectrumStore,
                   torus: CGRect, source: CGRect, reduced: Bool) {
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
        spectrum.ink.reduceMotion = reduced
        if self.reduced != reduced {
            self.reduced = reduced
            if reduced {
                particles.removeAll { $0.phase == .projectile }
                for index in particles.indices where particles[index].phase == .incoming {
                    particles[index].phase = .attached
                    spectrum.ink.deposit(at: particles[index].ring, angle: particles[index].angle, weight: 0.65)
                }
            }
        }
        positioned = torus.width > 0 && torus.height > 0
        if changed { spectrum.wake() }
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

    func reset() {
        wake()
        particles.removeAll(keepingCapacity: true)
        draws.removeAll(keepingCapacity: true)
        exposures.removeAll(keepingCapacity: true)
        drawing?.resetAtlas()
        spectrum?.ink.reset()
        wasPendingReturn = false
        ordinal = 0
        if window != nil { _ = drawing?.draw(draws, size: bounds.size) }
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
    }

    private func attachment(_ particle: Particle) -> CGPoint {
        let point = rings[particle.ring].point(at: particle.angle)
        return CGPoint(x: torus.minX + point.x, y: torus.minY + point.y)
    }

    func fire() {
        guard positioned, let spectrum else { return }
        let motion = spectrum.stringMotion
        let now = CACurrentMediaTime()
        let strength = motion.releaseStrength
        updateGeometry(spectrum)
        spectrum.ink.release(strength: strength)
        if reduced {
            particles.removeAll(keepingCapacity: true)
            draws.removeAll(keepingCapacity: true)
            exposures.removeAll(keepingCapacity: true)
            _ = drawing?.draw(draws, size: bounds.size)
            hadVisibleText = false
            return
        }
        let count = particles.reduce(0) { $0 + ($1.phase == .attached ? 1 : 0) }
        let layout = ReceiverFlightLayout(count: count, width: bounds.width)
        var attachedIndex = 0
        var shotIndex = 0
        // Retire an earlier visual flight before a repeated release, keeping the budget global.
        particles.removeAll { $0.phase == .projectile }
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
            let origin = attachment(particle)
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
            particle.rotation = rings[particle.ring].rotation
            particle.launchRotation = particle.rotation
            particle.flightTilt = layout.tilt(for: shotIndex)
            particle.flightBend = layout.bend(for: shotIndex)
            particle.phase = .projectile
            particles[index] = particle
            shotIndex += 1
        }
        particles.removeAll { $0.phase == .projectile && $0.opacity == 0 }
    }

    func renderStringMotion(_ motion: StringMotionStore, now: Double, dt: Double) {
        canvas.alpha = CGFloat(motion.clearLoadOpacity)
        guard window != nil, positioned, let spectrum, let drawing else { return }
        guard !particles.isEmpty || store?.hasPending == true || hadVisibleText else { return }
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
                let ring = Int((ordinal &* 17) % UInt64(TorusGeometry.ringCount))
                let angle = CGFloat(ordinal) * 2.399963229728653
                let seed = CGFloat((ordinal &* 73 &+ 19) % 997) / 996
                let origin = ReceiverEmission.origin(source: source, touchFraction: store?.sourceTouchFraction,
                    glyphSide: Self.baseSide * Self.entryScale, canvasWidth: bounds.width, seed: seed)
                if reduced {
                    // Keep the whole load visible without entry flight, drift or looping effects.
                    particles.append(Particle(glyph: glyph, ring: ring, angle: angle, seed: seed,
                        phase: .attached, origin: origin, position: origin, started: now, duration: 0))
                    spectrum.ink.deposit(at: ring, angle: angle, weight: 0.65)
                } else {
                    particles.append(Particle(glyph: glyph, ring: ring,
                        angle: angle, seed: seed, origin: origin, position: origin,
                        started: now + Double(seed) * 0.035,
                        duration: motion.pendingReturn ? 0.035 : 0.43 + Double(seed) * 0.065))
                }
            }
            let sampleBudget = particles.count + 64 * (ReceiverShutter.maximumSamples - 1)
            try drawing.reserve(instances: max(1024, particles.count), samples: sampleBudget)
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
                    var waiting = particle
                    waiting.opacity *= 0.42
                    append(waiting)
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
                let target = attachment(particle)
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
                particle.opacity = entrance + (0.42 - entrance) * Self.smooth((t - 0.76) / 0.24)
                particle.rotation = rings[particle.ring].rotation * fusion
                if t >= 1 {
                    particle.phase = .attached
                    spectrum.ink.deposit(at: particle.ring, angle: particle.angle, weight: 0.65)
                }
                append(particle, impact: max(0, 1 - abs(t - 0.97) / 0.08))
            } else {
                particle.position = attachment(particle)
                particle.rotation = rings[particle.ring].rotation + sin(particle.angle) * 0.10
                particle.scale = Self.attachedScale
                let restingOpacity = 0.30 + spectrum.ink.intensity(at: particle.ring) * 0.12
                let charge = spectrum.ink.chargeGlow
                let impact = reduced ? 0 : 1 - Self.smooth(max(0, age - CGFloat(particle.duration)) / 0.13)
                particle.opacity = restingOpacity + (0.98 - restingOpacity) * max(charge, impact * 0.9)
                append(particle, charge: charge, impact: impact)
            }
            particles[index] = particle
            index += 1
        }
        if !draws.isEmpty || hadVisibleText {
            _ = drawing.draw(draws, samples: exposures, size: bounds.size)
        }
        hadVisibleText = !draws.isEmpty
    }

    private func projectilePose(_ particle: Particle, at age: CGFloat) -> ReceiverFlightPose {
        particle.arrow.pose(at: age, origin: particle.origin,
            velocity: CGPoint(x: particle.velocity.dx, y: particle.velocity.dy),
            exitSide: Self.baseSide * particle.exitScale, emphasis: particle.emphasis,
            rotation: particle.launchRotation, tilt: particle.flightTilt, opacity: particle.startOpacity,
            bend: particle.flightBend)
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
            exposures.append(WaveGlyphSample(pose))
        }
        // The shutter can still see a glyph whose current position has left the screen.
        guard swept.maxY >= 0 else {
            exposures.removeLast(count)
            return false
        }
        appendDraw(particle.glyph, bounds: swept, sampleOffset: offset, sampleCount: count)
        return true
    }

    private func append(_ particle: Particle, charge: CGFloat = 0, impact: CGFloat = 0) {
        let side = Self.baseSide * particle.scale
        let pose = ReceiverFlightPose(center: particle.position, size: CGSize(width: side, height: side),
            rotation: particle.rotation, opacity: particle.opacity, warmth: max(charge * 0.28, impact * 0.75))
        let offset = exposures.count
        exposures.append(WaveGlyphSample(pose))
        appendDraw(particle.glyph, bounds: pose.bounds, sampleOffset: offset, sampleCount: 1)
    }

    private func appendDraw(_ glyph: WaveGlyphTexture, bounds: CGRect, sampleOffset: Int, sampleCount: Int) {
        let instance = WaveGlyphInstance(
            bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height)),
            uvRect: glyph.uv, sampleRange: SIMD2(UInt32(sampleOffset), UInt32(sampleCount)))
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
