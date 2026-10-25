import AVFoundation
import UIKit

/// 缓存合成的短弓弦与气流音；飞行前准备，过中线只启动已准备的播放器。
/// 单个播放器可重用，连续手势会替换声音而不叠加。
@MainActor
final class BowReleaseSound {
    static let shared = BowReleaseSound()
    private var player: AVAudioPlayer?
    private var prepared = false

    private init() {}

    func prepare() {
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            if player == nil {
                let player = try AVAudioPlayer(data: Self.makeWave(), fileTypeHint: AVFileType.wav.rawValue)
                player.volume = 0.65
                self.player = player
            }
            guard let player else { return }
            prepared = player.prepareToPlay()
            if !prepared {
                IMicLog.write("iphone.bow", "sound preparation refused")
            }
        } catch {
            prepared = false
            IMicLog.write("iphone.bow", "sound preparation failed: \(error.localizedDescription)")
        }
    }

    func play() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard prepared, let player else {
            IMicLog.write("iphone.bow", "sound skipped: not prepared")
            return
        }
        // 音频会话由采集链路管理；这里不激活或修改 category、mode、route。
        player.currentTime = 0
        if !player.play() {
            prepared = false
            IMicLog.write("iphone.bow", "sound playback refused")
        } else {
            IMicLog.write("iphone.bow", "played duration_ms=\(Int(player.duration * 1000))")
        }
    }

    func stop() {
        prepared = false
        player?.stop()
        player?.currentTime = 0
    }

    private static func makeWave() -> Data {
        let sampleRate = 24_000
        let count = sampleRate * 105 / 1000
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

        var seed: UInt32 = 0xB07A_1105
        var lowPass = 0.0
        var slowPass = 0.0
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let attack = min(1, time / 0.0008)
            let tail = min(1, (0.105 - time) / 0.012)
            let frequency = 380 + 560 * exp(-time / 0.012)
            phase += 2 * .pi * frequency / Double(sampleRate)
            let twang = (sin(phase) + 0.28 * sin(phase * 2.01)) * exp(-time / 0.017)

            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            lowPass += 0.48 * (noise - lowPass)
            slowPass += 0.075 * (noise - slowPass)
            let whooshEnvelope = (1 - exp(-time / 0.003)) * exp(-time / 0.025)
            let whoosh = (lowPass - slowPass) * whooshEnvelope
            let sample = (twang * 0.36 + whoosh * 0.80) * attack * tail
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }
}
