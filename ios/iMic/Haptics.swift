import CoreHaptics
import Foundation
import QuartzCore
import UIKit

/// 全 App 的语义化触感。优先 Core Haptics 播放细腻短模式，
/// 失败或不支持时回落到 UIFeedbackGenerator。
@MainActor
final class Haptics {
    static let shared = Haptics()

    enum Event: Hashable {
        case press
        case recordingStarted
        case release
        case bowArmed
        case stringNotchLow
        case stringNotchHigh
        case stringSnap
        case cancelArmed
        case cancelDisarmed
        case cancelled
        case tooShort

        case connected
        case pairingRequired
        case pairingSuccess
        case connectionLost
        case codeDigit
        case pairingFailed

        case result
        case polishReady
        case warning
        case error
        case copy
        case tap
        case overlayOpen
        case overlayClose
        case selection
    }

    private var engine: CHHapticEngine?
    private var patterns: [Event: CHHapticPattern] = [:]
    private var players: [Event: CHHapticPatternPlayer] = [:]
    private var lastPlayed: [Event: CFTimeInterval] = [:]
    private var prepared = false
    private var engineFailed = false
    private var coreReady = false
    private var engineGeneration: UInt64 = 0
    private var bowPrepared = false

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    private init() {}

    func prepare(force: Bool = false) {
        guard UIApplication.shared.applicationState == .active else { return }
        if !prepared {
            prepared = true
            light.prepare()
            medium.prepare()
            heavy.prepare()
            soft.prepare()
            rigid.prepare()
            notification.prepare()
            selection.prepare()
            buildPatterns()
        }
        if force { engineFailed = false }
        guard engine == nil, !engineFailed,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        startEngine()
    }

    /// 只预热拉满提示；真正释放的音触由 BowReleaseSound 统一拥有。
    func prepareBowArmed() {
        guard UIApplication.shared.applicationState == .active else { return }
        prepare(force: true)
        rigid.prepare()
        bowPrepared = true
        prepareBowPlayers()
    }

    func stop() {
        engineGeneration &+= 1
        bowPrepared = false
        let stoppedEngine = engine
        engine = nil
        coreReady = false
        players.removeAll()
        stoppedEngine?.stop { error in
            if let error {
                IMicLog.write("iphone.haptics", "engine stop failed: \(error.localizedDescription)")
            }
        }
    }

    func play(_ event: Event) {
        guard UIApplication.shared.applicationState == .active else { return }
        prepare()
        let now = CACurrentMediaTime()
        if let last = lastPlayed[event], now - last < minimumInterval(event) { return }
        lastPlayed[event] = now

        if coreReady, let engine = engine, let pattern = patterns[event] {
            do {
                let player: CHHapticPatternPlayer
                if let cached = players[event] {
                    player = cached
                } else {
                    player = try engine.makePlayer(with: pattern)
                    players[event] = player
                }
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                IMicLog.write("iphone.haptics", "playback failed event=\(event): \(error.localizedDescription)")
                stop()
            }
        }
        playFallback(event)
    }

    private func minimumInterval(_ event: Event) -> CFTimeInterval {
        switch event {
        case .codeDigit: return 0.03
        case .connected, .pairingSuccess, .result: return 0.4
        case .recordingStarted: return 0.15
        case .stringNotchLow, .stringNotchHigh: return 0.045
        default: return 0.06
        }
    }

    private func startEngine() {
        engineGeneration &+= 1
        let generation = engineGeneration
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    IMicLog.write("iphone.haptics", "engine stopped reason=\(reason.rawValue)")
                    self.engine = nil
                    self.coreReady = false
                    self.players.removeAll()
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.engineGeneration == generation else { return }
                    self.restartAfterReset()
                }
            }
            try engine.start()
            self.engine = engine
            coreReady = true
            players.removeAll()
            if bowPrepared { prepareBowPlayers() }
        } catch {
            engine = nil
            coreReady = false
            engineFailed = true
            IMicLog.write("iphone.haptics", "engine start failed: \(error.localizedDescription)")
        }
    }

    private func restartAfterReset() {
        coreReady = false
        players.removeAll()
        guard UIApplication.shared.applicationState == .active, let engine else {
            stop()
            return
        }
        do {
            try engine.start()
            coreReady = true
            if bowPrepared { prepareBowPlayers() }
        } catch {
            IMicLog.write("iphone.haptics", "engine reset recovery failed: \(error.localizedDescription)")
            stop()
            engineFailed = true
        }
    }

    private func prepareBowPlayers() {
        guard coreReady, let engine else { return }
        do {
            if players[.bowArmed] == nil, let pattern = patterns[.bowArmed] {
                players[.bowArmed] = try engine.makePlayer(with: pattern)
            }
        } catch {
            IMicLog.write("iphone.haptics", "bow preparation failed: \(error.localizedDescription)")
            stop()
            rigid.prepare()
        }
    }

    private func buildPatterns() {
        // 按下：一次更沉、更实的低频脉冲，明确确认触摸已经生效。
        // 随后的 recordingStarted 仍是双击 + 短低频，负责提示“可以说话”。
        patterns[.press] = pattern([(0, 0.95, 0.3)], continuous: (0, 0.07, 0.45, 0.2))
        patterns[.recordingStarted] = pattern(
            [(0, 0.9, 0.85), (0.10, 0.55, 0.5)],
            continuous: (0, 0.14, 0.2, 0.3)
        )
        patterns[.release] = pattern([(0, 0.3, 0.25)])
        patterns[.bowArmed] = pattern([(0, 0.28, 0.78)])
        patterns[.stringNotchLow] = pattern([(0, 0.48, 0.83)], continuous: (0, 0.018, 0.12, 0.6))
        patterns[.stringNotchHigh] = pattern([(0, 0.80, 0.98)], continuous: (0, 0.022, 0.22, 0.75))
        patterns[.stringSnap] = pattern([(0, 1, 0.92), (0.075, 0.38, 0.7)], continuous: (0, 0.045, 0.45, 0.45))
        patterns[.cancelArmed] = pattern([(0, 0.55, 0.8), (0.05, 0.4, 0.7)])
        patterns[.cancelDisarmed] = pattern([(0, 0.25, 0.4)])
        patterns[.cancelled] = pattern([(0, 0.6, 0.4), (0.08, 0.3, 0.2)])
        patterns[.tooShort] = pattern([(0, 0.45, 0.2), (0.07, 0.3, 0.15)])

        patterns[.connected] = pattern([(0, 0.4, 0.35), (0.08, 0.3, 0.3)])
        patterns[.pairingRequired] = pattern([
            (0, 0.35, 0.5), (0.07, 0.45, 0.55), (0.14, 0.35, 0.5)
        ])
        patterns[.pairingSuccess] = pattern([
            (0, 0.3, 0.35), (0.08, 0.5, 0.5), (0.16, 0.7, 0.65)
        ])
        patterns[.connectionLost] = pattern([(0, 0.55, 0.2), (0.1, 0.3, 0.15)])
        patterns[.codeDigit] = pattern([(0, 0.2, 0.6)])
        patterns[.pairingFailed] = pattern([(0, 0.5, 0.3), (0.08, 0.3, 0.2)])

        patterns[.result] = pattern([(0, 0.4, 0.4), (0.09, 0.6, 0.35)])
        // 润色完成、可以发射：一记实打实的重击，再一记更脆的确认，带短促余震。
        patterns[.polishReady] = pattern([(0, 1.0, 0.55), (0.085, 0.9, 0.95)], continuous: (0.085, 0.09, 0.4, 0.6))
        patterns[.warning] = pattern([(0, 0.4, 0.3), (0.08, 0.3, 0.2)])
        patterns[.error] = pattern([
            (0, 0.6, 0.2), (0.08, 0.4, 0.15), (0.16, 0.3, 0.1)
        ])
        patterns[.copy] = pattern([(0, 0.3, 0.5)])
        patterns[.tap] = pattern([(0, 0.35, 0.4)])
        patterns[.overlayOpen] = pattern([(0, 0.3, 0.4), (0.07, 0.45, 0.5)])
        patterns[.overlayClose] = pattern([(0, 0.25, 0.35)])
        patterns[.selection] = pattern([(0, 0.25, 0.5)])
    }

    private func pattern(
        _ transients: [(TimeInterval, Float, Float)],
        continuous: (TimeInterval, TimeInterval, Float, Float)? = nil
    ) -> CHHapticPattern? {
        var events: [CHHapticEvent] = []
        for (time, intensity, sharpness) in transients {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: time
            ))
        }
        if let continuous = continuous {
            events.append(CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: continuous.2),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: continuous.3)
                ],
                relativeTime: continuous.0,
                duration: continuous.1
            ))
        }
        do {
            return try CHHapticPattern(events: events, parameters: [])
        } catch {
            IMicLog.write("iphone.haptics", "pattern creation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func playFallback(_ event: Event) {
        switch event {
        case .press:
            heavy.impactOccurred(intensity: 1)
        case .recordingStarted:
            medium.impactOccurred(intensity: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                self?.light.impactOccurred(intensity: 0.75)
            }
        case .release:
            soft.impactOccurred(intensity: 0.6)
        case .bowArmed:
            rigid.impactOccurred(intensity: 0.35)
        case .stringNotchLow, .stringNotchHigh:
            rigid.impactOccurred(intensity: event == .stringNotchHigh ? 0.9 : 0.55)
        case .stringSnap:
            heavy.impactOccurred(intensity: 1)
        case .cancelArmed, .cancelDisarmed:
            rigid.impactOccurred(intensity: event == .cancelArmed ? 0.8 : 0.45)
        case .cancelled, .warning, .tooShort:
            notification.notificationOccurred(.warning)
        case .connected:
            light.impactOccurred(intensity: 0.7)
        case .pairingRequired:
            soft.impactOccurred(intensity: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.soft.impactOccurred(intensity: 0.5)
            }
        case .pairingSuccess, .result:
            notification.notificationOccurred(.success)
        case .polishReady:
            heavy.impactOccurred(intensity: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.085) { [weak self] in
                self?.rigid.impactOccurred(intensity: 0.9)
            }
        case .connectionLost, .pairingFailed, .error:
            notification.notificationOccurred(.error)
        case .codeDigit, .selection:
            selection.selectionChanged()
        case .copy, .tap, .overlayOpen, .overlayClose:
            light.impactOccurred(intensity: 0.55)
        }
    }
}
