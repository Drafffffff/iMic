import AudioToolbox
import AVFoundation
import QuartzCore
import UIKit

/// iMic 的界面音效。所有音在启动后用代码离线合成（振荡器 + 包络 + 滤波），
/// 写成 16-bit PCM WAV 注册为系统声音，由 AudioServices 播放。
///
/// 不使用 AVAudioSession / AVAudioEngine：采集链路独占会话的 category、mode 与激活时机，
/// 录音结束时会话被停用会连带停掉共享会话的播放引擎（旧 BowReleaseSound 的根因）。
/// 系统声音独立于 App 会话：遵守静音开关，录音期间由
/// `setAllowHapticsAndSystemSoundsDuringRecording(true)` 允许混音，中断与路由变化由系统处理。
@MainActor
final class SoundDesign {
    static let shared = SoundDesign()
    static let preferenceKey = "imic.sound.enabled"
    nonisolated static let primeKey = "prime"

    private enum State { case cold, warming, ready, failed }
    private var state = State.cold
    private var ids: [String: SystemSoundID] = [:]
    private var pending: (cue: SoundCue, variant: Int, at: CFTimeInterval)?
    private var observer: NSObjectProtocol?

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // 媒体服务重置后旧 SystemSoundID 全部失效，重新注册。
                let shared = SoundDesign.shared
                IMicLog.write("iphone.sound", "media services reset; re-registering")
                shared.state = .cold
                shared.ids.removeAll()
                shared.warmUp()
            }
        }
    }

    /// 后台线程合成并注册全部音色；主线程只接收 ID。可重复调用。
    func warmUp() {
        guard state == .cold || state == .failed else { return }
        state = .warming
        let began = CACurrentMediaTime()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.registerAll()
            DispatchQueue.main.async {
                let shared = SoundDesign.shared
                switch result {
                case .success(let ids):
                    shared.ids = ids
                    shared.state = .ready
                    IMicLog.write("iphone.sound", "ready sounds=\(ids.count) ms=\(Int((CACurrentMediaTime() - began) * 1000))")
                    // 系统声音服务首次播放约有 0.4 s 冷启动；先播一段静音，真实提示音不再吃这次延迟。
                    if let prime = ids[SoundDesign.primeKey] { AudioServicesPlaySystemSound(prime) }
                    if let pending = shared.pending, CACurrentMediaTime() - pending.at < 0.3 {
                        shared.fire(pending.cue, variant: pending.variant, reason: "deferred")
                    }
                case .failure(let error):
                    shared.state = .failed
                    IMicLog.write("iphone.sound", "warm-up failed: \(error.localizedDescription)")
                }
                shared.pending = nil
            }
        }
    }

    /// 语义事件入口：遵守设置开关；只在前台播放。
    func play(_ cue: SoundCue, strength: Float = 1) {
        let variant = cue.variant(strength: strength)
        guard enabled else {
            IMicLog.write("iphone.sound", "skip cue=\(cue.rawValue) reason=disabled")
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            IMicLog.write("iphone.sound", "skip cue=\(cue.rawValue) reason=inactive")
            return
        }
        fire(cue, variant: variant, reason: "event")
    }

    /// 调试试听：忽略设置开关，仍要求前台。
    func audition(_ cue: SoundCue, variant: Int) {
        fire(cue, variant: variant, reason: "audition")
    }

    private func fire(_ cue: SoundCue, variant: Int, reason: String) {
        guard state == .ready, let id = ids[cue.key(variant)] else {
            IMicLog.write("iphone.sound", "defer cue=\(cue.rawValue) state=\(state)")
            pending = (cue, variant, CACurrentMediaTime())
            warmUp()
            return
        }
        let began = CACurrentMediaTime()
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"
        let name = cue.rawValue
        IMicLog.write("iphone.sound", "play cue=\(name) v=\(variant) id=\(id) via=\(reason) route=\(route)")
        AudioServicesPlaySystemSoundWithCompletion(id) {
            // 完成回调在系统线程；耗时用于真机核对首播延迟。
            IMicLog.write("iphone.sound", "done cue=\(name) ms=\(Int((CACurrentMediaTime() - began) * 1000))")
        }
    }

    // MARK: - Rendering

    nonisolated private static func registerAll() -> Result<[String: SystemSoundID], Error> {
        do {
            let directory = try FileManager.default
                .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("iMicSounds-v\(SoundSynth.renderVersion)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var ids: [String: SystemSoundID] = [:]
            let silent = SoundPatch(cutoff: 1_000, glow: 0, peakDB: -96, voices: [])
            let primeURL = directory.appendingPathComponent("\(primeKey).wav")
            try SoundSynth.wav(silent).write(to: primeURL, options: .atomic)
            var primeID: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(primeURL as CFURL, &primeID) == noErr { ids[primeKey] = primeID }
            for cue in SoundCue.allCases {
                for variant in 0..<cue.variantCount {
                    let url = directory.appendingPathComponent("\(cue.key(variant)).wav")
                    try SoundSynth.wav(cue.patch(variant)).write(to: url, options: .atomic)
                    var id: SystemSoundID = 0
                    let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
                    guard status == noErr else {
                        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                                      userInfo: [NSLocalizedDescriptionKey: "register \(cue.key(variant)) status=\(status)"])
                    }
                    ids[cue.key(variant)] = id
                }
            }
            return .success(ids)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Cues

/// 五个音色家族：同一类状态共用波形与滤波，用音高走向和节奏区分成功、取消、错误。
enum SoundFamily: String, CaseIterable {
    case transport = "TRANSPORT"
    case string = "STRING"
    case signal = "SIGNAL"
    case link = "LINK"
    case alert = "ALERT"

    var title: String {
        switch self {
        case .transport: return "录音"
        case .string: return "弦手势"
        case .signal: return "文字"
        case .link: return "连接"
        case .alert: return "提醒"
        }
    }
}

enum SoundCue: String, CaseIterable, Identifiable {
    case release, cancelled, tooShort
    case bowArmed, snapReturn, delete, clear
    case result, polishReady, copy
    case connected, connectionLost, pairingRequired, pairingSuccess, pairingFailed
    case warning, error

    var id: String { rawValue }

    var family: SoundFamily {
        switch self {
        case .release, .cancelled, .tooShort: return .transport
        case .bowArmed, .snapReturn, .delete, .clear: return .string
        case .result, .polishReady, .copy: return .signal
        case .connected, .connectionLost, .pairingRequired, .pairingSuccess: return .link
        case .pairingFailed, .warning, .error: return .alert
        }
    }

    /// 像素字标签（英文）。
    var label: String {
        switch self {
        case .release: return "SEND"
        case .cancelled: return "CANCEL"
        case .tooShort: return "SHORT"
        case .bowArmed: return "ARMED"
        case .snapReturn: return "RETURN"
        case .delete: return "DEL"
        case .clear: return "CLEAR"
        case .result: return "TEXT"
        case .polishReady: return "POLISH"
        case .copy: return "COPY"
        case .connected: return "LINK"
        case .connectionLost: return "LOST"
        case .pairingRequired: return "PAIR?"
        case .pairingSuccess: return "PAIRED"
        case .pairingFailed: return "DENIED"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    var title: String {
        switch self {
        case .release: return "松开提交"
        case .cancelled: return "上滑取消"
        case .tooShort: return "录音太短"
        case .bowArmed: return "弦拉满"
        case .snapReturn: return "下拉回车"
        case .delete: return "上拉删除一字"
        case .clear: return "清空输入框"
        case .result: return "识别结果到达"
        case .polishReady: return "润色完成"
        case .copy: return "复制"
        case .connected: return "连接成功"
        case .connectionLost: return "连接断开"
        case .pairingRequired: return "需要配对"
        case .pairingSuccess: return "配对成功"
        case .pairingFailed: return "配对失败"
        case .warning: return "提示"
        case .error: return "出错"
        }
    }

    /// 回车按拉弦力度分三档：音高与音量随力度上升。
    var variantCount: Int { self == .snapReturn ? 3 : 1 }

    func variant(strength: Float) -> Int {
        guard variantCount > 1 else { return 0 }
        let bounded = strength.isFinite ? min(1, max(0, strength)) : 0
        return Int((bounded * Float(variantCount - 1)).rounded())
    }

    func key(_ variant: Int) -> String { variantCount > 1 ? "\(rawValue)-\(variant)" : rawValue }

    /// Haptics 语义事件到音效的唯一映射。nil 表示只有触感。
    /// 按下与开始录音不发声：此刻麦克风已打开（measurement 模式无回声消除），声音会被录进识别音频。
    static func forHaptic(_ event: Haptics.Event) -> SoundCue? {
        switch event {
        case .press, .recordingStarted: return nil
        case .release: return .release
        case .cancelled: return .cancelled
        case .tooShort: return .tooShort
        case .bowArmed: return .bowArmed
        case .stringNotchLow, .stringNotchHigh: return nil
        case .stringSnap: return .clear
        case .deleteChar: return .delete
        case .cancelArmed, .cancelDisarmed: return nil
        case .connected: return .connected
        case .connectionLost: return .connectionLost
        case .pairingRequired: return .pairingRequired
        case .pairingSuccess: return .pairingSuccess
        case .pairingFailed: return .pairingFailed
        case .codeDigit: return nil
        case .result: return .result
        case .polishReady: return .polishReady
        case .warning: return .warning
        case .error: return .error
        case .copy: return .copy
        case .tap, .overlayOpen, .overlayClose, .selection: return nil
        }
    }

    // 音名（Hz）。主体落在 A 大调五声音阶，手机扬声器在 600 Hz 以上才清晰。
    private enum Note {
        static let d5 = 587.33, e5 = 659.26, f5 = 698.46, g5 = 783.99
        static let bb4 = 466.16, b4 = 493.88
        static let a5 = 880.0, b5 = 987.77, cs6 = 1108.73, d6 = 1174.66, e6 = 1318.51
        static let fs6 = 1479.98, a6 = 1760.0, c7 = 2093.0, e7 = 2637.02
    }

    func patch(_ variant: Int) -> SoundPatch {
        typealias V = SoundVoice
        switch self {
        // TRANSPORT：25% 脉冲波，低通 3.2 kHz。上行=提交，下滑=取消，同音两下=太短。
        case .release:
            return SoundPatch(cutoff: 3_200, glow: 0, peakDB: -13, voices: [
                V(.pulse(0.25), at: 0, length: 0.026, from: Note.e6, decay: 0.030),
                V(.pulse(0.25), at: 0.030, length: 0.046, from: Note.a6, decay: 0.028)
            ])
        case .cancelled:
            return SoundPatch(cutoff: 3_200, glow: 0, peakDB: -14, voices: [
                V(.pulse(0.25), at: 0, length: 0.095, from: Note.a5, to: Note.b4, glide: 0.035, decay: 0.060)
            ])
        case .tooShort:
            return SoundPatch(cutoff: 3_200, glow: 0, peakDB: -14, voices: [
                V(.pulse(0.25), at: 0, length: 0.032, from: Note.d5, decay: 0.030),
                V(.pulse(0.25), at: 0.060, length: 0.032, from: Note.d5, decay: 0.030)
            ])
        // STRING：12.5% 细脉冲 + 白噪声瞬态，像弦也像 CRT 偏转线圈的“嗒”。
        case .bowArmed:
            return SoundPatch(cutoff: 6_000, glow: 0, peakDB: -22, voices: [
                V(.triangle, at: 0, length: 0.014, from: Note.e7, decay: 0.006)
            ])
        case .snapReturn:
            let start = [Note.fs6, Note.a6, Note.c7][min(2, max(0, variant))]
            let peak = [-14.0, -12.5, -11.0][min(2, max(0, variant))]
            return SoundPatch(cutoff: 4_200, glow: 0, peakDB: peak, voices: [
                V(.pulse(0.125), at: 0, length: 0.085, from: start, to: start / 2, glide: 0.018, decay: 0.040),
                V(.noise, at: 0, length: 0.010, from: 0, gain: 0.35, decay: 0.003)
            ])
        case .delete:
            return SoundPatch(cutoff: 4_200, glow: 0, peakDB: -17, voices: [
                V(.pulse(0.125), at: 0, length: 0.022, from: Note.d6, decay: 0.009),
                V(.noise, at: 0, length: 0.006, from: 0, gain: 0.25, decay: 0.002)
            ])
        case .clear:
            return SoundPatch(cutoff: 2_600, glow: 0, peakDB: -14, voices: [
                V(.pulse(0.25), at: 0, length: 0.140, from: Note.e6, to: 330, glide: 0.050, decay: 0.070),
                V(.noise, at: 0, length: 0.140, from: 0, gain: 0.5, decay: 0.050)
            ])
        // SIGNAL：50% 方波 + 荧光余辉（32/64 ms 两次衰减回声）。
        case .result:
            return SoundPatch(cutoff: 3_600, glow: 0.22, peakDB: -14, voices: [
                V(.pulse(0.5), at: 0, length: 0.060, from: Note.e6, decay: 0.035)
            ])
        case .polishReady:
            return SoundPatch(cutoff: 3_600, glow: 0.22, peakDB: -12, voices: [
                V(.pulse(0.5), at: 0, length: 0.035, from: Note.e6, decay: 0.030),
                V(.pulse(0.5), at: 0.040, length: 0.080, from: Note.a6, decay: 0.045)
            ])
        case .copy:
            return SoundPatch(cutoff: 6_000, glow: 0, peakDB: -18, voices: [
                V(.triangle, at: 0, length: 0.015, from: Note.c7, decay: 0.008),
                V(.triangle, at: 0.040, length: 0.015, from: Note.c7, decay: 0.008)
            ])
        // LINK：三角波，最柔和；上行=连上，下行=断开，同音两下=等待配对，琶音=配对成功。
        case .connected:
            return SoundPatch(cutoff: 5_000, glow: 0.18, peakDB: -13, voices: [
                V(.triangle, at: 0, length: 0.040, from: Note.cs6, decay: 0.040),
                V(.triangle, at: 0.045, length: 0.070, from: Note.e6, decay: 0.045)
            ])
        case .connectionLost:
            return SoundPatch(cutoff: 5_000, glow: 0.12, peakDB: -14, voices: [
                V(.triangle, at: 0, length: 0.045, from: Note.e6, decay: 0.040),
                V(.triangle, at: 0.050, length: 0.090, from: Note.a5, decay: 0.055)
            ])
        case .pairingRequired:
            return SoundPatch(cutoff: 5_000, glow: 0, peakDB: -15, voices: [
                V(.triangle, at: 0, length: 0.035, from: Note.e6, decay: 0.030),
                V(.triangle, at: 0.075, length: 0.035, from: Note.e6, decay: 0.030)
            ])
        case .pairingSuccess:
            return SoundPatch(cutoff: 5_000, glow: 0.20, peakDB: -12, voices: [
                V(.triangle, at: 0, length: 0.040, from: Note.a5, decay: 0.040),
                V(.triangle, at: 0.045, length: 0.040, from: Note.cs6, decay: 0.040),
                V(.triangle, at: 0.090, length: 0.090, from: Note.e6, decay: 0.060)
            ])
        // ALERT：方波低通 2.2 kHz，音域压低；小二度=否定。
        case .pairingFailed:
            return SoundPatch(cutoff: 2_200, glow: 0, peakDB: -13, voices: [
                V(.pulse(0.5), at: 0, length: 0.050, from: Note.f5, decay: 0.040),
                V(.pulse(0.5), at: 0.060, length: 0.060, from: Note.e5, decay: 0.045)
            ])
        case .warning:
            return SoundPatch(cutoff: 2_200, glow: 0, peakDB: -14, voices: [
                V(.pulse(0.5), at: 0, length: 0.070, from: Note.d5, decay: 0.040)
            ])
        case .error:
            return SoundPatch(cutoff: 2_000, glow: 0, peakDB: -11, voices: [
                V(.pulse(0.5), at: 0, length: 0.060, from: Note.bb4, decay: 0.050),
                V(.pulse(0.5), at: 0, length: 0.060, from: Note.b4, decay: 0.050),
                V(.pulse(0.5), at: 0.080, length: 0.070, from: Note.bb4, decay: 0.050),
                V(.pulse(0.5), at: 0.080, length: 0.070, from: Note.b4, decay: 0.050)
            ])
        }
    }
}

// MARK: - Synth

struct SoundVoice {
    enum Wave { case pulse(Double), triangle, noise }
    var wave: Wave
    var at: Double
    var length: Double
    var from: Double
    var to: Double?
    var glide: Double
    var gain: Double
    var attack: Double
    var decay: Double

    init(_ wave: Wave, at: Double, length: Double, from: Double, to: Double? = nil,
         glide: Double = 0.02, gain: Double = 1, attack: Double = 0.0015, decay: Double) {
        self.wave = wave
        self.at = at
        self.length = length
        self.from = from
        self.to = to
        self.glide = glide
        self.gain = gain
        self.attack = attack
        self.decay = decay
    }
}

struct SoundPatch {
    var cutoff: Double
    var glow: Double
    var peakDB: Double
    var voices: [SoundVoice]

    var duration: Double {
        (voices.map { $0.at + $0.length }.max() ?? 0) + (glow > 0 ? SoundSynth.glowTail : 0) + SoundSynth.tail
    }
}

enum SoundSynth {
    /// 改动任何参数时递增，避免沿用旧缓存文件名。
    static let renderVersion = 2
    static let sampleRate = 44_100.0
    static let glowDelay = 0.032
    static let glowTail = 0.070
    /// 滤波器余振的收尾空间；末 3 ms 线性淡出，保证首尾样本为 0、不爆音。
    static let tail = 0.008

    /// 合成单声道浮点样本：振荡器（PolyBLEP 脉冲 / 三角 / 噪声）→ 线性起音 + 指数衰减 + 4 ms 收尾
    /// → 荧光余辉 → 两级一阶低通 → 150 Hz 高通去直流 → 峰值归一化到 peakDB。
    static func render(_ patch: SoundPatch) -> [Float] {
        let count = Int((patch.duration * sampleRate).rounded(.up))
        var buffer = [Double](repeating: 0, count: count)
        var seed: UInt32 = 0x1A2B_3C4D
        for voice in patch.voices {
            let first = Int(voice.at * sampleRate)
            let frames = Int(voice.length * sampleRate)
            var phase = 0.0
            for frame in 0..<frames where first + frame < count {
                let t = Double(frame) / sampleRate
                let frequency: Double
                if let target = voice.to {
                    frequency = target + (voice.from - target) * exp(-t / voice.glide)
                } else {
                    frequency = voice.from
                }
                let step = frequency / sampleRate
                let value: Double
                switch voice.wave {
                case .pulse(let duty):
                    var naive = phase < duty ? 1.0 : -1.0
                    naive += polyBLEP(phase, step)
                    naive -= polyBLEP((phase - duty + 1).truncatingRemainder(dividingBy: 1), step)
                    value = naive
                case .triangle:
                    value = 1 - 4 * abs(phase - 0.5)
                case .noise:
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    value = Double(seed) / Double(UInt32.max) * 2 - 1
                }
                phase += step
                if phase >= 1 { phase -= 1 }
                let attack = min(1, t / voice.attack)
                let release = min(1, (voice.length - t) / 0.004)
                buffer[first + frame] += value * voice.gain * attack * release * exp(-t / voice.decay)
            }
        }
        if patch.glow > 0 {
            let delay = Int(glowDelay * sampleRate)
            let dry = buffer
            for index in delay..<count {
                buffer[index] += patch.glow * dry[index - delay]
                if index >= 2 * delay { buffer[index] += patch.glow * patch.glow * dry[index - 2 * delay] }
            }
        }
        let lowA = 1 - exp(-2 * Double.pi * patch.cutoff / sampleRate)
        let highRC = 1 / (2 * Double.pi * 150)
        let highA = highRC / (highRC + 1 / sampleRate)
        var low1 = 0.0, low2 = 0.0, highY = 0.0, highX = 0.0
        var peak = 0.0
        for index in 0..<count {
            low1 += lowA * (buffer[index] - low1)
            low2 += lowA * (low1 - low2)
            highY = highA * (highY + low2 - highX)
            highX = low2
            buffer[index] = highY
            peak = max(peak, abs(highY))
        }
        let scale = peak > 0 ? pow(10, patch.peakDB / 20) / peak : 0
        let fade = Int(0.003 * sampleRate)
        return buffer.enumerated().map { index, value in
            Float(value * scale * min(1, Double(count - 1 - index) / Double(fade)))
        }
    }

    static func wav(_ patch: SoundPatch) -> Data {
        let samples = render(patch)
        let rate = Int(sampleRate)
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 2))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        return data
    }

    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}
