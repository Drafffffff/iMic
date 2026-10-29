import AudioToolbox
import AVFoundation
import QuartzCore
import UIKit

/// iMic 的界面音效。所有音在启动后用代码离线合成（8-bit 芯片声道 + 阶梯包络 + 降采样/降位深 + 滤波），
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

/// 五个音色家族（8-bit lo-fi 芯片声道）：同一类状态共用波形、音区与颗粒度，用音高走向和节奏区分成功、取消、错误。
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

    // 音名（Hz）。所有音高最终按十二平均律半音量化，与芯片的音高表一致。
    private enum Note {
        static let e3 = 164.81, a3 = 220.0, bb3 = 233.08, b3 = 246.94, d4 = 293.66, e4 = 329.63
        static let f4 = 349.23, g4 = 392.0, a4 = 440.0, d5 = 587.33, e5 = 659.26
        static let a5 = 880.0, d6 = 1174.66, e6 = 1318.51, a6 = 1760.0, c7 = 2093.0, e7 = 2637.02
    }

    /// 8-bit 踢鼓：硬起音的 25% 脉冲 + 4-bit 三角，同步从 ~190 Hz 半音阶梯下坠到 ~50 Hz，
    /// 起音叠 3 ms 高频噪声“咔嗒”。只用于提交、发射、清空这类动作音。
    /// 手机外放还原不了 50 Hz，脉冲波的 2/3 次谐波负责让“咚”在外放上听得见；耳机上有完整低频。
    private static func kick(at: Double = 0, from: Double = 190, to: Double = 50, length: Double = 0.060,
                             gain: Double = 1) -> [SoundVoice] {
        [
            SoundVoice(.pulse(0.25), at: at, length: length, from: from, to: to, glide: 0.014,
                       gain: gain, decay: length * 0.55, step: 1.0 / 480),
            SoundVoice(.triangle, at: at, length: length, from: from, to: to, glide: 0.014,
                       gain: gain * 0.9, decay: length * 0.6, step: 1.0 / 480),
            SoundVoice(.noise, at: at, length: 0.003, from: 0, gain: gain * 0.5, decay: 0.0015)
        ]
    }

    func patch(_ variant: Int) -> SoundPatch {
        typealias V = SoundVoice
        switch self {
        // TRANSPORT：动作音带踢鼓；取消只有下行阶梯、无低音冲击，太短是两下颗粒短点。
        case .release:
            // 提交：一记 8-bit 踢鼓 + 25% 脉冲短“咔”（A4），单下、干、无余辉。
            return SoundPatch(cutoff: 3_200, glow: 0, peakDB: -9, crushRate: 16_000, bits: 8, voices:
                Self.kick(length: 0.065) + [
                    V(.pulse(0.25), at: 0.004, length: 0.030, from: Note.a4, gain: 0.35, decay: 0.016)
                ])
        case .cancelled:
            // 取消：A4 → E3 按 1/60 s 一级的半音阶梯下行，像芯片里“失败”的经典走法。
            return SoundPatch(cutoff: 2_600, glow: 0, peakDB: -13, crushRate: 16_000, bits: 8, voices: [
                V(.pulse(0.25), at: 0, length: 0.140, from: Note.a4, to: Note.e3, glide: 0.050,
                  decay: 0.080, step: 1.0 / 60),
                V(.pulse(0.125), at: 0, length: 0.140, from: Note.a5, to: Note.e4, glide: 0.050,
                  gain: 0.35, decay: 0.080, step: 1.0 / 60)
            ])
        case .tooShort:
            return SoundPatch(cutoff: 2_600, glow: 0, peakDB: -13, crushRate: 11_025, bits: 7, voices: [0.0, 0.036].flatMap { at in [
                V(.pulse(0.25), at: at, length: 0.022, from: Note.g4, decay: 0.020),
                V(.pulse(0.25), at: at, length: 0.022, from: Note.g4 * 2, gain: 0.4, decay: 0.020)
            ] })
        // STRING：弦手势。RETURN 是踢鼓 + 半音阶梯上扫的发射音；CLEAR 是降频噪声 + 踢鼓。
        case .bowArmed:
            return SoundPatch(cutoff: 6_000, glow: 0, peakDB: -22, crushRate: 22_050, bits: 8, voices: [
                V(.triangle, at: 0, length: 0.016, from: Note.e7, decay: 0.008)
            ])
        case .snapReturn:
            let index = min(2, max(0, variant))
            let top = [2_000.0, 2_400.0, 2_800.0][index]
            let length = [0.150, 0.165, 0.180][index]
            let peak = [-10.0, -8.5, -7.0][index]
            // 发射：起音一记踢鼓把“推力”打出来，同时 25% 脉冲从 A3 按 1/120 s 半音阶梯急速上扫到顶，
            // 低八度 50% 方波叠厚度，起音噪声做“膛口”。上扫=送出去，与 CANCEL 的下行相反。
            return SoundPatch(cutoff: 4_800, glow: 0, peakDB: peak, crushRate: 16_000, bits: 8, voices:
                Self.kick(length: 0.070, gain: 0.9) + [
                    V(.pulse(0.25), at: 0, length: length, from: Note.a3, to: top, glide: 0.022,
                      decay: length * 0.6, step: 1.0 / 120),
                    V(.pulse(0.5), at: 0, length: length, from: Note.a3 / 2, to: top / 2, glide: 0.022,
                      gain: 0.4, decay: length * 0.6, step: 1.0 / 120),
                    V(.noise, at: 0, length: 0.016, from: 9_000, gain: 0.3, decay: 0.006)
                ])
        case .delete:
            return SoundPatch(cutoff: 4_200, glow: 0, peakDB: -17, crushRate: 16_000, bits: 8, voices: [
                V(.pulse(0.125), at: 0, length: 0.022, from: Note.d6, decay: 0.009),
                V(.noise, at: 0, length: 0.006, from: 8_000, gain: 0.3, decay: 0.002)
            ])
        case .clear:
            // CRT 关机：噪声通道时钟从 12 kHz 降到 1.5 kHz（“嘶—噗”），叠一记偏重的踢鼓。无音高走向。
            return SoundPatch(cutoff: 3_000, glow: 0, peakDB: -11, crushRate: 11_025, bits: 7, voices:
                Self.kick(from: 160, to: 45, length: 0.075, gain: 0.8) + [
                    V(.noise, at: 0, length: 0.130, from: 12_000, to: 1_500, glide: 0.040,
                      gain: 0.7, decay: 0.050, step: 1.0 / 120)
                ])
        // SIGNAL：信息提示，不加低音冲击；高音区方波 + 低保真回声。
        case .result:
            // 识别完成：A5 → A6 八度“叮叮”，50% 空心方波，带两次颗粒回声。和 SEND 的踢鼓在音区、节奏、尾巴上全部相反。
            return SoundPatch(cutoff: 4_200, glow: 0.28, peakDB: -14, crushRate: 22_050, bits: 8, voices: [
                V(.pulse(0.5), at: 0, length: 0.030, from: Note.a5, decay: 0.025),
                V(.pulse(0.5), at: 0.045, length: 0.060, from: Note.a6, decay: 0.040)
            ])
        case .polishReady:
            // 润色完成：芯片和弦琶音（E 大三和弦 0/4/7/12 半音，每 1/60 s 轮换）120 ms，再落 E6。
            return SoundPatch(cutoff: 4_200, glow: 0.22, peakDB: -12, crushRate: 22_050, bits: 8, voices: [
                V(.pulse(0.25), at: 0, length: 0.120, from: Note.e5, decay: 0.150,
                  step: 1.0 / 60, arp: [0, 4, 7, 12]),
                V(.pulse(0.5), at: 0.125, length: 0.070, from: Note.e6, decay: 0.040)
            ])
        case .copy:
            return SoundPatch(cutoff: 6_000, glow: 0, peakDB: -18, crushRate: 22_050, bits: 8, voices: [
                V(.triangle, at: 0, length: 0.015, from: Note.c7, decay: 0.008),
                V(.triangle, at: 0.040, length: 0.015, from: Note.c7, decay: 0.008)
            ])
        // LINK：4-bit 三角 + 12.5% 细脉冲，中音区，柔和、不加低音冲击。
        case .connected:
            return SoundPatch(cutoff: 4_000, glow: 0.18, peakDB: -13, crushRate: 16_000, bits: 8, voices: [
                V(.triangle, at: 0, length: 0.050, from: Note.a4, decay: 0.045),
                V(.pulse(0.125), at: 0, length: 0.050, from: Note.a4, gain: 0.35, decay: 0.045),
                V(.triangle, at: 0.055, length: 0.080, from: Note.e5, decay: 0.050),
                V(.pulse(0.125), at: 0.055, length: 0.080, from: Note.e5, gain: 0.35, decay: 0.050)
            ])
        case .connectionLost:
            return SoundPatch(cutoff: 4_000, glow: 0.12, peakDB: -14, crushRate: 16_000, bits: 8, voices: [
                V(.triangle, at: 0, length: 0.050, from: Note.e5, decay: 0.045),
                V(.pulse(0.125), at: 0, length: 0.050, from: Note.e5, gain: 0.35, decay: 0.045),
                V(.triangle, at: 0.055, length: 0.100, from: Note.a4, decay: 0.060),
                V(.pulse(0.125), at: 0.055, length: 0.100, from: Note.a4, gain: 0.35, decay: 0.060)
            ])
        case .pairingRequired:
            // 光标闪烁：三下同音短点。
            return SoundPatch(cutoff: 5_000, glow: 0, peakDB: -15, crushRate: 16_000, bits: 8, voices: [0.0, 0.060, 0.120].map {
                V(.triangle, at: $0, length: 0.020, from: Note.e6, decay: 0.015)
            })
        case .pairingSuccess:
            // 握手：A5/E6 每 28 ms 交替的颤音琶音，再落 A6。
            return SoundPatch(cutoff: 5_000, glow: 0.20, peakDB: -13, crushRate: 16_000, bits: 8, voices: [
                V(.triangle, at: 0, length: 0.112, from: Note.a5, decay: 0.200, step: 0.028, arp: [0, 7]),
                V(.triangle, at: 0.115, length: 0.090, from: Note.a6, decay: 0.060)
            ])
        // ALERT：低音区方波 + 高八度，更粗的 11 kHz / 6-bit 颗粒；小二度=否定。不加踢鼓。
        case .pairingFailed:
            return SoundPatch(cutoff: 2_400, glow: 0, peakDB: -12, crushRate: 11_025, bits: 6, voices: [
                V(.pulse(0.5), at: 0, length: 0.050, from: Note.f4, decay: 0.040),
                V(.pulse(0.5), at: 0, length: 0.050, from: Note.f4 * 2, gain: 0.4, decay: 0.040),
                V(.pulse(0.5), at: 0.060, length: 0.070, from: Note.e4, decay: 0.050),
                V(.pulse(0.5), at: 0.060, length: 0.070, from: Note.e4 * 2, gain: 0.4, decay: 0.050)
            ])
        case .warning:
            // 三下急促 D4“嘟嘟嘟”：与 SEND 的单下、SHORT 的两下、ERROR 的不协和双音按次数区分。
            return SoundPatch(cutoff: 2_400, glow: 0, peakDB: -13, crushRate: 11_025, bits: 6, voices: [0.0, 0.030, 0.060].flatMap { at in [
                V(.pulse(0.5), at: at, length: 0.020, from: Note.d4, decay: 0.018),
                V(.pulse(0.5), at: at, length: 0.020, from: Note.d4 * 2, gain: 0.5, decay: 0.018)
            ] })
        case .error:
            let hits: [(Double, Double)] = [(0, 0.070), (0.090, 0.090)]
            return SoundPatch(cutoff: 2_200, glow: 0, peakDB: -11, crushRate: 11_025, bits: 6, voices: hits.flatMap { at, length in
                [Note.bb3, Note.b3].flatMap { pitch in [
                    V(.pulse(0.5), at: at, length: length, from: pitch, decay: 0.055),
                    V(.pulse(0.5), at: at, length: length, from: pitch * 2, gain: 0.4, decay: 0.055)
                ] }
            })
        }
    }
}

// MARK: - Synth

/// 一个芯片声道上的一个音符。
struct SoundVoice {
    /// pulse = 方波/脉冲（占空比）；triangle = 4-bit 阶梯三角；noise = 15-bit LFSR 噪声，
    /// `from`/`to` 为噪声时钟（Hz，0 = 每个采样都更新）。
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
    /// 音高/琶音的更新间隔：滑音按此节拍阶梯推进（芯片按帧改寄存器），并量化到半音。
    var step: Double
    /// 琶音半音偏移，每个 step 轮换一次（空 = 不琶音）。
    var arp: [Double]

    init(_ wave: Wave, at: Double, length: Double, from: Double, to: Double? = nil,
         glide: Double = 0.02, gain: Double = 1, attack: Double = 0.0008, decay: Double,
         step: Double = 1.0 / 120, arp: [Double] = []) {
        self.wave = wave
        self.at = at
        self.length = length
        self.from = from
        self.to = to
        self.glide = glide
        self.gain = gain
        self.attack = attack
        self.decay = decay
        self.step = step
        self.arp = arp
    }
}

struct SoundPatch {
    var cutoff: Double
    var glow: Double
    var peakDB: Double
    /// lo-fi：采样保持降到此采样率，再量化到 `bits` 位。
    var crushRate: Double = 16_000
    var bits: Int = 8
    var voices: [SoundVoice]

    var duration: Double {
        (voices.map { $0.at + $0.length }.max() ?? 0) + (glow > 0 ? SoundSynth.glowTail : 0) + SoundSynth.tail
    }
}

enum SoundSynth {
    /// 改动任何参数时递增，避免沿用旧缓存文件名。
    static let renderVersion = 9
    static let sampleRate = 44_100.0
    static let glowDelay = 0.036
    static let glowTail = 0.080
    /// 滤波器余振的收尾空间；末 3 ms 线性淡出，保证首尾样本为 0、不爆音。
    static let tail = 0.008

    /// 芯片式合成：
    /// 1. 声道：PolyBLEP 脉冲 / 4-bit 阶梯三角 / LFSR 噪声；音高按 step 节拍阶梯推进并量化到半音，可做琶音。
    /// 2. 音量包络：0.8 ms 硬起音 + 指数衰减，量化成 16 级（4-bit 音量寄存器的台阶感）。
    /// 3. 低保真回声（36/72 ms 两次）→ 采样保持降采样 + 位深量化（颗粒感）。
    /// 4. 两级一阶低通压掉降采样的混叠镜像，30 Hz 高通只去直流（保留踢鼓低频给耳机）→ 峰值归一化到 peakDB。
    static func render(_ patch: SoundPatch) -> [Float] {
        let count = Int((patch.duration * sampleRate).rounded(.up))
        var buffer = [Double](repeating: 0, count: count)
        for voice in patch.voices {
            let first = Int(voice.at * sampleRate)
            let frames = Int(voice.length * sampleRate)
            var phase = 0.0
            var lfsr: UInt16 = 1
            var noiseValue = 1.0
            for frame in 0..<frames where first + frame < count {
                let t = Double(frame) / sampleRate
                let tick = (t / voice.step).rounded(.down)
                let clock = tick * voice.step
                var frequency = voice.from
                if let target = voice.to {
                    frequency = target + (voice.from - target) * exp(-clock / voice.glide)
                }
                if !voice.arp.isEmpty {
                    frequency *= pow(2, voice.arp[Int(tick) % voice.arp.count] / 12)
                }
                let value: Double
                switch voice.wave {
                case .pulse(let duty):
                    let step = semitone(frequency) / sampleRate
                    var naive = phase < duty ? 1.0 : -1.0
                    naive += polyBLEP(phase, step)
                    naive -= polyBLEP((phase - duty + 1).truncatingRemainder(dividingBy: 1), step)
                    // 去掉非 50% 占空比的直流分量：低频只留给踢鼓，提示音不会多出“噗”声。
                    value = naive - (2 * duty - 1)
                    phase += step
                case .triangle:
                    let step = semitone(frequency) / sampleRate
                    let smooth = 1 - 4 * abs(phase - 0.5)
                    value = ((smooth * 7.5).rounded() / 7.5)
                    phase += step
                case .noise:
                    let rate = frequency > 0 ? frequency : sampleRate
                    phase += rate / sampleRate
                    if phase >= 1 || frame == 0 {
                        let bit = (lfsr ^ (lfsr >> 1)) & 1
                        lfsr = (lfsr >> 1) | (bit << 14)
                        noiseValue = lfsr & 1 == 0 ? 1 : -1
                    }
                    value = noiseValue
                }
                if phase >= 1 { phase -= phase.rounded(.down) }
                let attack = min(1, t / voice.attack)
                let release = min(1, (voice.length - t) / 0.003)
                let level = (exp(-t / voice.decay) * 15).rounded(.up) / 15
                buffer[first + frame] += value * voice.gain * attack * release * level
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
        // 降采样 + 位深量化，在归一化后的满幅信号上做，保证各音颗粒度一致。
        let rawPeak = buffer.reduce(0) { max($0, abs($1)) }
        if rawPeak > 0 {
            let hold = max(1, Int((sampleRate / patch.crushRate).rounded()))
            let levels = Double(1 << (patch.bits - 1))
            var held = 0.0
            for index in 0..<count {
                if index % hold == 0 { held = ((buffer[index] / rawPeak) * levels).rounded() / levels }
                buffer[index] = held
            }
        }
        let lowA = 1 - exp(-2 * Double.pi * patch.cutoff / sampleRate)
        let highRC = 1 / (2 * Double.pi * 30)
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

    /// 量化到最近的十二平均律半音（A4 = 440 Hz）。
    private static func semitone(_ frequency: Double) -> Double {
        guard frequency > 0 else { return 0 }
        return 440 * pow(2, (12 * log2(frequency / 440)).rounded() / 12)
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
