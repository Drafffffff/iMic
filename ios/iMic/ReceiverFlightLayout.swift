import Foundation

/// Project the control's local horizontal touch onto its top edge in the overlay.
struct ReceiverEmission {
    static func origin(source: CGRect, touchFraction: CGFloat?, glyphSide: CGFloat,
                       canvasWidth: CGFloat, seed: CGFloat) -> CGPoint {
        let fraction = touchFraction.flatMap { $0.isFinite ? $0 : nil } ?? 0.5
        let x = source.minX + min(1, max(0, fraction)) * source.width
        // A small spread feels organic while remaining directly above the finger.
        let margin = min(max(0, canvasWidth) / 2, glyphSide / 2 + 2)
        let safeX = min(max(margin, canvasWidth - margin), max(margin, x + (seed - 0.5) * 6))
        return CGPoint(x: safeX, y: source.minY - 3 - glyphSide / 2)
    }
}

/// A visual-only budget: the recognition text and input commands never use this layout.
struct ReceiverFlightLayout {
    let count: Int
    let visibleCount: Int
    let exitSide: CGFloat
    let emphasis: CGFloat
    private let width: CGFloat
    private let inset: CGFloat
    private let seed: UInt64

    init(count: Int, width: CGFloat, seed: UInt64 = .random(in: .min ... .max)) {
        // One seed per release. Subframes must reuse it so the shutter sees smooth motion.
        self.seed = seed
        self.count = max(0, count)
        self.width = max(1, width)
        // Spend the visual budget on one readable burst, rather than scheduling a queue.
        visibleCount = min(self.count, max(8, min(64, Int(max(0, self.width - 32) / 6))))
        // A short phrase keeps its large gesture; a paragraph settles at a readable size.
        exitSide = min(max(1, self.width - 32), max(32, 60.8 / sqrt(max(1, CGFloat(count) / 12))))
        // Long passages still get the same physical kick; density only limits glyph size/count.
        emphasis = 0.72 + 0.28 * min(1, 12 / CGFloat(max(1, count)))
        inset = min(self.width / 2, exitSide * 0.75 + 8)
    }

    /// Uniformly sample very long loads, including both ends, without retaining another array.
    func sourceIndex(for index: Int) -> Int {
        guard visibleCount > 1 else { return 0 }
        return Int((Double(index) * Double(max(0, count - 1)) / Double(visibleCount - 1)).rounded())
    }

    func targetX(for index: Int) -> CGFloat {
        // Independent low-discrepancy dimensions scatter the burst without rows or lanes.
        inset + scatter(index, stride: 0.61803398875, stream: 0) * (width - inset * 2)
    }

    func speedMultiplier(for index: Int) -> CGFloat {
        0.78 + scatter(index, stride: 0.75487766625, stream: 1) * 0.64
    }

    func tilt(for index: Int) -> CGFloat {
        (scatter(index, stride: 0.438579021, stream: 2) - 0.5) * 0.44
    }

    func delay(for index: Int) -> Double {
        // All glyphs leave within one 60Hz frame, including an arbitrarily long load.
        Double(scatter(index, stride: 0.569840291, stream: 3)) * 0.014
    }

    func bend(for index: Int) -> CGFloat {
        (phase(stream: UInt64(index) &+ 4) * 2 - 1) * min(10, width * 0.025)
    }

    private func scatter(_ index: Int, stride: Double, stream: UInt64) -> CGFloat {
        // Randomly rotate each low-discrepancy sequence, retaining its even coverage.
        let value = (Double(index) + 0.5) * stride + Double(phase(stream: stream))
        return CGFloat(value - floor(value))
    }

    private func phase(stream: UInt64) -> CGFloat {
        var value = seed &+ (stream &+ 1) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return CGFloat(Double(value >> 11) / 9_007_199_254_740_992)
    }
}

/// After leaving the string, an arrow has no thrust. With quadratic air drag,
/// dv/dt = -k*v², v = v0/(1+k*v0*t), and s = log(1+k*v0*t)/k.
/// Screen-space coefficients are art-directed; this is not a real-world arrow solver.
struct ReceiverArrowFlight {
    let launchSpeed: CGFloat
    private let drag: CGFloat = 0.00028

    init(speed: CGFloat) { launchSpeed = max(0, speed) }

    static func launchSpeed(height: CGFloat, clearance: CGFloat, strength: CGFloat,
                            bowVelocity: CGFloat, variation: CGFloat) -> CGFloat {
        let base = max(height * 4.4, clearance / 0.115)
        let impulse = max(0, -bowVelocity) * 0.55
        return (base * (0.92 + min(1, max(0, strength)) * 0.38) + impulse) * variation
    }

    func speed(at age: CGFloat) -> CGFloat {
        launchSpeed / (1 + drag * launchSpeed * max(0, age))
    }

    func distance(at age: CGFloat) -> CGFloat {
        log1p(drag * launchSpeed * max(0, age)) / drag
    }

    /// Multiply the launch velocity vector by this value; independent of display FPS.
    func travel(at age: CGFloat) -> CGFloat {
        launchSpeed > 0 ? distance(at: age) / launchSpeed : 0
    }

    func pose(at age: CGFloat, origin: CGPoint, velocity: CGPoint, exitSide: CGFloat,
              emphasis: CGFloat, rotation: CGFloat, tilt: CGFloat, opacity: CGFloat,
              bend: CGFloat = 0) -> ReceiverFlightPose {
        let time = max(0, age)
        let travel = travel(at: time)
        var center = CGPoint(x: origin.x + velocity.x * travel, y: origin.y + velocity.y * travel)
        let progress = min(1, max(0, (origin.y - center.y) / max(1, origin.y)))
        // A single small mid-flight bow, zero displacement and slope at both ends.
        // Evaluating the same curve at every shutter subframe avoids noisy/jagged blur.
        let arc = progress * (1 - progress)
        center.x += bend * 16 * arc * arc
        let growth = 1 - pow(1 - min(1, progress / 0.85), 1.6)
        let side = 6.08 + (exitSide - 6.08) * growth
        let impulse = age < 0 ? 0 : max(0, 1 - abs(time - 0.025) / 0.035) * emphasis
        let settle = Self.smooth(time / 0.045)
        return ReceiverFlightPose(center: center,
            size: CGSize(width: max(6.08, side * (1 - impulse * 0.12)), height: side * (1 + impulse * 0.38)),
            rotation: rotation * (1 - settle) + tilt * settle,
            opacity: opacity + (1 - opacity) * Self.smooth(time / 0.012),
            warmth: age < 0 ? 0 : max(0, 1 - time / 0.055))
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

struct ReceiverFlightPose {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let opacity: CGFloat
    let warmth: CGFloat

    var bounds: CGRect {
        let c: CGFloat = abs(cos(rotation))
        let s: CGFloat = abs(sin(rotation))
        let width: CGFloat = c * size.width + s * size.height
        let height: CGFloat = s * size.width + c * size.height
        let corner = CGPoint(x: center.x - width * 0.5, y: center.y - height * 0.5)
        return CGRect(origin: corner, size: CGSize(width: width, height: height))
    }
}

/// A 60fps composition with a 180° shutter and -90° phase: centered 8.33ms exposure.
/// Evaluate actual transforms throughout the shutter; no sharp head or history tail.
struct ReceiverShutter {
    static let maximumSamples = 64
    let duration: CGFloat = 0.5 / 60

    func sampleAge(_ index: Int, count: Int, at age: CGFloat) -> CGFloat {
        age + (CGFloat(index) + 0.5) / CGFloat(count) * duration - duration / 2
    }

    func sampleCount(start: ReceiverFlightPose, end: ReceiverFlightPose) -> Int {
        let translation = hypot(end.center.x - start.center.x, end.center.y - start.center.y)
        let radius = max(hypot(start.size.width, start.size.height), hypot(end.size.width, end.size.height)) / 2
        let rotation = abs(end.rotation - start.rotation) * radius
        let scale = hypot(end.size.width - start.size.width, end.size.height - start.size.height) / 2
        let sweep = translation + rotation + scale
        guard sweep > 0.01 || abs(end.opacity - start.opacity) > 0.001 || abs(end.warmth - start.warmth) > 0.001 else { return 1 }
        return min(Self.maximumSamples, max(16, Int(ceil(sweep / 0.65))))
    }
}
