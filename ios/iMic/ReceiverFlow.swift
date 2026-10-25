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
    }

    func reset() {
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
    nonisolated private static let attachedScale: CGFloat = 0.38
    nonisolated private static let entryScale: CGFloat = 2.4
    nonisolated private static let exitScale: CGFloat = 3.8
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
        var spin: CGFloat = 0
    }

    private weak var store: ReceiverFlowStore?
    private weak var spectrum: SpectrumStore?
    private let canvas = WaveTextCanvas()
    private var drawing: WaveTextRenderer?
    private var particles: [Particle] = []
    private var draws: [WaveGlyphDraw] = []
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
        particles.removeAll(keepingCapacity: true)
        draws.removeAll(keepingCapacity: true)
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
                                          pull: motion.pull, anchor: motion.anchor, reducedMotion: reduced)
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
            _ = drawing?.draw(draws, size: bounds.size)
            hadVisibleText = false
            return
        }
        // Attached text is the released load. Speech still arriving joins the next load.
        // No texture creation, allocations, command sending or audio work in this loop.
        for index in particles.indices where particles[index].phase == .attached {
            var particle = particles[index]
            let origin = attachment(particle)
            let progress = CGFloat(particle.ring) / CGFloat(TorusGeometry.ringCount - 1)
            let bowVelocity = TorusGeometry.stringDisplacement(
                progress: progress, anchor: motion.anchor, pull: motion.velocity)
            let clearance = max(1, origin.y + 32)
            let base = max(bounds.height * 3.2, clearance / 0.20)
            let speed = max(base, base * 0.82 - bowVelocity * 0.55)
                * (0.94 + particle.seed * 0.16 + strength * 0.10)
            let travelTime = clearance / max(1, speed) + 0.045
            let margin = max(0, min(origin.x - 48, bounds.width - origin.x - 48))
            let lateralLimit = margin / travelTime * 0.85
            let spread = (origin.x - torus.midX) * 1.55 + (particle.seed - 0.5) * 110
            particle.velocity = CGVector(dx: min(lateralLimit, max(-lateralLimit, spread)), dy: -speed)
            particle.origin = origin
            particle.position = origin
            particle.started = now + Double(particle.seed) * 0.012
            particle.scale = Self.attachedScale
            particle.flightProgress = 0
            particle.startOpacity = max(0.94, particle.opacity)
            particle.opacity = particle.startOpacity
            particle.rotation = rings[particle.ring].rotation
            particle.spin = (particle.seed - 0.5) * 5.2
            particle.phase = .projectile
            particles[index] = particle
        }
    }

    func renderStringMotion(_ motion: StringMotionStore, now: Double, dt: Double) {
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
                let origin = CGPoint(x: source.midX + (seed - 0.5) * source.width * 0.48,
                                     y: source.minY - 3 - Self.baseSide * Self.entryScale * 0.5)
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
            try drawing.reserve(instances: max(1024, particles.count * 2))
            if draws.capacity < particles.count * 2 {
                draws.reserveCapacity(max(draws.capacity * 2, particles.count * 2))
            }
        } catch {
            if !reportedRenderFailure {
                reportedRenderFailure = true
                IMicLog.write("iphone.visual", "glyph preparation failed: \(error)")
            }
        }
        draws.removeAll(keepingCapacity: true)
        var index = 0
        while index < particles.count {
            var particle = particles[index]
            let age = CGFloat(now - particle.started)
            if particle.phase == .projectile {
                if age >= 0 {
                    let travel = age * (1 + 1.6 * age)
                    particle.position = CGPoint(x: particle.origin.x + particle.velocity.dx * travel,
                                                y: particle.origin.y + particle.velocity.dy * travel)
                    particle.flightProgress = min(1, max(0, (particle.origin.y - particle.position.y) / max(1, particle.origin.y)))
                    particle.scale = Self.attachedScale
                        + (Self.exitScale - Self.attachedScale) * Self.smooth(particle.flightProgress)
                    particle.opacity = particle.startOpacity + (1 - particle.startOpacity) * Self.smooth(age / 0.018)
                    particle.rotation += particle.spin * CGFloat(max(0, dt))
                }
                // Culling uses the rendered, growing quad and its trail, not a fixed 24pt margin.
                if !append(particle, shotAge: max(0, age)) {
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
            _ = drawing.draw(draws, size: bounds.size)
        }
        hadVisibleText = !draws.isEmpty
    }

    @discardableResult
    private func append(_ particle: Particle, shotAge: CGFloat? = nil,
                        charge: CGFloat = 0, impact: CGFloat = 0) -> Bool {
        let isShot = shotAge != nil
        let flash = shotAge.map { max(0, 1 - $0 / 0.055) } ?? 0
        let warmth = isShot ? flash : max(charge * 0.28, impact * 0.75)
        let impulse = isShot ? 4 * particle.flightProgress * (1 - particle.flightProgress) : 0
        let size = SIMD2<Float>(
            Float(Self.baseSide * max(Self.attachedScale, particle.scale * (1 - impulse * 0.12))),
            Float(Self.baseSide * particle.scale * (1 + impulse * 0.48)))
        let cosine = Float(cos(particle.rotation))
        let sine = Float(sin(particle.rotation))
        let halfHeight = (abs(sine) * size.x + abs(cosine) * size.y) * 0.5
        let trailVisible = shotAge.map { $0 > 0 && $0 < 0.16 } ?? false
        let trailOffset = min(34, Float(abs(particle.velocity.dy)) * 0.005)
            * Float(Self.smooth(particle.flightProgress / 0.15))
        let trailingEdge = trailVisible ? halfHeight + abs(cosine) * size.y * 0.09 + trailOffset : halfHeight
        guard !isShot || Float(particle.position.y) + trailingEdge >= 0 else { return false }
        let halfWidth = (abs(cosine) * size.x + abs(sine) * size.y) * 0.5
        let margin = min(Float(bounds.width) * 0.5, halfWidth + 2)
        let x = isShot ? min(Float(bounds.width) - margin, max(margin, Float(particle.position.x)))
            : Float(particle.position.x)
        let color = SIMD4<Float>(1 - Float(warmth) * 0.05,
                                0.29 + Float(warmth) * 0.65,
                                Float(warmth) * 0.88, Float(particle.opacity))
        let instance = WaveGlyphInstance(center: SIMD2(x, Float(particle.position.y)),
                                         size: size, uvRect: particle.glyph.uv,
                                         orientation: SIMD2(cosine, sine), color: color)
        if trailVisible {
            var trail = instance
            trail.center.y += trailOffset
            trail.size.y *= 1.18
            trail.color.w *= 0.18
            draws.append(WaveGlyphDraw(instance: trail, page: particle.glyph.page))
        }
        draws.append(WaveGlyphDraw(instance: instance, page: particle.glyph.page))
        return true
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
