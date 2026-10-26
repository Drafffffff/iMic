import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// Check the properties that prevent the reported pile-up, across iPhone widths and loads.
let source = CGRect(x: 22, y: 700, width: 358, height: 70)
for fraction: CGFloat in [0, 0.1, 0.5, 0.9, 1] {
    let point = ReceiverEmission.origin(source: source, touchFraction: fraction,
        glyphSide: 38.4, canvasWidth: 402, seed: 0.5)
    expect(abs(point.x - (22 + fraction * 358)) < 0.001, "Entry must align vertically above the finger")
    expect(abs(point.y + 19.2 - 697) < 0.001, "The glyph bottom must clear the button top by 3pt")
}
let fallback = ReceiverEmission.origin(source: source, touchFraction: nil, glyphSide: 38.4, canvasWidth: 402, seed: 0.5)
expect(fallback.x == 201, "Hands-free entry must fall back to the button center")
for fraction: CGFloat in [-2, 2] {
    let point = ReceiverEmission.origin(source: source, touchFraction: fraction, glyphSide: 38.4, canvasWidth: 402, seed: fraction < 0 ? 0 : 1)
    expect(point.x >= 21.2 && point.x <= 380.8, "Edge touches must keep the full entry glyph on screen")
}
for width: CGFloat in [320, 375, 402, 440, 852] {
    var previousSize: CGFloat = .greatestFiniteMagnitude
    for count in [0, 1, 8, 12, 24, 60, 120, 180, 500, 5000, 100_000] {
        let layout = ReceiverFlightLayout(count: count, width: width, seed: 0)
        expect(layout.exitSide <= previousSize, "More text must never produce bigger glyphs")
        expect(layout.exitSide >= 32, "Dense loads must retain readable glyphs")
        expect(layout.visibleCount <= 64, "Visual workload must be bounded")
        previousSize = layout.exitSide
        guard count > 0 else { continue }
        var lastSource = -1
        var targets: [CGFloat] = []
        var speeds: [CGFloat] = []
        expect(layout.emphasis >= 0.72, "Dense loads must retain a strong launch impulse")
        for index in 0..<layout.visibleCount {
            let source = layout.sourceIndex(for: index)
            expect(source > lastSource && source < count, "Samples must be unique and in bounds")
            lastSource = source
            let x = layout.targetX(for: index)
            expect(x - layout.exitSide * 0.75 >= 0, "Glyph must clear the left edge")
            expect(x + layout.exitSide * 0.75 <= width, "Glyph must clear the right edge")
            expect(layout.delay(for: index) >= 0 && layout.delay(for: index) < 1.0 / 60,
                   "The entire load must fire within one display frame, never queue in waves")
            expect(abs(layout.tilt(for: index)) <= 0.22, "Launch tilt must preserve recognizable glyphs")
            targets.append(x)
            speeds.append(layout.speedMultiplier(for: index))
        }
        expect(layout.sourceIndex(for: 0) == 0, "Keep the start of the visual load")
        expect(lastSource == count - 1, "Keep the end of the visual load")
        if count >= 8 {
            expect(Set(targets).count == targets.count, "Shots must not share fixed exit lanes")
            expect(targets.max()! - targets.min()! > width * 0.45, "Burst must fan across the screen")
            expect(speeds.max()! - speeds.min()! > 0.45, "Speed differences must open up the burst vertically")
        }
    }
}
for width: CGFloat in [0, 1, 20] {
    let layout = ReceiverFlightLayout(count: 1000, width: width, seed: 0)
    expect(layout.visibleCount >= 1 && layout.exitSide.isFinite, "Transient layout sizes must be safe")
}
// Release randomness is frozen, reproducible with a seed, and bounded across seeds.
let releaseA = ReceiverFlightLayout(count: 120, width: 402, seed: 101)
let replayA = ReceiverFlightLayout(count: 120, width: 402, seed: 101)
let releaseB = ReceiverFlightLayout(count: 120, width: 402, seed: 202)
expect(releaseA.targetX(for: 0) != releaseB.targetX(for: 0), "A new release must change the flight pattern")
expect(releaseA.speedMultiplier(for: 0) != releaseB.speedMultiplier(for: 0), "A new release must change speed distribution")
expect(releaseA.bend(for: 0) != releaseB.bend(for: 0), "A new release must change mid-flight curvature")
for seed in UInt64(0)..<128 {
    let release = ReceiverFlightLayout(count: 120, width: 402, seed: seed)
    for index in 0..<release.visibleCount {
        expect(abs(release.bend(for: index)) <= 10, "Mid-flight perturbations must remain subtle")
        expect(release.speedMultiplier(for: index) >= 0.78 && release.speedMultiplier(for: index) <= 1.42,
               "Randomness must retain the arrow's existing speed envelope")
        expect(release.delay(for: index) < 1.0 / 60, "Randomness must not turn a burst into a queue")
        expect(release.targetX(for: index) >= 32 && release.targetX(for: index) <= 370,
               "Random exit points must retain the edge clearance")
    }
}
for index in 0..<releaseA.visibleCount {
    expect(releaseA.targetX(for: index) == replayA.targetX(for: index)
        && releaseA.speedMultiplier(for: index) == replayA.speedMultiplier(for: index)
        && releaseA.bend(for: index) == replayA.bend(for: index),
        "A shutter's subframes must reuse the same variation, not sample fresh noise")
}
let curvedArrow = ReceiverArrowFlight(speed: 4000)
for age: CGFloat in [0, 0.02, 0.04, 0.06, 0.1, 0.2] {
    func pose(bend: CGFloat) -> ReceiverFlightPose {
        curvedArrow.pose(at: age, origin: CGPoint(x: 200, y: 450), velocity: CGPoint(x: 300, y: -3988),
            exitSide: 32, emphasis: 1, rotation: 0.2, tilt: 0, opacity: 1, bend: bend)
    }
    let straight = pose(bend: 0), bent = pose(bend: 10)
    expect(abs(bent.center.x - straight.center.x) <= 10.001 && bent.center.y == straight.center.y,
           "Curvature must not slow vertical flight or cause large swerves")
    if age == 0 || straight.center.y <= 0 {
        expect(bent.center == straight.center, "Mid-flight perturbation must vanish at release and exit")
    }
}
// The arrow must be fastest at release, never acquire thrust after leaving the string.
for initial: CGFloat in [0, 1000, 4000, 8000] {
    let arrow = ReceiverArrowFlight(speed: initial)
    expect(arrow.distance(at: 0) == 0 && arrow.speed(at: 0) == initial, "Release must start at full launch speed")
    var lastSpeed = initial
    var lastDistance: CGFloat = -1
    for age: CGFloat in [0, 0.008, 0.016, 0.04, 0.08, 0.12, 0.2] {
        let speed = arrow.speed(at: age)
        let distance = arrow.distance(at: age)
        expect(speed <= lastSpeed && speed >= 0, "Drag must only reduce speed")
        expect(distance >= lastDistance && distance <= initial * age + 0.0001, "Flight must advance without post-release acceleration")
        let epsilon: CGFloat = 0.000001
        let measuredSpeed = (arrow.distance(at: age + epsilon) - distance) / epsilon
        expect(abs(measuredSpeed - speed) < 0.1, "Position and velocity must describe the same motion")
        lastSpeed = speed
        lastDistance = distance
    }
}
for height: CGFloat in [600, 852, 932] {
    let clearance = height * 0.55
    let weak = ReceiverArrowFlight.launchSpeed(height: height, clearance: clearance,
        strength: 0, bowVelocity: 0, variation: 0.78)
    let strong = ReceiverArrowFlight.launchSpeed(height: height, clearance: clearance,
        strength: 1, bowVelocity: 0, variation: 0.78)
    let inherited = ReceiverArrowFlight.launchSpeed(height: height, clearance: clearance,
        strength: 1, bowVelocity: -1200, variation: 0.78)
    expect(strong > weak * 1.3 && inherited > strong, "Pull and upward string velocity must strengthen the shot")
    expect(ReceiverArrowFlight(speed: weak).distance(at: 0.22) > clearance + 60,
           "Even weak/slow shots must clear the screen and blur promptly")
}
let arrow = ReceiverArrowFlight(speed: 4000)
expect(arrow.distance(at: 0.05) > arrow.distance(at: 0.1) - arrow.distance(at: 0.05),
       "The first 50ms must cover more distance than the next 50ms")
let shutter = ReceiverShutter()
for age: CGFloat in [0, 0.016, 0.05, 0.12] {
    var mean: CGFloat = 0
    for index in 0..<ReceiverShutter.maximumSamples {
        let time = shutter.sampleAge(index, count: ReceiverShutter.maximumSamples, at: age)
        expect(abs(time - age) < shutter.duration / 2, "All samples must lie inside the shutter")
        mean += time / CGFloat(ReceiverShutter.maximumSamples)
    }
    expect(abs(mean - age) < 0.000001, "Exposure must be centered on the current frame, not trail behind it")
}
let staticPose = ReceiverFlightPose(center: CGPoint(x: 50, y: 50), size: CGSize(width: 16, height: 16),
    rotation: 0, opacity: 1, warmth: 0)
expect(shutter.sampleCount(start: staticPose, end: staticPose) == 1, "Static glyphs must retain their original sharp rendering")
let rotated = ReceiverFlightPose(center: staticPose.center, size: staticPose.size, rotation: .pi / 2, opacity: 1, warmth: 0)
let scaled = ReceiverFlightPose(center: staticPose.center, size: CGSize(width: 32, height: 32), rotation: 0, opacity: 1, warmth: 0)
expect(shutter.sampleCount(start: staticPose, end: rotated) > 1, "Rotation alone must cause temporal sampling")
expect(shutter.sampleCount(start: staticPose, end: scaled) > 1, "Scale alone must cause temporal sampling")
let early = arrow.pose(at: 0.012, origin: CGPoint(x: 200, y: 450), velocity: CGPoint(x: 0, y: -4000),
    exitSide: 32, emphasis: 1, rotation: 0.5, tilt: 0, opacity: 0.94)
let later = arrow.pose(at: 0.018, origin: CGPoint(x: 200, y: 450), velocity: CGPoint(x: 0, y: -4000),
    exitSide: 32, emphasis: 1, rotation: 0.5, tilt: 0, opacity: 0.94)
expect(later.center.y < early.center.y && later.size != early.size && later.rotation != early.rotation,
       "Subframes must evaluate actual position, scale and rotation")
expect(later.warmth != early.warmth, "The launch flash must be exposed at the sampled time")
try verifyMetalExposure(shaderPath: CommandLine.arguments[1])
print("Receiver flight: density, arrow physics, centered shutter and GPU exposure integration checks passed")
