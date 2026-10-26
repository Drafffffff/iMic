#if DEBUG
import Foundation
import UIKit

/// Explicit, standalone UI diagnostics: no Mac commands, microphone or network audio.
@MainActor
enum StandbyDiagnostics {
    private enum Failure: Error { case check }

    private static func check(_ value: Bool, _ stage: String) throws {
        guard value else {
            IMicLog.write("iphone.power", "visual check FAIL stage=\(stage)")
            throw Failure.check
        }
    }

    private static func settle(_ spectrum: SpectrumStore) async throws -> Bool {
        // First-use CoreText glyph preparation runs asynchronously; wait for actual
        // quiescence with a hard deadline, rather than assuming cached-font latency.
        let deadline = Date().addingTimeInterval(8)
        while spectrum.isClockRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        return !spectrum.isClockRunning
    }

    private static func verifyRestingShape() throws {
        func profile(energy: CGFloat, peak: CGFloat) -> CGFloat {
            TorusGeometry.ringProfile(
                energy: energy,
                relief: .init(bands: [peak] + [CGFloat](repeating: 0, count: 43)), level: 0,
                breath: 0.5, texture: 0, envelope: 1).radius
        }
        let resting = profile(energy: 0, peak: 0)
        try check(resting >= 0.62 && resting <= 0.72, "fuller resting string")
        try check(profile(energy: 0, peak: 1) < 0.4, "voiced valleys remain distinct")
        try check(profile(energy: 1, peak: 1) > 0.9, "voiced peaks retain range")
        var previous = resting
        for step in 1...1000 {
            let energy = CGFloat(step) / 1000
            let next = profile(energy: energy, peak: energy)
            try check(abs(next - previous) < 0.004, "continuous resting to voiced contour")
            previous = next
        }
        for size in [CGSize(width: 272, height: 240), CGSize(width: 354, height: 300)] {
            for pull: CGFloat in [-1000, -60, 0, 60, 1000] {
                let frame = SpectrumFrame(bands: [CGFloat](repeating: 0, count: 44),
                                          breath: 0.5, time: 0, level: 0, peak: 0)
                let layout = TorusGeometry.Layout(size: size, frame: frame, pull: pull,
                                                  anchor: 0.5, reducedMotion: false)
                for index in 0..<44 {
                    let ring = layout.ring(at: index)
                    let extent = abs(sin(ring.rotation)) * ring.radiusX
                        + abs(cos(ring.rotation)) * ring.radiusY
                    try check(ring.center.y - extent >= 0 && ring.center.y + extent <= size.height,
                              "full resting contour stays within drag canvas")
                }
            }
        }
    }

    private static func verifyAmbientEnvelope() throws {
        var envelope = AmbientMotionEnvelope()
        envelope.noteActivity(at: 100)
        try check(envelope.target(at: 139.99) == 1, "ambient holds forty seconds")
        try check(envelope.target(at: 140) == 1, "fade starts without a jump")
        try check(abs(envelope.target(at: 142) - 0.5) < 0.0001, "fade midpoint")
        var previous: CGFloat = 1
        for step in 0...400 {
            let next = envelope.advance(at: 140 + Double(step) / 100, dt: 0.01)
            try check(next <= previous && previous - next < 0.004, "continuous monotonic ambient fade")
            previous = next
        }
        try check(envelope.intensity == 0, "ambient reaches complete rest")
        envelope.noteActivity(at: 145)
        try check(envelope.intensity == 0, "wake preserves the displayed intensity")
        let resumed = envelope.advance(at: 145, dt: 1.0 / 60)
        try check(resumed > 0 && resumed < 0.1, "decoration resumes smoothly")
        try check(envelope.target(at: 184.99) == 1, "new activity renews the full hold")
    }

    static func run(spectrum: SpectrumStore, receiver: ReceiverFlowStore) async {
        IMicLog.write("iphone.power", "visual check START")
        do {
            try verifyRestingShape()
            try verifyAmbientEnvelope()
            spectrum.configureAmbientMotion(enabled: true, reducedMotion: false)
            spectrum.wake()
            try await Task.sleep(for: .seconds(2.5))
            try check(spectrum.isClockRunning && spectrum.frame.ambientIntensity > 0.99,
                      "ambient remains alive after short inactivity")
            while spectrum.ambientIdleDuration < 39.8 {
                try await Task.sleep(for: .milliseconds(100))
            }
            try check(spectrum.isClockRunning && spectrum.frame.ambientIntensity > 0.99,
                      "live clock retains forty-second hold")
            while spectrum.ambientIdleDuration < 42 {
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(spectrum.isClockRunning && spectrum.frame.ambientIntensity > 0.35
                      && spectrum.frame.ambientIntensity < 0.65, "live clock fades gradually")
            let ambientSettled = try await settle(spectrum)
            try check(ambientSettled && spectrum.frame.ambientIntensity == 0, "ambient fades to idle")
            let ticks = spectrum.renderedTicks
            try await Task.sleep(for: .milliseconds(300))
            try check(spectrum.renderedTicks == ticks, "zero standby callbacks")

            // The full forty-second policy was tested above; isolate finite feedback below.
            spectrum.configureAmbientMotion(enabled: false, reducedMotion: false)

            let motion = spectrum.stringMotion
            let gestureTicks = spectrum.renderedTicks
            motion.begin(anchor: 0.5, height: 200)
            motion.drag(translation: 60, velocity: 0, returnEnabled: false, deleteEnabled: false)
            try check(spectrum.isClockRunning, "gesture wakes clock")
            try await Task.sleep(for: .seconds(1.5))
            try check(spectrum.isClockRunning, "held gesture stays active")
            try check(spectrum.renderedTicks > gestureTicks, "gesture produces frames")
            _ = motion.finish(translation: 60, velocity: 0, returnEnabled: false, deleteEnabled: false)
            let springSettled = try await settle(spectrum)
            try check(springSettled, "spring settles")

            receiver.reset()
            receiver.update(text: "省电待机之后文字仍能正常落到弦上")
            try check(spectrum.isClockRunning, "new glyphs wake clock")
            let textSettled = try await settle(spectrum)
            try check(textSettled, "attached text becomes static")
            receiver.fire()
            try check(spectrum.isClockRunning, "release wakes clock")
            try await Task.sleep(for: .seconds(2))
            try check(!spectrum.isClockRunning, "flight and ink settle")

            spectrum.setVisible(false)
            spectrum.update([CGFloat](repeating: 0, count: 44), level: 0)
            try check(!spectrum.isClockRunning, "hidden view ignores wake")
            spectrum.setVisible(UIApplication.shared.applicationState == .active)
            try check(spectrum.isClockRunning, "foreground resumes")
            try await Task.sleep(for: .seconds(1.5))
            try check(!spectrum.isClockRunning, "foreground returns to standby")
            spectrum.configureAmbientMotion(enabled: true, reducedMotion: true)
            let reducedSettled = try await settle(spectrum)
            try check(reducedSettled, "Reduce Motion skips ambient hold")
            spectrum.configureAmbientMotion(enabled: true, reducedMotion: false)
            IMicLog.write("iphone.power", "visual check PASS")
        } catch {
            spectrum.stringMotion.cancel()
            receiver.reset()
            spectrum.setVisible(UIApplication.shared.applicationState == .active)
        }
    }
}
#endif
