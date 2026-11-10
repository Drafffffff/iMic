import Foundation
import simd

/// Real spatial cross-sections, calibrated to the original front projection.
/// The two unit axes are orthogonal; z is retained for occlusion and side views.
struct PhosphorRing {
    var center: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var radius: Float
    var opacity: Float

    func point(_ angle: Float) -> SIMD3<Float> {
        center + radius * (cos(angle) * u + sin(angle) * v)
    }
}

struct PhosphorCamera {
    var center: SIMD2<Float>
    var yaw: Float = 0

    func project(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let x = point.x - center.x
        return SIMD3(center.x + x * cos(yaw) + point.z * sin(yaw), point.y,
                     -x * sin(yaw) + point.z * cos(yaw))
    }

    func depth(_ point: SIMD3<Float>) -> Float {
        min(0.95, max(0.05, 0.5 - project(point).z / 4096))
    }
}

/// A camera-facing stroke instance. Width is in points, independent of depth.
struct PhosphorStroke {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var color: SIMD4<Float>
    var material: SIMD4<Float> // emission, persistence eligibility, reserved
}

struct PhosphorUniforms {
    var viewport: SIMD4<Float> // points.xy, physical scale, CRT strength
    var timing: SIMD4<Float> // decay, clear history, bloom strength, surface enabled
    var regions: SIMD4<Float> // UI status top/bottom, main action top/bottom
    var interaction: SIMD4<Float> = SIMD4(0,1,0,0) // clear zone, press scale, reduced-motion vignette, reserved
    var collapse: SIMD4<Float> = .zero // amount, center in points.xy, peripheral optics gain
}

/// Recording feedback only: no audio, view or display-link ownership. All clocks use
/// monotonic seconds. Return curves are analytic, so a skipped frame cannot explode.
struct PhosphorCollapse {
    enum Ending { case sent, cancelled }
    struct Sample {
        var amount: Double
        var vignette: Double
        var streak: Double
        var needsFrames: Bool
    }
    static let maximum = 0.08
    static let timeConstant = 45.0
    static let onsetTimeConstant = 1.5
    static let opticsTimeConstant = 28.0
    private var recordingBegan: Double?
    private var returnBegan: Double?
    private var returnOrigin = 0.0
    private var returnOpticsOrigin = 0.0
    private var ending: Ending = .cancelled
    private var reduced = false
    private var level = 0.5
    private var levelTime: Double?

    mutating func configure(elapsed: Double?, ending: Ending, reduced: Bool, now: Double) {
        let current = value(at: now).0
        let currentOptics = opticalValue(at: now)
        let motionChanged = self.reduced != reduced
        self.reduced = reduced
        if let elapsed, elapsed.isFinite {
            if recordingBegan == nil {
                recordingBegan = now - max(0, elapsed)
                level = 0.5
                levelTime = now
            }
            returnBegan = nil
        } else if recordingBegan != nil || (returnBegan != nil && (motionChanged || self.ending != ending)) {
            recordingBegan = nil
            returnOrigin = ending == .cancelled ? max(0, current) : current
            returnOpticsOrigin = currentOptics
            returnBegan = now
            self.ending = ending
        }
    }

    mutating func advance(level target: Double, now: Double) -> Sample {
        let dt = max(0, now - (levelTime ?? now))
        let safeTarget = target.isFinite ? min(1, max(0, target)) : 0.5
        level += (safeTarget - level) * (1 - exp(-dt / 0.12))
        levelTime = now
        let frame = sample(at: now)
        if !frame.needsFrames { returnBegan = nil; returnOrigin = 0; returnOpticsOrigin = 0 }
        return frame
    }

    func sample(at now: Double) -> Sample {
        let (amount, velocity) = value(at: now)
        let active = recordingBegan != nil || (returnBegan != nil && (abs(amount) >= 0.0005 || abs(velocity) >= 0.003))
        let a = active ? amount : 0
        return Sample(amount: reduced ? 0 : a,
                      vignette: reduced ? min(0.25, max(0, a / Self.maximum) * 0.25) : 0,
                      streak: reduced || !active ? 0 : opticalValue(at: now), needsFrames: active)
    }

    private func opticalValue(at now: Double) -> Double {
        if let began = recordingBegan {
            let t = max(0, now - began), q = min(32, t / 1.2)
            return 0.25 * (1 - exp(-q * q)) + 0.75 * (1 - exp(-t / Self.opticsTimeConstant))
        }
        guard returnBegan != nil, returnOrigin > 0.000001 else { return 0 }
        return returnOpticsOrigin * min(1, max(0, value(at: now).0 / returnOrigin))
    }

    private func value(at now: Double) -> (Double, Double) {
        if let began = recordingBegan {
            let t = max(0, now - began)
            let q = min(32, t / Self.onsetTimeConstant)
            let onset = exp(-q * q), accumulation = exp(-t / Self.timeConstant)
            // Show a small cue within a few seconds; reserve most of the gentle
            // range for prolonged speech. A slow curve alone hid short recordings.
            let progress = 0.20 * (1 - onset) + 0.80 * (1 - accumulation)
            let speed = 0.20 * onset * 2 * q / Self.onsetTimeConstant + 0.80 * accumulation / Self.timeConstant
            let pulse = 1 + 0.12 * (level - 0.5)
            return (min(Self.maximum, Self.maximum * progress * pulse), Self.maximum * speed * pulse)
        }
        guard let began = returnBegan else { return (0, 0) }
        let t = max(0, now - began)
        if reduced {
            return t >= 0.2 ? (0, 0) : (returnOrigin * (1 - t / 0.2), -returnOrigin / 0.2)
        }
        func critical(_ origin: Double, _ age: Double, _ omega: Double) -> (Double, Double) {
            let e = exp(-omega * age)
            return (origin * (1 + omega * age) * e, -origin * omega * omega * age * e)
        }
        guard ending == .sent else { return critical(returnOrigin, t, 40) }
        let omega = 2 * Double.pi / 0.32, decay = 0.55 * omega
        let frequency = omega * sqrt(1 - 0.55 * 0.55), minimumTime = Double.pi / frequency
        if t <= minimumTime {
            let e = exp(-decay * t), c = cos(frequency * t), s = sin(frequency * t)
            return (returnOrigin * e * (c + decay / frequency * s),
                    -returnOrigin * e * omega * omega / frequency * s)
        }
        // Join at the first minimum (zero velocity); recover without a second crossing.
        return critical(-returnOrigin * exp(-decay * minimumTime), t - minimumTime, 32)
    }
}

struct PhosphorPressSpring {
    private var origin:Double=1
    private var velocity:Double=0
    private var target:Double=1
    private var began:Double=0

    mutating func set(pressed:Bool,at time:Double){
        let next=pressed ? 0.986:1
        guard next != target else{return}
        let sample=value(at:time)
        origin=sample.0;velocity=sample.1;target=next;began=time
    }
    func value(at time:Double)->(Double,Double){
        let t=max(0,time-began),omega=2*Double.pi/0.24,zeta=0.7
        let decay=zeta*omega,frequency=omega*sqrt(1-zeta*zeta)
        let a=origin-target,b=(velocity+decay*a)/frequency,e=exp(-decay*t)
        let c=cos(frequency*t),s=sin(frequency*t)
        return (target+e*(a*c+b*s),e*((b*frequency-decay*a)*c+(-a*frequency-decay*b)*s))
    }
}

/// One lighting profile for both Metal and the Canvas fallback. Progress runs
/// from the fading tail to the moving head, independent of rotation direction.
enum PhosphorOrbitLight {
    static let segments = 18
    static let trailAngle: CGFloat = 0.16

    static func angle(head: CGFloat, direction: CGFloat, progress: CGFloat) -> CGFloat {
        head - direction * trailAngle * (1 - progress)
    }

    static func tailGain(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return 0.04 + 0.96 * t * t
    }

    static func depthGain(_ angle: CGFloat) -> CGFloat {
        // Positive z (the lower half in the front view) is nearer the viewer.
        0.45 + 0.55 * (0.5 + 0.5 * sin(angle))
    }
}

enum PhosphorMath {
    /// 12ms: a hint of phosphor afterglow. At 32ms, wire emission 3–5× SDR white took ~140ms
    /// to fade and dragged a visible ghost behind a pulled coil.
    static func decay(dt: Double, lifetime: Double = 0.012) -> Float {
        Float(exp(-max(0, dt) / lifetime))
    }

    static func ring(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat,
                     rotation: CGFloat, depth: Float, opacity: CGFloat) -> PhosphorRing {
        let radius = max(0.01, Float(radiusY))
        let ratio = min(0.96, max(0.01, Float(radiusX) / radius))
        let c = Float(cos(rotation)), s = Float(sin(rotation))
        return PhosphorRing(center: SIMD3(Float(center.x), Float(center.y), depth),
            u: SIMD3(ratio * c, ratio * s, sqrt(1 - ratio * ratio)),
            v: SIMD3(-s, c, 0), radius: radius, opacity: Float(opacity))
    }

    static func smooth(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
