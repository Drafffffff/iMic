import AVFoundation

#if DEBUG
/// 仅用于模拟器联调：没有可用输入设备时，用系统语音合成生成 PCM，
/// 走与真实录音相同的 20ms 分帧、加密与结果回传路径。
final class DebugSpeech {
    static let shared = DebugSpeech()

    private let queue = DispatchQueue(label: "imic.debug.speech")
    private var active: AVSpeechSynthesizer?

    private init() {}

    func synthesize(_ text: String, rate: Float = 0.48, completion: @escaping (Data?) -> Void) {
        queue.async {
            let synthesizer = AVSpeechSynthesizer()
            self.active = synthesizer
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
                ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = rate

            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            var converter: AVAudioConverter?
            var output = Data()
            var finished = false
            var finishWork: DispatchWorkItem?

            func complete() {
                guard !finished else { return }
                finished = true
                finishWork?.cancel()
                DispatchQueue.main.async {
                    self.active = nil
                    completion(output.isEmpty ? nil : output)
                }
            }

            // write 在分段处也可能回调零长度 buffer，用 0.6 秒静默窗口收尾。
            func scheduleFinish() {
                finishWork?.cancel()
                let work = DispatchWorkItem { complete() }
                finishWork = work
                self.queue.asyncAfter(deadline: .now() + 0.6, execute: work)
            }

            synthesizer.write(utterance) { buffer in
                self.queue.async {
                    guard !finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        scheduleFinish()
                        return
                    }
                    if pcm.frameLength > 0 {
                        if converter == nil {
                            converter = AVAudioConverter(from: pcm.format, to: target)
                        }
                        if let converter = converter {
                            let ratio = target.sampleRate / pcm.format.sampleRate
                            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
                            if let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) {
                                var error: NSError?
                                var supplied = false
                                let status = converter.convert(to: converted, error: &error) { _, pointer in
                                    if supplied {
                                        pointer.pointee = .noDataNow
                                        return nil
                                    }
                                    supplied = true
                                    pointer.pointee = .haveData
                                    return pcm
                                }
                                if status != .error, converted.frameLength > 0,
                                   let channel = converted.int16ChannelData?[0] {
                                    output.append(Data(
                                        bytes: channel,
                                        count: Int(converted.frameLength) * 2
                                    ))
                                }
                            }
                        }
                    }
                    scheduleFinish()
                }
            }

            self.queue.asyncAfter(deadline: .now() + 10) {
                complete()
            }
        }
    }
}
#endif
