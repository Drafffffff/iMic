import AVFoundation
import Foundation
import Speech

/// Apple Speech 只提供本地实时文字，最终正文仍由 Mac 的百炼模型生成。
/// 每个 buffer 只属于一个滚动分段；上一段 endAudio 后继续排空，下一段立即接收音频。
@MainActor
final class SpeechPreview {
    private final class Segment {
        let id: UInt64
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var drainTask: Task<Void, Never>?
        var text = ""
        var audio: [AVAudioPCMBuffer] = []
        var duration: TimeInterval = 0
        var recognizedThrough: TimeInterval = 0
        var ended = false
        var completed = false

        init(id: UInt64) { self.id = id }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        ?? SFSpeechRecognizer(locale: .current)
    private var generation: UInt64 = 0
    private var segmentID: UInt64 = 0
    private var segments: [Segment] = []
    private var current: Segment?
    private var accepting = false
    private var finishing = false
    private var failures = 0
    private var rotationTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var onText: (@MainActor (String) -> Void)?
    private var lastText = ""
    private var authorizationRequested = false
    private nonisolated let audioGate = PreviewAudioGate()

    var isRunning: Bool { accepting || finishing }

    /// 只在没有按住录音时调用；首次授权绝不插入按住路径或阻塞百炼采集。
    func prepareAuthorization() {
        guard !isRunning, !authorizationRequested,
              SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        authorizationRequested = true
        SFSpeechRecognizer.requestAuthorization { status in
            IMicLog.write("iphone.preview", "speech permission=\(status.rawValue)")
        }
    }

    func start(onText: @escaping @MainActor (String) -> Void) {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              recognizer?.isAvailable == true else {
            IMicLog.write("iphone.preview", "speech unavailable or not authorized; final ASR remains active")
            return
        }
        self.onText = onText
        accepting = true
        failures = 0
        audioGate.open(generation: generation)
        beginSegment()
    }

    private func beginSegment(replaying audio: [AVAudioPCMBuffer] = []) {
        guard accepting, let recognizer, recognizer.isAvailable else {
            stopPreservingText()
            return
        }
        segmentID &+= 1
        let segment = Segment(id: segmentID)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        segment.request = request
        segments.append(segment)
        current = segment
        let generation = self.generation
        segment.task = recognizer.recognitionTask(with: request) { [weak self, weak segment] result, error in
            Task { @MainActor in
                guard let self, let segment, self.generation == generation,
                      !segment.completed else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        segment.text = text
                        segment.recognizedThrough = result.bestTranscription.segments
                            .map { $0.timestamp + $0.duration }.max() ?? 0
                        self.failures = 0
                        self.publish()
                    }
                }
                // 发布回调可能取消/替换整次录音。
                guard self.generation == generation else { return }
                if let error {
                    IMicLog.write("iphone.preview", "speech segment=\(segment.id) error=\(error.localizedDescription)")
                }
                if result?.isFinal == true || error != nil {
                    self.complete(segment, failed: error != nil)
                }
            }
        }
        for buffer in audio { append(buffer, to: segment, allowRotation: false) }
        armRotation(for: segment)
        IMicLog.write("iphone.preview", "speech segment start id=\(segment.id) replayBuffers=\(audio.count)")
    }

    /// 音频工作线程只复制本会话输入；主线程按到达顺序把它交给当前分段。
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let generation = audioGate.claim() else { return }
        let copy = buffer.copy() as? AVAudioPCMBuffer
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            if let copy, let current = self.current { self.append(copy, to: current) }
            if self.audioGate.complete(generation: generation), self.finishing {
                self.endCurrentAudio()
            }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to segment: Segment, allowRotation: Bool = true) {
        guard !segment.ended else { return }
        segment.audio.append(buffer)
        segment.duration += Double(buffer.frameLength) / buffer.format.sampleRate
        segment.request?.append(buffer)
        // Apple 文档要求按一分钟上限设计；留出结束和尾字排空的余量。
        if allowRotation, accepting, segment.duration >= 45 { rotate(segment) }
    }

    private func armRotation(for segment: Segment) {
        rotationTask?.cancel()
        let generation = self.generation
        rotationTask = Task { @MainActor [weak self, weak segment] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, let segment,
                  self.generation == generation, self.accepting, self.current === segment else { return }
            self.rotate(segment)
        }
    }

    private func rotate(_ segment: Segment) {
        guard accepting, current === segment else { return }
        end(segment)
        beginSegment()
    }

    private func end(_ segment: Segment) {
        guard !segment.ended else { return }
        segment.ended = true
        segment.request?.endAudio()
        // 已结束分段无需保留音频副本；文字仍按分段顺序累计，不能清空前缀。
        segment.audio.removeAll()
        let generation = self.generation
        segment.drainTask = Task { @MainActor [weak self, weak segment] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, let segment, self.generation == generation else { return }
            IMicLog.write("iphone.preview", "speech segment drain timeout id=\(segment.id)")
            segment.task?.cancel()
            self.release(segment)
        }
    }

    private func complete(_ segment: Segment, failed: Bool) {
        if current === segment, accepting {
            // 系统可能提前 isFinal/error。冻结已识别文字，仅重放尚未覆盖的真实音频尾部，
            // 不重放整段，也不使用文本后缀去重（真实重复的词必须保留）。
            let tail = unrecognizedAudio(in: segment)
            segment.ended = true
            segment.task?.cancel()
            release(segment)
            failures += failed ? 1 : 0
            if failures >= 3 {
                IMicLog.write("iphone.preview", "speech recovery exhausted; preserving local text")
                stopPreservingText()
            } else {
                beginSegment(replaying: tail)
            }
        } else {
            release(segment)
        }
    }

    private func unrecognizedAudio(in segment: Segment) -> [AVAudioPCMBuffer] {
        var cursor: TimeInterval = 0
        var tail: [AVAudioPCMBuffer] = []
        for buffer in segment.audio {
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            defer { cursor += duration }
            guard cursor + duration > segment.recognizedThrough else { continue }
            let skip = AVAudioFrameCount(max(0, min(Double(buffer.frameLength),
                ((segment.recognizedThrough - cursor) * buffer.format.sampleRate).rounded(.up))))
            if skip == 0 {
                tail.append(buffer)
            } else if skip < buffer.frameLength,
                      let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - skip) {
                copy.frameLength = buffer.frameLength - skip
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
                for index in 0..<min(source.count, destination.count) {
                    if let src = source[index].mData, let dst = destination[index].mData {
                        memcpy(dst, src.advanced(by: Int(skip) * bytesPerFrame), Int(copy.frameLength) * bytesPerFrame)
                    }
                }
                tail.append(copy)
            }
        }
        return tail
    }

    private func release(_ segment: Segment) {
        segment.completed = true
        segment.drainTask?.cancel()
        segment.drainTask = nil
        segment.request = nil
        segment.task = nil
        segment.audio.removeAll()
        if current === segment { current = nil }
        if finishing, segments.allSatisfy({ $0.task == nil }) { stopPreservingText() }
    }

    private func publish() {
        let text = segments.map(\.text).filter { !$0.isEmpty }.reduce("") { prefix, next in
            // 拉丁词跨分段需要空格；中文不插入人为分隔。
            guard let last = prefix.last, let first = next.first else { return prefix + next }
            return prefix + (last.isASCII && last.isLetter && first.isASCII && first.isLetter ? " " : "") + next
        }
        guard !text.isEmpty, text != lastText else { return }
        lastText = text
        onText?(text)
    }

    /// 松手后关闭入口，所有已复制 buffer 先排空，再 endAudio；上一滚动分段也继续排空。
    func finish() {
        guard accepting else { return }
        accepting = false
        finishing = true
        rotationTask?.cancel()
        rotationTask = nil
        if audioGate.close() { endCurrentAudio() }
        let generation = self.generation
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation, self.finishing else { return }
            self.stopPreservingText()
        }
    }

    private func endCurrentAudio() {
        if let current { end(current) }
    }

    private func stopPreservingText() {
        publish()
        stop()
    }

    /// 新录音/取消使所有迟到回调失效，但不回调空字符串，SessionModel 持有最后正文。
    func stop() {
        generation &+= 1
        accepting = false
        finishing = false
        _ = audioGate.close()
        rotationTask?.cancel()
        rotationTask = nil
        finishTask?.cancel()
        finishTask = nil
        for segment in segments {
            segment.drainTask?.cancel()
            segment.request?.endAudio()
            segment.task?.cancel()
        }
        segments.removeAll()
        current = nil
        onText = nil
        lastText = ""
    }
}

/// 锁内只保存代际和在途计数；Speech request 始终留在主线程。
private final class PreviewAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var accepting = false
    private var inFlight = 0

    func open(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.generation = generation
        inFlight = 0
        accepting = true
    }

    func claim() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return nil }
        inFlight += 1
        return generation
    }

    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        return inFlight == 0
    }

    func complete(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return false }
        inFlight -= 1
        return !accepting && inFlight == 0
    }
}
