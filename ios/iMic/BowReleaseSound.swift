import AVFoundation
import CoreHaptics
import UIKit

/// 释放只消费预热资源：优先同一 Core Haptics pattern 的音触，失败才用播放器与单次系统触觉。
/// 不管理音频会话；采集链路始终拥有 category、mode、route 与激活时机。
@MainActor
final class BowReleaseSound {
    static let shared = BowReleaseSound()

    private static let variantCount = 5
    private var waves: [Data] = []
    private var audioPlayers: [AVAudioPlayer] = []
    private var audioPrepared = false
    private var activeAudioIndex: Int?
    private let fallbackImpact = UIImpactFeedbackGenerator(style: .rigid)

    private var engine: CHHapticEngine?
    private var corePlayers: [CHHapticPatternPlayer] = []
    private var corePrepared = false
    private var coreStarting = false
    private var activeCoreIndex: Int?
    private var resourceIDs: [CHHapticAudioResourceID] = []
    private var resourceDirectory: URL?
    private var generation: UInt64 = 0
    private var prepared = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.interrupted = type == .began
                if self.interrupted { self.invalidate() }
                // 中断结束不重放旧手势；下一次 prepare 才重新预热。
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.interrupted = false
                self?.invalidate()
            }
        })
    }

    func prepare() {
        guard UIApplication.shared.applicationState == .active, !interrupted, !prepared else { return }
        Haptics.shared.prepareBowArmed()
        fallbackImpact.prepare()
        if waves.isEmpty {
            waves = (0..<Self.variantCount).map {
                Self.makeWave(strength: Float($0) / Float(Self.variantCount - 1))
            }
        }
        prepareAudioPlayers()
        prepareCorePlayers()
        // 即使声音不可用，也保留真实的单次系统触觉；不阻塞 Return。
        prepared = true
    }

    /// Builds every expensive resource at a quiet moment after the home screen appears, so the
    /// first pull past the threshold no longer generates PCM, creates players and starts an
    /// engine on the main thread mid-gesture (a visible hitch on the first drag after launch).
    /// It does not arm a shot; `prepare()` still does that and is cheap once this has run.
    func warmUp() {
        guard UIApplication.shared.applicationState == .active, !interrupted else { return }
        if waves.isEmpty {
            waves = (0..<Self.variantCount).map {
                Self.makeWave(strength: Float($0) / Float(Self.variantCount - 1))
            }
        }
        prepareAudioPlayers()
        prepareCorePlayers()
    }

    func play(strength: Float) {
        guard UIApplication.shared.applicationState == .active, !interrupted, prepared else { return }
        prepared = false // 每次预备只可发射一次，重抓必须重新 prepare。
        let bounded = strength.isFinite ? min(1, max(0, strength)) : 0
        let index = Int((bounded * Float(Self.variantCount - 1)).rounded())
        if corePrepared, corePlayers.count == Self.variantCount {
            do {
                try corePlayers[index].start(atTime: CHHapticTimeImmediate)
                activeCoreIndex = index
                return
            } catch {
                IMicLog.write("iphone.bow", "coordinated playback refused; using fallback: \(error.localizedDescription)")
                retireFailedCore()
            }
        }
        // 热路径不生成 PCM、不创建 player、不初始化/启动引擎。
        // 降级不宣称采样级同步，但两路都在本次主线程调用中只触发一次。
        if audioPrepared, audioPlayers.count == Self.variantCount {
            let player = audioPlayers[index]
            player.currentTime = 0
            audioPrepared = false
            if player.play() {
                activeAudioIndex = index
            } else {
                IMicLog.write("iphone.bow", "fallback audio playback refused")
            }
        }
        fallbackImpact.impactOccurred(intensity: CGFloat(0.65 + 0.35 * bounded))
    }

    /// 重抓只取消本次待发与正在播放的反馈，保留健康的预热资源。
    func stop() {
        prepared = false
        if let index = activeAudioIndex {
            audioPlayers[index].pause()
            audioPlayers[index].currentTime = 0
        }
        activeAudioIndex = nil
        if let index = activeCoreIndex {
            do {
                try corePlayers[index].stop(atTime: CHHapticTimeImmediate)
            } catch {
                IMicLog.write("iphone.bow", "coordinated cancellation refused: \(error.localizedDescription)")
                retireFailedCore()
            }
        }
        activeCoreIndex = nil
    }

    /// 生命周期失效才释放播放器、注册资源与引擎；不可变 PCM 留作下次预热。
    private func invalidate() {
        prepared = false
        audioPrepared = false
        activeAudioIndex = nil
        for player in audioPlayers { player.stop() }
        audioPlayers.removeAll()
        invalidateCore()
    }

    private func retireFailedCore() {
        corePrepared = false
        let failedGeneration = generation
        // 失败清理也避开发射/重抓帧；下一次 prepare 若已重建，则不能清理新引擎。
        Task { @MainActor [weak self] in
            guard let self, self.generation == failedGeneration else { return }
            self.invalidateCore()
        }
    }

    private func prepareAudioPlayers() {
        guard !audioPrepared else { return }
        do {
            if audioPlayers.isEmpty {
                audioPlayers = try waves.map {
                    let player = try AVAudioPlayer(data: $0, fileTypeHint: AVFileType.wav.rawValue)
                    player.volume = 0.76
                    return player
                }
            }
            audioPrepared = true
            for player in audioPlayers {
                player.currentTime = 0
                if !player.prepareToPlay() { audioPrepared = false }
            }
            if !audioPrepared {
                IMicLog.write("iphone.bow", "fallback audio preparation refused")
            }
        } catch {
            audioPrepared = false
            audioPlayers.removeAll()
            IMicLog.write("iphone.bow", "fallback audio preparation failed: \(error.localizedDescription)")
        }
    }

    private func prepareCorePlayers() {
        let capabilities = CHHapticEngine.capabilitiesForHardware()
        guard capabilities.supportsHaptics, capabilities.supportsAudio else { return }
        if corePrepared || coreStarting { return }
        invalidateCore()
        let currentGeneration = generation
        do {
            let engine = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            self.engine = engine
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    IMicLog.write("iphone.bow", "coordinated engine stopped reason=\(reason.rawValue)")
                    self.prepared = false
                    self.invalidateCore()
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    let shouldPrepare = self.prepared && !self.interrupted
                        && UIApplication.shared.applicationState == .active
                    self.invalidateCore()
                    // 重置后的资源 ID 全部失效；仅在预备期重建，不在发射帧补建。
                    if shouldPrepare { self.prepareCorePlayers() }
                }
            }
            // Asynchronous start: until it completes, a release uses the existing fallback.
            coreStarting = true
            engine.start { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.engine === engine else { return }
                    self.coreStarting = false
                    if let error {
                        IMicLog.write("iphone.bow", "coordinated preparation unavailable; using fallback: \(error.localizedDescription)")
                        self.invalidateCore()
                    } else {
                        self.registerCorePlayers(engine)
                    }
                }
            }
        } catch {
            IMicLog.write("iphone.bow", "coordinated preparation unavailable; using fallback: \(error.localizedDescription)")
            invalidateCore()
        }
    }

    private func registerCorePlayers(_ engine: CHHapticEngine) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("imic-bow-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resourceDirectory = directory
            for index in 0..<Self.variantCount {
                let url = directory.appendingPathComponent("release-\(index).wav")
                try waves[index].write(to: url)
                // PCM 已有亚毫秒攻击与淡出，不再叠加系统包络钝化弦响。
                let resource = try engine.registerAudioResource(
                    url, options: [CHHapticAudioResourceKeyUseVolumeEnvelope: false]
                )
                resourceIDs.append(resource)
                let strength = Float(index) / Float(Self.variantCount - 1)
                let pattern = try Self.makePattern(resource: resource, strength: strength)
                corePlayers.append(try engine.makePlayer(with: pattern))
            }
            corePrepared = true
        } catch {
            IMicLog.write("iphone.bow", "coordinated preparation unavailable; using fallback: \(error.localizedDescription)")
            invalidateCore()
        }
    }

    private func invalidateCore() {
        corePrepared = false
        coreStarting = false
        activeCoreIndex = nil
        generation &+= 1
        let oldEngine = engine
        engine = nil
        for player in corePlayers { try? player.stop(atTime: CHHapticTimeImmediate) }
        corePlayers.removeAll()
        if let oldEngine {
            for resource in resourceIDs { try? oldEngine.unregisterAudioResource(resource) }
            oldEngine.stop(completionHandler: nil)
        }
        resourceIDs.removeAll()
        if let resourceDirectory {
            do {
                try FileManager.default.removeItem(at: resourceDirectory)
            } catch {
                IMicLog.write("iphone.bow", "wave resource cleanup failed: \(error.localizedDescription)")
            }
        }
        resourceDirectory = nil
    }

    private static func makePattern(resource: CHHapticAudioResourceID, strength: Float) throws -> CHHapticPattern {
        let attack = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 0.65 + 0.35 * strength),
                .init(parameterID: .hapticSharpness, value: 0.72 + 0.20 * strength)
            ],
            relativeTime: 0
        )
        let tail = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                .init(parameterID: .hapticIntensity, value: 0.12 + 0.10 * strength),
                .init(parameterID: .hapticSharpness, value: 0.40)
            ],
            relativeTime: 0,
            duration: 0.022
        )
        let audio = CHHapticEvent(
            audioResourceID: resource,
            parameters: [.init(parameterID: .audioVolume, value: 0.76)],
            relativeTime: 0
        )
        let decay = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 1),
                .init(relativeTime: 0.004, value: 0.62),
                .init(relativeTime: 0.012, value: 0.18),
                .init(relativeTime: 0.022, value: 0)
            ],
            relativeTime: 0
        )
        return try CHHapticPattern(events: [attack, tail, audio], parameterCurves: [decay])
    }

    private static func makeWave(strength: Float) -> Data {
        let sampleRate = 24_000
        let duration = 0.072
        let count = Int(Double(sampleRate) * duration)
        var data = Data(capacity: 44 + count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))

        let charge = Double(strength)
        var seed: UInt32 = 0xB07A_1105
        var lowPass = 0.0
        var slowPass = 0.0
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let progress = time / duration
            let attack = min(1, time / 0.00065)
            let fade = min(1, (duration - time) / 0.008)
            let frequency = (620 + 90 * charge) + 280 * exp(-time / 0.004)
            phase += 2 * .pi * frequency / Double(sampleRate)
            let twang = (sin(phase) + 0.20 * sin(phase * 2.01)) * exp(-time / 0.010)

            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            // 气流的频谱重心迅速上移；不加低频爆破或第二个攻击。
            lowPass += (0.18 + 0.45 * progress) * (noise - lowPass)
            slowPass += 0.08 * (noise - slowPass)
            let airEnvelope = (1 - exp(-time / 0.002)) * exp(-time / 0.016)
            let air = (lowPass - slowPass) * airEnvelope
            let sample = (twang * 0.44 + air * 0.64) * (0.56 + 0.30 * charge) * attack * fade
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }
}
