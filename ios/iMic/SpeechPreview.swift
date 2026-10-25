import AVFoundation
import Foundation
import Speech

/// Apple Speech 只负责“边说边出临时文字”，最终文本仍由 Mac 上的百炼模型校准。
/// 它使用同一路麦克风 buffer，不额外启动音频引擎。
@MainActor
final class SpeechPreview {
    private enum State {
        case idle, authorizing, listening, finishing
    }

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var state: State = .idle
    private var generation: UInt64 = 0
    private var audioEnded = false
    private var finishTask: Task<Void, Never>?
    private var onText: (@MainActor (String) -> Void)?
    private var lastText = ""
    private nonisolated let audioGate = PreviewAudioGate()

    var isRunning: Bool { state != .idle }

    init() {
        let locale = Locale(identifier: "zh-CN")
        recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale.current)
    }

    /// 每次开始都替换上一代，包括仍在等待系统授权的任务。
    func start(onText: @escaping @MainActor (String) -> Void) {
        stop()
        let generation = self.generation
        state = .authorizing
        self.onText = onText
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self,
                      self.generation == generation,
                      self.state == .authorizing else { return }
                guard status == .authorized else {
                    IMicLog.write("iphone.preview", "speech permission=\(status.rawValue)")
                    self.clear(cancel: false)
                    return
                }
                guard let recognizer = self.recognizer, recognizer.isAvailable else {
                    IMicLog.write("iphone.preview", "speech recognizer unavailable")
                    self.clear(cancel: false)
                    return
                }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.taskHint = .dictation
                request.addsPunctuation = false
                self.request = request
                self.state = .listening
                IMicLog.write("iphone.preview", "speech start generation=\(generation)")
                self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self = self,
                              self.generation == generation,
                              self.state == .listening || self.state == .finishing else { return }
                        if let result = result {
                            let text = result.bestTranscription.formattedString
                            if !text.isEmpty, text != self.lastText {
                                self.lastText = text
                                self.onText?(text)
                            }
                            if result.isFinal {
                                IMicLog.write("iphone.preview", "speech final generation=\(generation) chars=\(text.count)")
                            }
                        }
                        // onText 可能触发停止或新会话，不能清理它们的新任务。
                        guard self.generation == generation else { return }
                        if let error = error {
                            IMicLog.write("iphone.preview", "speech error generation=\(generation) error=\(error.localizedDescription)")
                        }
                        if result?.isFinal == true || error != nil {
                            self.clear(cancel: error != nil)
                        }
                    }
                }
                self.audioGate.open(generation: generation)
            }
        }
    }

    /// 音频线程调用：仅为本代录音复制 buffer，再回到主线程 append。
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let generation = audioGate.claim() else { return }
        let copy = buffer.copy() as? AVAudioPCMBuffer
        Task { @MainActor [weak self] in
            guard let self = self,
                  self.generation == generation,
                  self.state == .listening || self.state == .finishing else { return }
            if let copy = copy { self.request?.append(copy) }
            if self.audioGate.complete(generation: generation), self.state == .finishing {
                self.endAudio()
            }
        }
    }

    /// 正常松手：关掉音频入口，排空已经复制的 buffer 后 endAudio，保留尾部识别。
    /// 不等待此过程即可发送 audio.end，让 Mac 最终识别并行开始。
    func finish() {
        guard state == .listening else {
            if state == .authorizing { stop() }
            return
        }
        state = .finishing
        if audioGate.close() { endAudio() }
        let generation = self.generation
        IMicLog.write("iphone.preview", "speech finish generation=\(generation) chars=\(lastText.count)")
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self = self,
                  self.generation == generation, self.state == .finishing else { return }
            IMicLog.write("iphone.preview", "speech drain timeout generation=\(generation)")
            self.stop()
        }
    }

    /// 取消、断线、最终结果或新会话：立即作废授权和识别回调，不发送空文字。
    func stop() {
        let wasRunning = isRunning
        clear(cancel: true)
        if wasRunning { IMicLog.write("iphone.preview", "speech stop") }
    }

    private func endAudio() {
        guard !audioEnded else { return }
        audioEnded = true
        request?.endAudio()
    }

    private func clear(cancel: Bool) {
        generation &+= 1
        state = .idle
        _ = audioGate.close()
        finishTask?.cancel()
        finishTask = nil
        endAudio()
        if cancel { task?.cancel() }
        request = nil
        task = nil
        onText = nil
        lastText = ""
        audioEnded = false
    }
}

/// 锁内只保存代际和在途计数；Speech request 始终留在主线程。
/// 松手关闭入口后仍排空本代在途 buffer，新会话不会接收旧 buffer。
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
