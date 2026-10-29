import Accelerate
import Combine
import Foundation
import QuartzCore

/// Display-only gain for mono, signed PCM16. Recording bytes are never modified.
/// The anchors keep quiet speech legible without making loud speech a solid block.
enum VoiceVisualLevel {

    static func level(rmsDB: Double) -> CGFloat {
        guard rmsDB.isFinite, rmsDB > -60 else { return 0 }
        switch rmsDB {
        case ..<(-54): return CGFloat((rmsDB + 60) / 6 * 0.08)
        case ..<(-48): return CGFloat(0.08 + (rmsDB + 54) / 6 * 0.14)
        case ..<(-24): return CGFloat(0.22 + (rmsDB + 48) / 24 * 0.52)
        case ..<(-12): return CGFloat(0.74 + (rmsDB + 24) / 12 * 0.16)
        default: return CGFloat(min(0.98, 0.90 + (rmsDB + 12) / 12 * 0.08))
        }
    }
}

/// 512 点 DFT：重叠的 32ms PCM 窗映射为 70Hz–7kHz 的当前频谱，不滚动历史。
/// 窗增益、对数分频和三角权重只在初始化/频段数变化时计算。
final class SpectrumAnalyzer {
    private let size = 512
    private let sampleRate: Float = 16_000
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var windowSums: [Float]
    private struct BinWeight {
        let bin: Int
        let weight: Float
    }
    private struct BandFilter {
        let weights: [BinWeight]
        let weightSum: Float
        let tiltDB: Float
    }
    private var filters: [BandFilter] = []
    private var bandDB: [Float] = []
    private var real: [Float]
    private var imaginary: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var binPowers: [Float]

    init() {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(512), .FORWARD) else {
            fatalError("Unable to create DFT setup")
        }
        self.setup = setup
        window = [Float](repeating: 0, count: 512)
        vDSP_hann_window(&window, vDSP_Length(512), Int32(vDSP_HANN_NORM))
        windowSums = [Float](repeating: 0, count: 513)
        for index in 0..<512 {
            windowSums[index + 1] = windowSums[index] + window[index]
        }
        real = [Float](repeating: 0, count: 512)
        imaginary = [Float](repeating: 0, count: 512)
        outReal = [Float](repeating: 0, count: 512)
        outImag = [Float](repeating: 0, count: 512)
        binPowers = [Float](repeating: 0, count: 256)
        prepareFilters(count: 44)
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    /// RMS 仍是未加窗原始 dBFS；bands 是受绝对有声门限约束的相对谱形。
    /// 调用方可直接用低幅合成 PCM 验证峰的位置；不依赖音量/显示时钟。
    func analyze(_ pcm: Data, count: Int = 44) -> (bands: [CGFloat], level: CGFloat, rmsDB: Double) {
        for index in 0..<size {
            real[index] = 0
            imaginary[index] = 0
        }
        let sampleCount = min(size, pcm.count / 2)
        guard sampleCount > 0, count > 0 else { return ([], 0, -.infinity) }

        var squares = 0.0
        if filters.count != count { prepareFilters(count: count) }
        pcm.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                let sample = Float(raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) / 32768
                real[index] = sample * window[index]
                squares += Double(sample * sample)
            }
        }
        let rmsDB = squares > 0 ? 10 * log10(squares / Double(sampleCount)) : -.infinity
        let visualLevel = VoiceVisualLevel.level(rmsDB: rmsDB)
        // 相对归一化只在确有声音时生效；低于 -60dBFS 全零，
        // -60…-48dBFS 渐入，不能把底噪归一成满幅频峰。
        let gate = Float(min(1, max(0, (rmsDB + 60) / 12)))
        guard gate > 0 else { return ([CGFloat](repeating: 0, count: count), visualLevel, rmsDB) }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                outReal.withUnsafeMutableBufferPointer { outRealPointer in
                    outImag.withUnsafeMutableBufferPointer { outImagPointer in
                        guard let realBase = realPointer.baseAddress,
                              let imagBase = imaginaryPointer.baseAddress,
                              let outRealBase = outRealPointer.baseAddress,
                              let outImagBase = outImagPointer.baseAddress else { return }
                        vDSP_DFT_Execute(setup, realBase, imagBase, outRealBase, outImagBase)
                    }
                }
            }
        }

        let coherentGain = 2 / max(1, windowSums[sampleCount])
        for bin in 1..<(size / 2) {
            binPowers[bin] = outReal[bin] * outReal[bin] + outImag[bin] * outImag[bin]
        }
        var strongestDB: Float = -160
        for band in filters.indices {
            let filter = filters[band]
            var weightedPower: Float = 0
            var peakPower: Float = 0
            for item in filter.weights {
                let power = binPowers[item.bin] * item.weight
                weightedPower += power
                peakPower = max(peakPower, power)
            }
            // 峰值保留窄带共振；少量均方能量保留宽频声，避免高频宽带天然占优。
            let power = (0.75 * peakPower + 0.25 * weightedPower / filter.weightSum)
                * coherentGain * coherentGain
            let db = 10 * log10f(max(1e-16, power)) + filter.tiltDB
            bandDB[band] = db
            strongestDB = max(strongestDB, db)
        }

        // 每帧保留最强峰以下 34dB 的谱形，而不是把 60dB 绝对范围挤在一起。
        // 绝对可听度再约束峰值：即使频谱有相对峰，也不能把极弱噪声拉满。
        let floorDB = max(-84, strongestDB - 34)
        let spanDB = max(1, strongestDB - floorDB)
        let audibility = min(1, max(0, (strongestDB + 78) / 30))
        var result = [CGFloat](repeating: 0, count: count)
        for band in filters.indices {
            let relative = min(1, max(0, (bandDB[band] - floorDB) / spanDB))
            let shape = relative * relative * (3 - 2 * relative)
            result[band] = CGFloat(shape * gate * audibility)
        }
        return (result, visualLevel, rmsDB)
    }

    private func prepareFilters(count: Int) {
        let binWidth = sampleRate / Float(size)
        let lastBin = size / 2 - 1
        filters = (0..<count).map { band in
            let center = 70 * powf(100, (Float(band) + 0.5) / Float(count))
            let low = min(center - binWidth, 70 * powf(100, (Float(band) - 0.5) / Float(count)))
            let high = max(center + binWidth, 70 * powf(100, (Float(band) + 1.5) / Float(count)))
            let first = max(1, Int(ceil(low / binWidth)))
            let last = min(lastBin, Int(floor(high / binWidth)))
            var weights: [BinWeight] = []
            var weightSum: Float = 0
            for bin in first...max(first, last) {
                let frequency = Float(bin) * binWidth
                let width = frequency <= center ? center - low : high - center
                let weight = max(0, 1 - abs(frequency - center) / width)
                if weight > 0 {
                    weights.append(BinWeight(bin: bin, weight: weight))
                    weightSum += weight
                }
            }
            return BandFilter(weights: weights, weightSum: max(0.0001, weightSum),
                              tiltDB: 3 * Float(band) / Float(max(1, count - 1)))
        }
        bandDB = [Float](repeating: -160, count: count)
    }
}

/// 仅改变展示排布：相邻频段按均方能量合组，低频居中，向两侧对称展开。
/// 不增强高频底噪，不改 FFT 原始顺序、缓存或录音 PCM。
enum SpectrumPresentation {
    static func balancedBands(_ values: [CGFloat], count: Int) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: count)
        guard count > 0 else { return result }
        func band(_ index: Int) -> CGFloat {
            index < values.count ? min(1, max(0, values[index])) : 0
        }
        let half = count / 2
        let center = count % 2
        if center == 1 { result[half] = band(0) }
        for pair in 0..<half {
            let first = band(center + pair * 2)
            let second = band(center + pair * 2 + 1)
            let energy = sqrt((first * first + second * second) / 2)
            result[half - 1 - pair] = energy
            result[half + center + pair] = energy
        }
        return result
    }
}

/// 连续速度的临界阻尼包络；起音约 120ms 到九成，回落约 280ms。
/// 解析更新不依赖帧率，也不需要降低真实音频采集频率。
struct SpectrumResponse {
    private let time: CGFloat
    private let attackDecay: CGFloat
    private let releaseDecay: CGFloat

    init(dt: Double) {
        time = CGFloat(max(0, dt))
        attackDecay = exp(-32 * time)
        releaseDecay = exp(-14 * time)
    }

    func advance(value: CGFloat, velocity: CGFloat, target: CGFloat) -> (value: CGFloat, velocity: CGFloat) {
        guard time > 0 else { return (value, velocity) }
        let rising = target > value
        let omega: CGFloat = rising ? 32 : 14
        let offset = value - target
        let b = velocity + omega * offset
        let decay = rising ? attackDecay : releaseDecay
        let next = target + (offset + b * time) * decay
        let nextVelocity = (velocity - omega * b * time) * decay
        if next < 0 { return (0, 0) }
        if next > 1 { return (1, 0) }
        return (next, nextVelocity)
    }
}

struct SpectrumFrame {
    var bands: [CGFloat]
    var breath: CGFloat
    var time: Double
    /// 快速响度包络（0…1），仅用于少量 presence 与亮度，不统一放大圆环。
    var level: CGFloat
    /// 带保持时间的峰值包络（0…1），用于外层余辉。
    var peak: CGFloat
    /// Only decorative motion fades; live audio, spring physics and text keep real time.
    var ambientIntensity: CGFloat = 1
}

/// No separate timer: the shared display clock evaluates a forty-second hold,
/// then a four-second smooth fade. A fresh interaction ramps the decoration back in.
struct AmbientMotionEnvelope {
    static let holdDuration: Double = 40
    static let fadeDuration: Double = 4
    private(set) var lastActivity: Double = 0
    private(set) var intensity: CGFloat = 1

    mutating func noteActivity(at time: Double) { lastActivity = time }

    func target(at time: Double) -> CGFloat {
        let progress = min(1, max(0, (time - lastActivity - Self.holdDuration) / Self.fadeDuration))
        return CGFloat(1 - progress * progress * (3 - 2 * progress))
    }

    mutating func advance(at time: Double, dt: Double) -> CGFloat {
        let next = target(at: time)
        if next > intensity {
            intensity += (next - intensity) * CGFloat(1 - exp(-max(0, dt) / 0.18))
            if intensity > 0.999 { intensity = 1 }
        } else { intensity = next }
        return intensity
    }
}

/// 一维平滑值噪声，供呼吸纹理和全局呼吸共用。
enum BreathingNoise {
    static func value(_ x: Double) -> Double {
        let base = floor(x)
        let fraction = x - base
        let index = Int(base)
        let smooth = fraction * fraction * fraction * (fraction * (fraction * 6 - 15) + 10)
        let first = hash(index)
        let second = hash(index + 1)
        return first + (second - first) * smooth
    }

    private static func hash(_ index: Int) -> Double {
        var value = UInt64(bitPattern: Int64(index))
        value ^= value >> 33
        value &*= 0xff51afd7ed558ccd
        value ^= value >> 33
        value &*= 0xc4ceb9fe1a85ec53
        value ^= value >> 33
        return Double(value & 0xFFFF_FFFF) / Double(UInt32.max) * 2 - 1
    }
}

/// 文字到达留下的局部光能；独立于音频 bands，不向 Home 发布逐帧状态。
@MainActor
final class WaveformInkStore {
    nonisolated static let impactSlotsPerRing = 3
    nonisolated static let impactLifetime: CGFloat = 0.16

    struct Impact {
        var angle: CGFloat = 0
        var age: CGFloat = WaveformInkStore.impactLifetime
        var amplitude: CGFloat = 0
        var unit = CGVector(dx: 1, dy: 0)

        var intensity: CGFloat {
            let remaining = max(0, 1 - age / WaveformInkStore.impactLifetime)
            return amplitude * remaining * remaining
        }

        var halfWidth: CGFloat { 0.14 + 0.24 * min(1, age / WaveformInkStore.impactLifetime) }
    }

    /// Exact, persistent landing geometry. Unit coordinates are prepared only on ingestion.
    /// A quadratic short arc follows the same transformed ellipse as its attached glyph.
    struct Contact {
        let angle: CGFloat
        let start: CGPoint
        let control: CGPoint
        let end: CGPoint
        /// Landing time, so the arc can grow out of the collapsing glyph.
        let born: Double
        /// Ambient clock at landing; flowing arcs advance from here and rest with that clock.
        let phase: Double

        init(angle: CGFloat, born: Double = CACurrentMediaTime(), phase: Double = 0) {
            self.born = born
            self.phase = phase
            let turn = 2 * CGFloat.pi
            let normalizedAngle = (angle.truncatingRemainder(dividingBy: turn) + turn)
                .truncatingRemainder(dividingBy: turn)
            self.angle = normalizedAngle
            let halfWidth: CGFloat = 0.16
            start = CGPoint(x: cos(normalizedAngle - halfWidth), y: sin(normalizedAngle - halfWidth))
            end = CGPoint(x: cos(normalizedAngle + halfWidth), y: sin(normalizedAngle + halfWidth))
            let controlRadius = 2 - cos(halfWidth)
            control = CGPoint(x: cos(normalizedAngle) * controlRadius, y: sin(normalizedAngle) * controlRadius)
        }
    }

    private struct Slot {
        var charge: CGFloat = 0
        var value: CGFloat = 0
        var arrivalTarget: CGFloat = 0
        var arrival: CGFloat = 0
        var releasePeak: CGFloat = 0
    }

    private var slots = [Slot](repeating: Slot(), count: TorusGeometry.ringCount)
    private var nextCharge = [CGFloat](repeating: 0, count: TorusGeometry.ringCount)
    private var nextArrival = [CGFloat](repeating: 0, count: TorusGeometry.ringCount)
    private var impacts = [Impact](repeating: Impact(),
                                  count: TorusGeometry.ringCount * impactSlotsPerRing)
    private var contacts = [[Contact]](repeating: [], count: TorusGeometry.ringCount)
    private var chargePhase: Double = 0
    private var smoothedTension: CGFloat = 0
    private(set) var chargeTension: CGFloat = 0
    private(set) var chargeGlow: CGFloat = 0
    private var releasing = false
    var reduceMotion = false
    private(set) var releaseFlash: CGFloat = 0
    /// 发射冲击波：从拉弦点沿线圈向两端传播的一次亮带，只依赖时间，不改几何。
    private var waveAge: CGFloat = .infinity
    private var waveOrigin: CGFloat = 0
    private var waveStrength: CGFloat = 0
    nonisolated static let waveLifetime: CGFloat = 0.34
    var releaseWaveActive: Bool { waveAge < Self.waveLifetime }
    var onActivity: (() -> Void)?

    func deposit(at ring: Int, angle: CGFloat, weight: CGFloat, phase: Double = 0) {
        guard slots.indices.contains(ring), angle.isFinite, weight.isFinite, weight > 0 else { return }
        onActivity?()
        let weight = min(1, weight)
        releasing = false
        // 饱和叠加：再长的文字也只趋近上限，不积出无限亮度。
        slots[ring].charge += (1 - slots[ring].charge) * weight * 0.24
        contacts[ring].append(Contact(angle: angle, phase: phase))
        if !reduceMotion {
            slots[ring].arrivalTarget += (1 - slots[ring].arrivalTarget) * weight * 0.92
            let first = ring * Self.impactSlotsPerRing
            var weakest = first
            for index in first..<(first + Self.impactSlotsPerRing) {
                if impacts[index].intensity < impacts[weakest].intensity { weakest = index }
            }
            impacts[weakest] = Impact(angle: angle.truncatingRemainder(dividingBy: 2 * .pi),
                                     age: 0, amplitude: 0.55 + 0.45 * weight,
                                     unit: CGVector(dx: cos(angle), dy: sin(angle)))
        }
    }

    func release(strength: CGFloat, anchor: CGFloat = 0.5) {
        onActivity?()
        let strength = min(1, max(0, strength))
        releasing = true
        if !reduceMotion {
            waveAge = 0
            waveOrigin = min(1, max(0, anchor.isFinite ? anchor : 0.5)) * CGFloat(slots.count - 1)
            waveStrength = 0.45 + 0.4 * strength
        }
        releaseFlash = 0
        clearCharge()
        for index in contacts.indices { contacts[index].removeAll(keepingCapacity: true) }
        for index in impacts.indices { impacts[index].amplitude = 0 }
        for index in slots.indices {
            let local = max(slots[index].value, slots[index].charge)
            let peak = reduceMotion ? 0 : local * (0.38 + 0.62 * strength)
            slots[index].releasePeak = peak
            slots[index].charge = 0
            slots[index].arrivalTarget = 0
            releaseFlash = max(releaseFlash, peak)
        }
    }

    func reset() {
        for index in slots.indices {
            slots[index] = Slot()
            nextCharge[index] = 0
            nextArrival[index] = 0
        }
        clearCharge()
        for index in contacts.indices { contacts[index].removeAll(keepingCapacity: true) }
        releasing = false
        releaseFlash = 0
        waveAge = .infinity
        for index in impacts.indices { impacts[index] = Impact() }
    }

    /// Only a live downward touch charges the load; spring overshoot cannot relight it.
    /// Stop immediately on release/cancel, but retain landing positions until the load fires.
    func updateCharge(tension: CGFloat, dt: Double) {
        let tension = tension.isFinite ? min(1, max(0, tension)) : 0
        guard tension > 0 else {
            clearCharge()
            return
        }
        chargeTension = tension
        if reduceMotion {
            smoothedTension = tension
            chargePhase = 0
            chargeGlow = tension
            return
        }
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        smoothedTension += (tension - smoothedTension) * CGFloat(1 - exp(-step / 0.045))
        let frequency = 0.65 + Double(smoothedTension) * 0.70
        chargePhase = (chargePhase + step * 2 * .pi * frequency).truncatingRemainder(dividingBy: 2 * .pi)
        let depth = 0.06 + 0.08 * smoothedTension
        // Increasing pressure quickens the pulse, never beyond 1.35 Hz or into a strobe.
        chargeGlow = smoothedTension * (1 - depth + depth * CGFloat(cos(chargePhase)))
    }

    private func clearCharge() {
        chargeTension = 0
        chargeGlow = 0
        smoothedTension = 0
        chargePhase = 0
    }

    func contactCount(at ring: Int) -> Int {
        guard contacts.indices.contains(ring) else { return 0 }
        return contacts[ring].count
    }

    func contact(at ring: Int, slot: Int) -> Contact? {
        guard contacts.indices.contains(ring), contacts[ring].indices.contains(slot) else { return nil }
        return contacts[ring][slot]
    }

    func tick(dt: Double) {
        guard dt.isFinite, dt > 0 else { return }
        let impactStep = CGFloat(min(Double(Self.impactLifetime), dt))
        for index in impacts.indices {
            impacts[index].age = min(Self.impactLifetime, impacts[index].age + impactStep)
            if reduceMotion { impacts[index].amplitude = 0 }
        }
        if waveAge < Self.waveLifetime { waveAge = reduceMotion ? .infinity : waveAge + CGFloat(min(0.05, dt)) }
        let dt = CGFloat(min(0.05, dt))
        let chargeSpread = min(0.20, dt * 0.7)
        let arrivalSpread = min(0.24, dt * 5)
        let chargeDecay: CGFloat = releasing ? exp(-dt / 0.13) : 1
        let arrivalDecay = exp(-dt / 0.11)
        let valueEase = 1 - exp(-dt / (releasing ? 0.065 : 0.09))
        let arrivalEase = 1 - exp(-dt / 0.025)
        let peakDecay = exp(-dt / 0.075)

        // 双缓冲只在初始化分配；相邻槽缓慢传光，不改变圆环几何或音频。
        for index in slots.indices {
            let slot = slots[index]
            let left = index > 0 ? slots[index - 1] : slot
            let right = index + 1 < slots.count ? slots[index + 1] : slot
            nextCharge[index] = (slot.charge
                + (left.charge + right.charge - 2 * slot.charge) * chargeSpread) * chargeDecay
            nextArrival[index] = reduceMotion ? 0 : (slot.arrivalTarget
                + (left.arrivalTarget + right.arrivalTarget - 2 * slot.arrivalTarget) * arrivalSpread)
                * arrivalDecay
        }
        releaseFlash = 0
        for index in slots.indices {
            slots[index].charge = nextCharge[index]
            slots[index].arrivalTarget = nextArrival[index]
            slots[index].value += (nextCharge[index] - slots[index].value) * valueEase
            slots[index].arrival += (nextArrival[index] - slots[index].arrival) * arrivalEase
            slots[index].releasePeak = reduceMotion ? 0 : slots[index].releasePeak * peakDecay
            releaseFlash = max(releaseFlash, slots[index].releasePeak)
            if reduceMotion { slots[index].arrival = 0 }
        }
    }

    /// Stored text energy of one ring: saturating, slowly shared with its neighbors, kept
    /// until release. The ring-charge attach style draws the load from this alone.
    func load(at ring: Int) -> CGFloat {
        guard slots.indices.contains(ring) else { return 0 }
        return slots[ring].value
    }

    func intensity(at ring: Int) -> CGFloat {
        guard slots.indices.contains(ring) else { return 0 }
        let slot = slots[ring]
        // Arrival pulses only faintly: a whole ring jumping on every landing reads as flicker.
        return min(1, slot.value * 0.78 + slot.arrival * 0.06 + slot.releasePeak * 0.70 + releaseWave(at: ring) * 0.85)
    }

    /// 释放余光与文字到达脉冲独立，避免把任意落点错误地画到圆环顶部。
    func accent(at ring: Int) -> CGFloat {
        guard !reduceMotion, slots.indices.contains(ring) else { return 0 }
        return min(1, max(slots[ring].releasePeak, releaseWave(at: ring)))
    }

    /// 前沿先快后慢（约 0.2s 扫过整条线圈），亮带随传播变宽、变暗。
    func releaseWave(at ring: Int) -> CGFloat {
        guard waveAge < Self.waveLifetime else { return 0 }
        let progress = waveAge / Self.waveLifetime
        let front = CGFloat(slots.count) * 1.15 * (1 - pow(1 - progress, 2.2))
        let width = 1.6 + 1.8 * progress
        let distance = abs(CGFloat(ring) - waveOrigin) - front
        let fade = pow(1 - progress, 3)
        // Ramp in as the front leaves the pull point, so the release never pins a hot spot there.
        let departure = min(1, front / 5)
        return waveStrength * fade * departure * exp(-distance * distance / (width * width))
    }

    func impact(at ring: Int, slot: Int) -> Impact? {
        guard !reduceMotion, slots.indices.contains(ring),
              slot >= 0, slot < Self.impactSlotsPerRing else { return nil }
        let impact = impacts[ring * Self.impactSlotsPerRing + slot]
        return impact.intensity > 0.01 ? impact : nil
    }
}

/// 120 Hz 显示时钟：频谱按时间常数连续插值，呼吸用一维 Perlin 噪声，
/// 只让中心 Canvas 订阅，避免整个页面跟着 120 帧重排。
@MainActor
final class SpectrumStore: ObservableObject {
    @Published private(set) var frame: SpectrumFrame
    private var target: [CGFloat]
    private var displayBands: [CGFloat]
    private var bandVelocities: [CGFloat]
    private var targetLevel: CGFloat = 0
    private var displayLevel: CGFloat = 0
    private var levelVelocity: CGFloat = 0
    private var displayPeak: CGFloat = 0
    private var peakHoldUntil: CFTimeInterval = 0
    private var noiseTime: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var lastHitchLog: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var visible = false
    private var activeUntil: CFTimeInterval = 0
    private var ambientMotion = AmbientMotionEnvelope()
    private var ambientEnabled = false
    private var ambientReduced = false
    private var highRefresh = true
    #if DEBUG
    private(set) var renderedTicks: UInt64 = 0
    var ambientIdleDuration: Double { CACurrentMediaTime() - ambientMotion.lastActivity }
    #endif
    private let proxy = DisplayLinkProxy()
    let stringMotion = StringMotionStore()
    let ink = WaveformInkStore()

    init(count: Int = 44) {
        let zeros = [CGFloat](repeating: 0, count: count)
        frame = SpectrumFrame(bands: zeros, breath: 0.5, time: 0, level: 0, peak: 0)
        target = zeros
        displayBands = zeros
        bandVelocities = zeros
        proxy.store = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        stringMotion.onActivity = { [weak self] in self?.wake() }
        ink.onActivity = { [weak self] in self?.wake() }
    }

    deinit {
        displayLink?.invalidate()
    }

    var isClockRunning: Bool { displayLink?.isPaused == false }

    func configureAmbientMotion(enabled: Bool, reducedMotion: Bool) {
        guard enabled != ambientEnabled || reducedMotion != ambientReduced else { return }
        ambientEnabled = enabled
        ambientReduced = reducedMotion
        wake()
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            wake()
        } else {
            displayLink?.isPaused = true
            lastTick = 0
        }
    }

    /// The main HUD keeps its ambient motion for forty seconds after activity.
    /// Replay and Reduce Motion keep the short finite-effect tail.
    /// Reset the timestamp after a pause, so standby time never becomes spring/flight dt.
    func wake() {
        let now = CACurrentMediaTime()
        activeUntil = now + 1.2
        ambientMotion.noteActivity(at: now)
        setHighRefresh(true)
        guard visible, displayLink?.isPaused == true else { return }
        lastTick = CACurrentMediaTime()
        displayLink?.isPaused = false
        IMicLog.write("iphone.power", "visual clock resumed")
    }

    func update(_ incoming: [CGFloat], level: CGFloat) {
        wake()
        target = displayTargets(incoming)
        targetLevel = min(1, max(0, level))
    }

    func set(_ values: [CGFloat], level: CGFloat = 0) {
        wake()
        let next = displayTargets(values)
        let clamped = min(1, max(0, level))
        target = next
        displayBands = next
        bandVelocities = [CGFloat](repeating: 0, count: next.count)
        levelVelocity = 0
        targetLevel = clamped
        displayLevel = clamped
        displayPeak = clamped
        peakHoldUntil = CACurrentMediaTime() + 0.25
        frame = SpectrumFrame(
            bands: next,
            breath: frame.breath,
            time: frame.time,
            level: clamped,
            peak: clamped,
            ambientIntensity: frame.ambientIntensity
        )
    }

    func reset() {
        wake()
        let zeros = [CGFloat](repeating: 0, count: target.count)
        target = zeros
        displayBands = zeros
        bandVelocities = zeros
        levelVelocity = 0
        targetLevel = 0
        displayLevel = 0
        displayPeak = 0
        peakHoldUntil = 0
        frame = SpectrumFrame(
            bands: zeros,
            breath: frame.breath,
            time: frame.time,
            level: 0,
            peak: 0,
            ambientIntensity: frame.ambientIntensity
        )
    }

    fileprivate func tick() {
        #if DEBUG
        renderedTicks &+= 1
        #endif
        let now = CACurrentMediaTime()
        let elapsed = lastTick == 0 ? 1.0 / 60.0 : max(0, now - lastTick)
        let dt = min(0.05, elapsed)
        // Main-thread stalls freeze the coil and then jump it; log them, at most once a second.
        if elapsed > 0.05, now - lastHitchLog > 1 {
            lastHitchLog = now
            IMicLog.write("iphone.visual", String(format: "frame hitch %.0fms", elapsed * 1000))
        }
        lastTick = now
        let ambient = ambientEnabled && !ambientReduced
            ? ambientMotion.advance(at: now, dt: dt) : 0
        // Slowing the decorative phase to zero prevents a frozen-frame jump.
        // Physical springs/flight continue to receive unmodified elapsed time below.
        noiseTime += dt * Double(ambientEnabled ? ambient : 1)

        // 两段低频平滑噪声叠加，输出完整的 0…1，呼吸幅度不再被压扁。
        let value = 0.7 * BreathingNoise.value(noiseTime * 0.13)
            + 0.3 * BreathingNoise.value(noiseTime * 0.37 + 9.1)
        let breath = CGFloat(min(1, max(0, 0.5 + 0.5 * value)))

        let easing = SpectrumResponse(dt: dt)
        var next = displayBands
        for index in 0..<min(next.count, target.count) {
            let response = easing.advance(
                value: next[index], velocity: bandVelocities[index], target: target[index])
            next[index] = response.value
            bandVelocities[index] = response.velocity
        }
        displayBands = next

        // 亮度与频段同样保留惯性，但不会统一撑大所有圆环。
        let levelResponse = easing.advance(
            value: displayLevel, velocity: levelVelocity, target: targetLevel)
        displayLevel = levelResponse.value
        levelVelocity = levelResponse.velocity
        if targetLevel >= displayPeak {
            displayPeak = targetLevel
            peakHoldUntil = now + 0.08
        } else if now >= peakHoldUntil {
            let peakEase = CGFloat(1 - exp(-dt / 0.16))
            displayPeak += (displayLevel - displayPeak) * peakEase
        }
        if displayLevel < 0.001 && targetLevel < 0.001 {
            displayLevel = 0
        }
        if displayPeak < 0.001 && displayLevel < 0.001 {
            displayPeak = 0
        }

        frame = SpectrumFrame(
            bands: next,
            breath: breath,
            time: noiseTime,
            level: displayLevel,
            peak: displayPeak,
            ambientIntensity: ambient
        )
        ink.reduceMotion = stringMotion.reduceMotion
        ink.updateCharge(tension: stringMotion.chargeTension, dt: elapsed)
        ink.tick(dt: elapsed)
        // 渲染器在弦 tick 的 defer 中读取几何，此时必须已拿到当前声帧。
        stringMotion.tick(now: now, dt: elapsed)
        let effectActive = stringMotion.needsAnimation
            || stringMotion.renderer?.needsStringMotionFrames == true
        if effectActive {
            ambientMotion.noteActivity(at: now)
        }
        setHighRefresh(now < activeUntil || effectActive)
        if now >= activeUntil, ambient == 0, !stringMotion.needsAnimation,
           stringMotion.renderer?.needsStringMotionFrames != true {
            displayLink?.isPaused = true
            lastTick = 0
            IMicLog.write("iphone.power", "visual clock paused")
        }
    }

    private func displayTargets(_ values: [CGFloat]) -> [CGFloat] {
        SpectrumPresentation.balancedBands(values, count: target.count)
    }

    private func setHighRefresh(_ active: Bool) {
        guard highRefresh != active else { return }
        highRefresh = active
        displayLink?.preferredFrameRateRange = active
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    }

}

private final class DisplayLinkProxy {
    weak var store: SpectrumStore?

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            store?.tick()
        }
    }
}

/// Pure, frame-rate-independent string physics; velocities are in points/second.
struct StringSpring {
    private(set) var position: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private var origin: CGFloat = 0
    private static let dragGain: CGFloat = 0.72
    private static let damping: CGFloat = 7.0
    private static let frequency: CGFloat = 27.5

    static func travelLimit(height: CGFloat) -> CGFloat { max(12, height * 0.21) }
    static func threshold(height: CGFloat) -> CGFloat { travelLimit(height: height) * 0.52 }

    mutating func begin() {
        // Regrabbing even a fast overshoot must start at exactly the current position.
        origin = position
    }

    mutating func drag(translation: CGFloat, velocity: CGFloat, limit: CGFloat,
                       clearStretch: StringClearStretch? = nil) {
        let normalized = translation * Self.dragGain / limit
        let resistance = tanh(normalized)
        position = origin + limit * resistance
        self.velocity = velocity * Self.dragGain * (1 - resistance * resistance)
        if let clearStretch, translation < 0 {
            let normal = limit * resistance
            position = origin + clearStretch.pull(normal: normal, translation: translation, limit: limit, origin: origin)
            let delta: CGFloat = 0.1
            let nextNormal = limit * tanh((translation + delta) * Self.dragGain / limit)
            let next = clearStretch.pull(normal: nextNormal, translation: translation + delta, limit: limit, origin: origin)
            self.velocity = velocity * (next - (position - origin)) / delta
        }
    }

    /// First future zero with upward velocity, for a positively stretched string.
    /// The analytic deadline cannot miss a crossing after a delayed display frame.
    func upwardNeutralTime() -> Double {
        guard position > 0 else { return 0 }
        let b = (velocity + Self.damping * position) / Self.frequency
        return Double((atan2(b, position) + .pi / 2) / Self.frequency)
    }

    mutating func advance(dt: Double, reduceMotion: Bool) {
        guard dt > 0 else { return }
        let t = CGFloat(dt)
        let x = position
        let v = velocity
        if reduceMotion {
            // Critical damping: a quick return without repeated oscillations.
            let omega: CGFloat = 30
            let b = v + omega * x
            let decay = exp(-omega * t)
            position = (x + b * t) * decay
            velocity = (v - omega * b * t) * decay
        } else {
            // Exact underdamped solution, stable even after a dropped display frame.
            let damping = Self.damping
            let frequency = Self.frequency
            let decay = exp(-damping * t)
            let c = cos(frequency * t)
            let s = sin(frequency * t)
            let b = (v + damping * x) / frequency
            position = decay * (x * c + b * s)
            velocity = decay * ((-damping * x + frequency * b) * c
                + (-damping * b - frequency * x) * s)
        }
        if abs(position) < 0.08 && abs(velocity) < 0.4 { reset() }
    }

    mutating func reset() {
        position = 0
        velocity = 0
        origin = 0
    }
}

/// No timers or async work: one due delete per display tick, never a catch-up burst.
struct StringDeleteHold {
    private(set) var armedAt: Double?
    private(set) var repeating = false
    private(set) var repeatedInGesture = false
    private var nextDeleteAt: Double = 0
    private var directionReversed = false
    private var reversalTravel: CGFloat = 0
    static let directionHysteresis: CGFloat = 2.5

    mutating func update(beyondThreshold: Bool, movement: CGFloat, now: Double) {
        // Accumulate net retreat from the latest directional extreme. Subpixel
        // jitter neither restarts the dwell nor resumes deletion after a real reversal.
        if directionReversed {
            reversalTravel = min(0, reversalTravel + movement)
            if reversalTravel <= -Self.directionHysteresis {
                directionReversed = false
                reversalTravel = 0
            }
        } else {
            reversalTravel = max(0, reversalTravel + movement)
            if reversalTravel >= Self.directionHysteresis {
                directionReversed = true
                reversalTravel = 0
            }
        }
        guard beyondThreshold, !directionReversed else {
            armedAt = nil
            repeating = false
            return
        }
        if armedAt == nil {
            armedAt = now
            nextDeleteAt = now + 0.4
        }
    }

    mutating func advance(now: Double) -> Bool {
        guard let armedAt, now >= nextDeleteAt else { return false }
        repeating = true
        repeatedInGesture = true
        let acceleration = min(1, max(0, (now - armedAt - 0.4) / 1.8))
        let interval = 0.18 + (0.05 - 0.18) * acceleration
        nextDeleteAt = now + interval
        return true
    }

    mutating func reset() { self = StringDeleteHold() }
}

/// The receiver shares the string's display clock without publishing animation frames to SwiftUI.
@MainActor
protocol StringMotionRendering: AnyObject {
    var needsStringMotionFrames: Bool { get }
    func renderStringMotion(_ motion: StringMotionStore, now: Double, dt: Double)
}

/// Only TorusView observes per-frame motion. HomeView receives hint changes only.
@MainActor
final class StringMotionStore: ObservableObject {
    @Published private(set) var pull: CGFloat = 0
    @Published private(set) var anchor: CGFloat = 0.5
    @Published private(set) var armed = false
    @Published private(set) var hint: String?
    @Published private(set) var clearOpacity: Double = 1
    @Published private(set) var clearZone: Double = 0
    @Published private(set) var isClearing = false
    private var clearFeedback: StringClearFeedback?
    private var clearElapsed: Double = 0
    var onRepeatDelete: (() -> Bool)?
    var onFireReturn: (() -> Bool)?
    weak var renderer: (any StringMotionRendering)?
    var velocity: CGFloat { spring.velocity }
    var upwardTravel: CGFloat? { clearStretch?.depth }

    /// Brightness of the top clear zone. Only a finger pulling the string up
    /// previews it; a released string swinging above its baseline never does.
    func clearPreview(distance: CGFloat, enabled: Bool) -> CGFloat {
        if isClearing { return CGFloat(clearZone) }
        guard enabled, dragging, !cancelled else { return 0 }
        return min(1, max(0, -pull / max(1, distance)))
    }
    var clearLoadOpacity: Double { isClearing ? (clearElapsed < 0.22 ? clearOpacity : 0) : 1 }
    private(set) var releaseStrength: CGFloat = 0
    private(set) var pendingReturn = false
    private var returnRemaining: Double = 0
    var reduceMotion = false
    private var spring = StringSpring()
    private var deleteHold = StringDeleteHold()
    private var pullRatchet = StringPullRatchet()
    private var clearSnapPlayed = false
    private var dragging = false
    private var cancelled = false
    private var height: CGFloat = 1
    private var clearStretch: StringClearStretch?
    private var previousTranslation: CGFloat = 0
    private var returnEnabled = false
    private var deleteEnabled = false
    var onActivity: (() -> Void)?
    var needsAnimation: Bool {
        isClearing || dragging || pendingReturn || abs(spring.position) >= 0.08 || abs(spring.velocity) >= 0.4
    }

    /// Normalized live pull, independent of arming, return flight and spring rebound.
    var chargeTension: CGFloat {
        guard dragging, !cancelled, returnEnabled else { return 0 }
        return min(1, max(0, pull / StringSpring.travelLimit(height: height)))
    }

    func begin(anchor: CGFloat, height: CGFloat, clearStretch: StringClearStretch? = nil) {
        guard !isClearing else { return }
        self.clearStretch = clearStretch
        onActivity?()
        cancelPendingReturn()
        self.anchor = TorusGeometry.clampedAnchor(anchor)
        self.height = height
        spring.begin()
        deleteHold.reset()
        previousTranslation = 0
        pullRatchet = StringPullRatchet()
        dragging = true
        cancelled = false
    }

    /// A vertical grab remains a grab when the finger moves sideways; both the
    /// waveform and its attached glyphs read this live force point on the same clock.
    func moveAnchor(to anchor: CGFloat) {
        guard dragging, !cancelled, !isClearing else { return }
        let next = TorusGeometry.clampedAnchor(anchor)
        guard next != self.anchor else { return }
        onActivity?()
        self.anchor = next
    }

    func drag(translation: CGFloat, velocity: CGFloat, returnEnabled: Bool, deleteEnabled: Bool,
              now: Double = CACurrentMediaTime()) {
        guard dragging, !cancelled else { return }
        onActivity?()
        self.returnEnabled = returnEnabled
        self.deleteEnabled = deleteEnabled
        spring.drag(translation: translation, velocity: velocity,
                    limit: StringSpring.travelLimit(height: height), clearStretch: clearStretch)
        pull = spring.position
        if deleteEnabled, translation < 0, pullRatchet.advance(distance: -translation, now: now) {
            let progress = -translation / max(1, clearStretch?.distance ?? height)
            Haptics.shared.play(progress > 0.55 ? .stringNotchHigh : .stringNotchLow)
        }
        let threshold = StringSpring.threshold(height: height)
        let enabled = pull > 0 ? returnEnabled : deleteEnabled
        let nextArmed = abs(pull) >= threshold && enabled
        if nextArmed != armed {
            armed = nextArmed
            if nextArmed, pull > 0 {
                Haptics.shared.prepareBowArmed()
                Haptics.shared.play(.bowArmed)
            } else {
                Haptics.shared.play(nextArmed ? .cancelArmed : .cancelDisarmed)
            }
        }
        deleteHold.update(beyondThreshold: pull <= -threshold && deleteEnabled,
                          movement: translation - previousTranslation, now: now)
        previousTranslation = translation
        updateHint()
    }

    /// Upward release deletes immediately; downward release only arms the flight.
    func finish(translation: CGFloat, velocity: CGFloat,
                returnEnabled: Bool, deleteEnabled: Bool) -> String? {
        guard !isClearing else { return nil }
        onActivity?()
        defer {
            dragging = false
            cancelled = false
            deleteHold.reset()
            armed = false
            hint = nil
        }
        guard dragging, !cancelled else { return nil }
        spring.drag(translation: translation, velocity: velocity,
                    limit: StringSpring.travelLimit(height: height), clearStretch: clearStretch)
        pull = spring.position
        let threshold = StringSpring.threshold(height: height)
        if spring.position >= threshold && returnEnabled {
            pendingReturn = true
            releaseStrength = min(1, max(0, spring.position / StringSpring.travelLimit(height: height)))
            Haptics.shared.prepareBowArmed()
            // Reduced motion settles once in finite time, without oscillation.
            returnRemaining = reduceMotion ? min(0.10, spring.upwardNeutralTime()) : spring.upwardNeutralTime()
            return nil
        }
        if spring.position <= -threshold && deleteEnabled && !deleteHold.repeatedInGesture {
            return "delete"
        }
        return nil
    }

    func cancelPendingReturn() {
        pendingReturn = false
        returnRemaining = 0
        releaseStrength = 0
    }

    /// Cancels the current touch as well as repeat state; it cannot rearm until lift.
    func cancel(preserveClear: Bool = false) {
        if preserveClear, isClearing { return }
        onActivity?()
        clearFeedback = nil
        isClearing = false
        clearOpacity = 1
        clearZone = 0
        cancelPendingReturn()
        cancelled = true
        dragging = false
        deleteHold.reset()
        spring.reset()
        pull = 0
        armed = false
        hint = nil
    }

    func completeClearContact() {
        guard !isClearing else { return }
        onActivity?()
        cancelPendingReturn()
        dragging = false
        cancelled = false
        deleteHold.reset()
        armed = false
        hint = nil
        clearFeedback = StringClearFeedback(initialPull: pull, depth: clearStretch?.depth ?? abs(pull))
        clearElapsed = 0
        clearSnapPlayed = false
        clearOpacity = 1
        clearZone = 1
        isClearing = true
    }

    func tick(now: Double, dt: Double) {
        defer { renderer?.renderStringMotion(self, now: now, dt: dt) }
        if let feedback = clearFeedback {
            clearElapsed += max(0, dt)
            if clearElapsed >= 0.22, !clearSnapPlayed {
                clearSnapPlayed = true
                Haptics.shared.play(.stringSnap)
            }
            let frame = feedback.frame(at: clearElapsed, reducedMotion: reduceMotion)
            pull = frame.pull
            clearOpacity = frame.opacity
            clearZone = frame.zone
            if frame.finished {
                clearFeedback = nil
                spring.reset()
                isClearing = false
            }
            return
        }
        if dragging, !cancelled {
            if deleteHold.advance(now: now) {
                guard onRepeatDelete?() == true else {
                    cancel()
                    return
                }
                updateHint()
            }
        } else if !cancelled {
            if pendingReturn {
                let step = min(max(0, dt), returnRemaining)
                spring.advance(dt: step, reduceMotion: reduceMotion)
                returnRemaining -= step
                if returnRemaining <= 0 {
                    // Consume before calling out: reentrancy or later oscillations
                    // cannot duplicate the command. The visual is at neutral now.
                    let strength = releaseStrength
                    cancelPendingReturn()
                    releaseStrength = strength
                    if reduceMotion {
                        spring.reset()
                    }
                    pull = 0
                    if onFireReturn?() == true {
                        Haptics.shared.playBowRelease(strength: Float(releaseStrength))
                    } else {
                        releaseStrength = 0
                    }
                    return
                }
            } else {
                spring.advance(dt: dt, reduceMotion: reduceMotion)
            }
            if pull != spring.position { pull = spring.position }
        }
    }

    private func updateHint() {
        let next: String?
        if abs(pull) < StringSpring.threshold(height: height) {
            next = nil
        } else if pull > 0 {
            next = returnEnabled ? "松手回弹 · 过中线发射文字" : "发射已在 Mac 关闭"
        } else if !deleteEnabled {
            next = "删除已在 Mac 关闭"
        } else if deleteHold.repeating {
            next = "正在连续删除 · 下移或松手停止"
        } else if deleteHold.armedAt != nil {
            next = "松手删除一字 · 保持上拉连续删除"
        } else {
            next = "连续删除已暂停 · 继续上拉可恢复"
        }
        if hint != next { hint = next }
    }
}
