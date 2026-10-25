import Foundation
import SwiftUI
import UIKit

/// 一次「按住—说话—松开—回传」的完整状态机。
///
/// 关键行为：按下立即起振与采集；链路尚未就绪时把 20ms 帧缓存起来，
/// 连上后按顺序补发。这样用户不需要等连接动画结束再开口。
@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case result
        case error
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var transcript = ""
    @Published private(set) var liveTranscript = ""
    @Published private(set) var isUploading = false
    @Published private(set) var pasted = false
    @Published private(set) var target: String?
    @Published private(set) var message: String?
    @Published private(set) var notice: String?
    @Published private(set) var micDenied = false
    @Published private(set) var copied = false
    @Published private(set) var remoteFeatures = 0b1110
    let spectrumStore = SpectrumStore()
    let link: LinkClient
    private let audio = AudioCapture()
    private let analyzer = SpectrumAnalyzer()
    private let speechPreview = SpeechPreview()
    private let waveformTrace = WaveformTraceStore.shared
    private let isPreview: Bool
    private let previewMode: String?
    private let debugTTSText: String?
    private let debugBufferText: String?
    private var debugDidRun = false
    private var audioGeneration: UInt64 = 0

    private var wantsRecording = false
    private var session: UInt16 = 0
    private var activeSession: UInt16?
    private var frames: UInt32 = 0
    private var samples = 0
    private var pending = Data()
    private var analysisWindow = Data()
    private var preRoll = Data()
    private var preRollSamplesAdded = 0
    private var buffered: [Data] = []
    /// 本次会话已发送/待补发的全部 20ms 音频块，用于 Mac 请求 audio.need 时重放。
    private var audioJournal: [Data] = []
    private var announcedSession = false
    private let maxBufferedChunks = IMicLink.sampleRate * IMicLink.maxSessionSeconds / IMicLink.frameSamples
    private var commitTimer: Timer?
    private var syntheticActive = false
    private var streaming = false
    private var pendingEnd = false
    private var timer: Timer?
    private var resultTimer: Timer?
    private var uploadTimer: Timer?
    private var submissionGeneration: UInt64 = 0
    private var endInFlight = false
    private var connectionTimer: Timer?
    private var previewTimer: Timer?
    private var previewSpectrumGeneration: UInt64 = 0
    private var syntheticTimer: Timer?
    private var syntheticData = Data()
    private var syntheticOffset = 0
    private var startedAt = Date()
    private var noticeTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?
    private var lastPreviewSent = Date.distantPast
    private var pendingLivePreview = ""
    private var lastLivePreviewSent = ""
    private var livePreviewGeneration: UInt64 = 0
    private var previewSendTask: Task<Void, Never>?

    init(link: LinkClient) {
        self.link = link
        isPreview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-preview=") }
        previewMode = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--ui-preview=") }?
            .replacingOccurrences(of: "--ui-preview=", with: "")
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(where: { $0.hasPrefix("--debug-tts=") }) {
            var parts = [String(arguments[index].dropFirst("--debug-tts=".count))]
            var next = index + 1
            while next < arguments.count, !arguments[next].hasPrefix("--") {
                parts.append(arguments[next])
                next += 1
            }
            debugTTSText = parts.joined(separator: " ")
        } else {
            debugTTSText = nil
        }
        if let index = arguments.firstIndex(where: { $0.hasPrefix("--debug-buffer-tts=") }) {
            var parts = [String(arguments[index].dropFirst("--debug-buffer-tts=".count))]
            var next = index + 1
            while next < arguments.count, !arguments[next].hasPrefix("--") {
                parts.append(arguments[next])
                next += 1
            }
            debugBufferText = parts.joined(separator: " ")
        } else {
            debugBufferText = nil
        }
        #else
        debugTTSText = nil
        debugBufferText = nil
        #endif

        link.onReady = { [weak self] _ in
            Task { @MainActor in
                self?.prepareHaptics()
                self?.handleLinkReady()
                self?.runDebugSpeechIfNeeded()
            }
        }
        link.onLost = { [weak self] in
            Task { @MainActor in self?.handleLinkLost() }
        }
        link.onResult = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        link.onRemoteState = { phase in
            IMicLog.write("iphone.session", "remote state=\(phase)")
        }
        link.onAudioNeed = { [weak self] session, from in
            Task { @MainActor in self?.replayAudio(session: session, from: from) }
        }
        link.onSettings = { [weak self] features in
            Task { @MainActor in self?.applyRemoteFeatures(features) }
        }

        if isPreview {
            configurePreview()
        } else {
            prepareHaptics()
        }
    }

    // MARK: - Permissions / first press

    /// 前台常驻热麦克风：按下时不再激活 AVAudioSession 或启动引擎，直接进入录音状态。
    func activateAudio() {
        guard !isPreview else { return }
        #if DEBUG
        // 模拟器联调用合成语音，不需要也不应该弹麦克风授权。
        if debugTTSText != nil || debugBufferText != nil { return }
        #endif
        if AudioCapture.permissionGranted {
            micDenied = false
            _ = startAudioEngine()
            if !wantsRecording { speechPreview.prepareAuthorization() }
            return
        }
        Task {
            let granted = await AudioCapture.requestPermission()
            guard !Task.isCancelled else { return }
            micDenied = !granted
            if granted {
                _ = startAudioEngine()
                if !wantsRecording { speechPreview.prepareAuthorization() }
            }
        }
    }

    func deactivateAudio() {
        audioGeneration &+= 1
        audio.stop()
        preRoll.removeAll()
        stopVisualInput()
    }

    @discardableResult
    private func startAudioEngine() -> Bool {
        guard !audio.isRunning else { return true }
        audioGeneration &+= 1
        let generation = audioGeneration
        do {
            try audio.start(
                onChunk: { [weak self] data in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.audioGeneration == generation else { return }
                        self.handleLiveAudio(data)
                    }
                },
                onBuffer: { [preview = speechPreview] buffer in
                    preview.append(buffer)
                },
                onFailure: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.audioGeneration == generation else { return }
                        self.handleAudioFailure(message)
                    }
                }
            )
            // 重启触感引擎，但不更改已运行的 playAndRecord 音频会话。
            Haptics.shared.prepare(force: true)
            return true
        } catch {
            audioGeneration &+= 1
            return false
        }
    }

    private func handleAudioFailure(_ message: String) {
        wantsRecording = false
        if phase == .listening { endListening(cancelled: true) }
        deactivateAudio()
        // 热麦失败不能破坏已提交的识别或已完成的文字。
        if phase == .transcribing || phase == .result {
            showNotice(message)
            return
        }
        phase = .error
        self.message = message
        Haptics.shared.play(.error)
    }

    /// 引擎一直运行；未录音时只保留最后 150ms，按下后立刻补进开头。
    private func handleLiveAudio(_ data: Data) {
        guard !isPreview, !syntheticActive else { return }
        if phase == .listening {
            ingest(data)
        } else if phase == .idle || phase == .error {
            preRoll.append(data)
            if preRoll.count > 4_800 {
                preRoll.removeFirst(preRoll.count - 4_800)
            }
            if preRoll.count % 2 == 1 { preRoll.removeFirst() }
        }
    }

    func beginListening() {
        if isPreview {
            if phase == .listening {
                endListening(cancelled: false)
            } else {
                previewBegin()
            }
            return
        }
        guard phase != .listening, phase != .transcribing else { return }
        guard link.phase.isReady || link.hasPairedMac else {
            Haptics.shared.play(.pairingRequired)
            phase = .error
            message = "先连接 Mac，再开始说话"
            return
        }

        // 触觉确认必须发生在任何异步工作之前：按下即响应。
        Haptics.shared.play(.press)
        wantsRecording = true
        notice = nil

        if AudioCapture.permissionGranted {
            guard startAudioEngine() else {
                phase = .error
                message = "麦克风启动失败"
                Haptics.shared.play(.error)
                return
            }
            startCapture()
        } else {
            Task {
                let granted = await AudioCapture.requestPermission()
                guard wantsRecording else { return }
                guard granted else {
                    micDenied = true
                    phase = .error
                    message = "麦克风权限未开启"
                    Haptics.shared.play(.error)
                    return
                }
                micDenied = false
                guard startAudioEngine() else {
                    phase = .error
                    message = "麦克风启动失败"
                    Haptics.shared.play(.error)
                    return
                }
                startCapture()
            }
        }
    }

    var livePreviewEnabled: Bool { remoteFeatures & 0b0001 != 0 }
    var snapReturnEnabled: Bool { remoteFeatures & 0b0010 != 0 }
    var pullDeleteEnabled: Bool { remoteFeatures & 0b0100 != 0 }
    var swipeCursorEnabled: Bool { remoteFeatures & 0b1000 != 0 }

    private func applyRemoteFeatures(_ features: Int) {
        remoteFeatures = features
        if !livePreviewEnabled {
            previewSendTask?.cancel()
            previewSendTask = nil
            pendingLivePreview = ""
            lastLivePreviewSent = ""
        } else if phase == .listening || phase == .transcribing {
            queueLivePreview(liveTranscript)
        }
    }

    private func startLivePreview() {
        guard phase == .listening, let session = activeSession else { return }
        livePreviewGeneration &+= 1
        let generation = livePreviewGeneration
        speechPreview.start { [weak self] text in
            guard let self = self,
                  self.livePreviewGeneration == generation,
                  self.session == session,
                  self.phase == .listening || self.phase == .transcribing || self.phase == .result else { return }
            self.liveTranscript = text
            self.queueLivePreview(text)
        }
    }

    private func queueLivePreview(_ text: String) {
        guard phase == .listening || phase == .transcribing,
              livePreviewEnabled, activeSession != nil else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != pendingLivePreview else { return }
        pendingLivePreview = clean
        let now = Date()
        let interval = now.timeIntervalSince(lastPreviewSent)
        if interval >= 0.20 {
            sendPendingLivePreview()
        } else if previewSendTask == nil {
            let generation = livePreviewGeneration
            previewSendTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self = self,
                      self.livePreviewGeneration == generation else { return }
                self.sendPendingLivePreview()
            }
        }
    }

    private func sendPendingLivePreview() {
        previewSendTask?.cancel()
        previewSendTask = nil
        guard phase == .listening || phase == .transcribing,
              livePreviewEnabled, activeSession != nil,
              announcedSession, link.phase.isReady else { return }
        let text = pendingLivePreview
        guard !text.isEmpty else { return }
        pendingLivePreview = ""
        guard text != lastLivePreviewSent else { return }
        lastLivePreviewSent = text
        lastPreviewSent = Date()
        IMicLog.write("iphone.preview", "send session=\(session) phase=\(phase) chars=\(text.count)")
        link.sendPreview(text)
    }

    /// 松手只结束 Speech 音频输入，不清空最后文字；Mac 最终识别立即并行进行。
    private func finishLivePreview() {
        speechPreview.finish()
        sendPendingLivePreview()
    }

    private func stopLivePreview() {
        livePreviewGeneration &+= 1
        speechPreview.stop()
        previewSendTask?.cancel()
        previewSendTask = nil
        pendingLivePreview = ""
        lastLivePreviewSent = ""
        lastPreviewSent = .distantPast
    }

    private func startCapture() {
        guard wantsRecording else { return }
        session = UInt16.random(in: 1...65535)
        activeSession = session
        submissionGeneration &+= 1
        endInFlight = false
        isUploading = false
        uploadTimer?.invalidate()
        uploadTimer = nil
        frames = 0
        samples = 0
        pending.removeAll(keepingCapacity: true)
        analysisWindow.removeAll(keepingCapacity: true)
        buffered.removeAll(keepingCapacity: true)
        stopLivePreview()
        audioJournal.removeAll(keepingCapacity: true)
        announcedSession = false
        streaming = false
        pendingEnd = false
        connectionTimer?.invalidate()
        connectionTimer = nil
        transcript = ""
        liveTranscript = ""
        pasted = false
        target = nil
        message = nil
        copied = false
        elapsed = 0
        startedAt = Date()
        phase = .listening
        syntheticActive = false
        waveformTrace.begin(source: .microphone)

        // 链路已就绪就立即宣告会话，让 Mac 立刻显示“正在听”。
        // 音频仍由 0.5 秒短按门限决定是否发送；短按会补发 audio.cancel。
        if link.phase.isReady {
            link.beginSession(session)
            announcedSession = true
        }
        IMicLog.write("iphone.session", "capture start session=\(session) ready=\(link.phase.isReady) preRollSamples=\(preRoll.count / 2) samples=\(samples)")

        // 预录 + 本地 0.5 秒：短按完全不会建立链接会话；按下瞬间已在采集。
        preRollSamplesAdded = preRoll.count / 2
        pending = preRoll
        preRoll.removeAll(keepingCapacity: true)
        if pending.count % 2 == 1 { pending.removeLast() }
        processPending()
        scheduleCommit()
        startTicker()

        startLivePreview()

        // 真正开始采集后才给“可以说话”的强触觉：短促双击 + 极短低频。
        Haptics.shared.play(.recordingStarted)
    }

    private func processPending() {
        while pending.count >= 640 {
            let chunk = pending.prefix(640)
            pending.removeFirst(640)
            captureChunk(Data(chunk))
        }
    }

    /// 只有按住超过 0.5 秒才建立链路会话；短按在本地就被丢弃，不发送任何音频。
    /// 注意：音频引擎刚启动时 0.5 秒内可能还没攒够 8000 个样本，因此不能只检查一次；
    /// 后续每个音频回调都会再次尝试提交，否则整段音频会永远留在本地缓冲。
    private func scheduleCommit() {
        commitTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.streaming && self.samples - self.preRollSamplesAdded < IMicLink.minimumSamples {
                    IMicLog.write("iphone.session", "commit deferred session=\(self.session) samples=\(self.samples) preRoll=\(self.preRollSamplesAdded)")
                }
                self.maybeBeginStreaming()
            }
        }
        commitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func maybeBeginStreaming() {
        guard phase == .listening, !streaming, activeSession != nil else { return }
        guard samples - preRollSamplesAdded >= IMicLink.minimumSamples else { return }
        guard link.phase.isReady else {
            armConnectionTimeout()
            return
        }
        beginStreaming()
        if !streaming { armConnectionTimeout() }
    }

    private func startTicker() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func endListening(cancelled: Bool) {
        wantsRecording = false
        guard phase == .listening else { return }
        timer?.invalidate()
        timer = nil
        commitTimer?.invalidate()
        commitTimer = nil
        syntheticTimer?.invalidate()
        syntheticTimer = nil
        syntheticActive = false
        syntheticData.removeAll()
        flushPending()
        elapsed = max(elapsed, Double(max(0, samples - preRollSamplesAdded)) / 16_000)

        if cancelled || samples - preRollSamplesAdded < IMicLink.minimumSamples {
            if !liveTranscript.isEmpty { transcript = liveTranscript }
            submissionGeneration &+= 1
            isUploading = false
            waveformTrace.cancel()
            connectionTimer?.invalidate()
            connectionTimer = nil
            if streaming || announcedSession { link.cancelSession(session) }
            IMicLog.write("iphone.session", "discard session=\(session) cancelled=\(cancelled) samples=\(samples) frames=\(frames) streamed=\(streaming) announced=\(announcedSession)")
            streaming = false
            announcedSession = false
            pendingEnd = false
            activeSession = nil
            buffered.removeAll()
            pending.removeAll()
            audioJournal.removeAll(keepingCapacity: true)
            phase = .idle
            stopVisualInput(reset: true)
            preRoll.removeAll()
            stopLivePreview()
            showNotice(cancelled ? "已取消" : "录音太短，再说一次")
            Haptics.shared.play(cancelled ? .cancelled : .tooShort)
            return
        }

        pendingEnd = true
        phase = .transcribing
        isUploading = true
        message = "正在上传音频…"
        stopVisualInput()
        waveformTrace.finish()
        finishLivePreview()
        IMicLog.write("iphone.session", "release session=\(session) samples=\(samples) frames=\(frames) streaming=\(streaming) announced=\(announcedSession) buffered=\(buffered.count)")
        Haptics.shared.play(.release)
        beginStreaming()
        if streaming && pendingEnd {
            finishStreaming()
        } else if !streaming {
            // 还没连上：保留缓存，连接成功后立刻补发并结束。
            armConnectionTimeout()
        }
    }

    private func tick() {
        guard phase == .listening else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if samples >= IMicLink.sampleRate * IMicLink.maxSessionSeconds ||
            elapsed >= Double(IMicLink.maxSessionSeconds) {
            submitAtRecordingLimit()
        }
    }

    private func ingest(_ data: Data) {
        guard phase == .listening else { return }
        analyzeVisuals(data)
        let remainingBytes = max(0, (IMicLink.sampleRate * IMicLink.maxSessionSeconds - samples) * 2 - pending.count)
        pending.append(data.prefix(remainingBytes))
        processPending()
        if !streaming {
            maybeBeginStreaming()
        }
        if samples >= IMicLink.sampleRate * IMicLink.maxSessionSeconds {
            submitAtRecordingLimit()
        }
    }

    private func submitAtRecordingLimit() {
        guard phase == .listening else { return }
        endListening(cancelled: false)
        notice = "已达到单次录音 \(IMicLink.maxSessionSeconds / 60) 分钟上限，已自动提交"
        IMicLog.write("iphone.session", "recording limit auto-submit session=\(session) samples=\(samples)")
    }

    private func flushPending() {
        processPending()
        guard pending.count >= 2 else {
            pending.removeAll()
            return
        }
        let length = pending.count - pending.count % 2
        captureChunk(Data(pending.prefix(length)))
        pending.removeAll()
    }

    /// 缓存或发送一帧；FFT 独立按麦克风回调更新。samples 表示已采集，frames 表示已发送。
    private func captureChunk(_ chunk: Data) {
        guard phase == .listening, !chunk.isEmpty, chunk.count % 2 == 0 else { return }
        let remaining = IMicLink.sampleRate * IMicLink.maxSessionSeconds - samples
        guard remaining > 0 else { return }
        let chunk = chunk.count / 2 > remaining ? Data(chunk.prefix(remaining * 2)) : chunk
        samples += chunk.count / 2
        if streaming {
            sendChunk(chunk)
            return
        }
        buffered.append(chunk)
        // 缓存与整段硬上限一致；不能丢弃开头来让计数看似仍在范围内。
        if buffered.count > maxBufferedChunks {
            failActiveSession("录音缓存已满，本次输入已停止")
        }
    }

    /// 每次麦克风回调都更新频谱，而不是等 20ms 网络帧；滚动窗口保证频率分辨率。
    private func analyzeVisuals(_ data: Data) {
        guard phase == .listening else { return }
        analysisWindow.append(data)
        if analysisWindow.count > 2_048 {
            analysisWindow.removeFirst(analysisWindow.count - 2_048)
        }
        // Data 的单位是字节：1024 字节 = 512 个 16-bit 采样，填满 512 点 FFT。
        // 之前误传 512 字节，实际只有 256 个采样，低频被零填充糊掉。
        let length = min(1024, analysisWindow.count)
        guard length >= 320 else { return }
        let pcm = Data(analysisWindow.suffix(length))
        let analysis = analyzer.analyze(pcm)
        spectrumStore.update(analysis.bands, level: analysis.level)
        waveformTrace.append(bands: analysis.bands, level: analysis.level, rmsDB: analysis.rmsDB)
    }

    /// 停止视觉输入后只把目标归零，让现有惯性自然收回；不向原始波形缓存追加假静音。
    /// Speech 尾字排空和网络音频补发与视觉生命周期独立。
    private func stopVisualInput(reset: Bool = false) {
        previewSpectrumGeneration &+= 1
        previewTimer?.invalidate()
        previewTimer = nil
        analysisWindow.removeAll(keepingCapacity: true)
        if reset {
            spectrumStore.reset()
        } else {
            spectrumStore.update([CGFloat](repeating: 0, count: 44), level: 0)
        }
    }

    private func sendChunk(_ chunk: Data) {
        guard !chunk.isEmpty, chunk.count % 2 == 0 else { return }
        let seq = frames
        if audioJournal.count == Int(seq) {
            audioJournal.append(chunk)
        } else if Int(seq) < audioJournal.count {
            audioJournal[Int(seq)] = chunk
        } else {
            // 正常情况下不会发生；保持日志便于定位序号与日志长度脱节。
            IMicLog.write("iphone.session", "journal gap session=\(session) seq=\(seq) journal=\(audioJournal.count)")
            while audioJournal.count < Int(seq) { audioJournal.append(Data()) }
            audioJournal.append(chunk)
        }
        link.sendAudio(chunk, session: session, seq: seq)
        frames += 1
        if seq % 25 == 0 {
            IMicLog.write("iphone.session", "sent seq=\(seq) frames=\(frames) samples=\(samples) journal=\(audioJournal.count)")
        }
    }

    private func replayAudio(session requested: UInt16, from: UInt32) {
        guard requested == session || requested == activeSession,
              activeSession != nil,
              Int(from) < audioJournal.count else {
            IMicLog.write("iphone.session", "replay ignored session=\(requested) from=\(from) active=\(activeSession.map(String.init) ?? "nil") journal=\(audioJournal.count)")
            return
        }
        let start = Int(from)
        let end = audioJournal.count
        IMicLog.write("iphone.session", "replay session=\(requested) from=\(start) count=\(end - start) frames=\(frames)")
        for index in start..<end {
            link.sendAudio(audioJournal[index], session: requested, seq: UInt32(index))
        }
    }

    private func beginStreaming() {
        guard !streaming, activeSession != nil, link.phase.isReady else {
            IMicLog.write("iphone.session", "beginStreaming blocked session=\(session) active=\(activeSession != nil) ready=\(link.phase.isReady) buffered=\(buffered.count)")
            return
        }
        streaming = true
        if !announcedSession {
            link.beginSession(session)
            announcedSession = true
        }
        IMicLog.write("iphone.session", "streaming session=\(session) buffered=\(buffered.count) samples=\(samples) frames=\(frames)")
        for chunk in buffered {
            sendChunk(chunk)
        }
        buffered.removeAll(keepingCapacity: true)
        connectionTimer?.invalidate()
        connectionTimer = nil
        // 连接前缓存的最后预览也须先于 audio.end 发出；不等待 Speech 收尾。
        sendPendingLivePreview()
        if pendingEnd { finishStreaming() }
    }

    private func finishStreaming() {
        guard pendingEnd, let active = activeSession, streaming, !endInFlight else { return }
        pendingEnd = false
        endInFlight = true
        let generation = submissionGeneration
        let uploadWait = max(30, Double(samples) / Double(IMicLink.sampleRate) * 2 + 15)
        uploadTimer?.invalidate()
        let timer = Timer(timeInterval: uploadWait, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.submissionGeneration == generation,
                      self.activeSession == active, self.endInFlight else { return }
                self.failActiveSession("音频上传超时，已保留本机识别文字，可复制后重试")
            }
        }
        uploadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        link.endSession(active, samples: samples, frames: Int(frames)) { [weak self] sent in
            guard let self, self.submissionGeneration == generation,
                  self.activeSession == active, self.phase == .transcribing,
                  self.endInFlight else { return }
            self.endInFlight = false
            self.isUploading = false
            self.uploadTimer?.invalidate()
            self.uploadTimer = nil
            guard sent else {
                self.failActiveSession("音频未能完整送达 Mac，已保留本机识别文字")
                return
            }
            IMicLog.write("iphone.session", "audio.end drained session=\(active) samples=\(self.samples) frames=\(self.frames)")
            self.message = "正在识别…"
            self.startResultTimeout()
        }
    }

    private func armConnectionTimeout() {
        guard connectionTimer == nil else { return }
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.phase == .listening || self.phase == .transcribing, !self.streaming else {
                    return
                }
                self.abortForConnection()
            }
        }
        connectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func abortForConnection() {
        failActiveSession("无法连接 Mac，请确认 Mac 上的 iMic 已打开")
    }

    /// 失败只保留可复制文字，绝不把本机临时识别自动投递到其它设备。
    private func failActiveSession(_ reason: String, cancelRemote: Bool = true) {
        if cancelRemote, let activeSession, announcedSession { link.cancelSession(activeSession) }
        if !liveTranscript.isEmpty { transcript = liveTranscript }
        submissionGeneration &+= 1
        wantsRecording = false
        waveformTrace.cancel()
        timer?.invalidate(); timer = nil
        commitTimer?.invalidate(); commitTimer = nil
        connectionTimer?.invalidate(); connectionTimer = nil
        uploadTimer?.invalidate(); uploadTimer = nil
        resultTimer?.invalidate(); resultTimer = nil
        syntheticTimer?.invalidate(); syntheticTimer = nil
        preRoll.removeAll()
        buffered.removeAll()
        pending.removeAll()
        syntheticData.removeAll()
        audioJournal.removeAll(keepingCapacity: true)
        streaming = false
        pendingEnd = false
        endInFlight = false
        isUploading = false
        activeSession = nil
        syntheticActive = false
        announcedSession = false
        stopLivePreview()
        phase = .error
        message = reason
        stopVisualInput()
        Haptics.shared.play(.error)
    }

    private func startResultTimeout() {
        resultTimer?.invalidate()
        // audio.end 在链路排空后，Mac 仍可能在向百炼上传真实积压音频。
        // 分别留出上传、最终识别及润色余量；不把 BLE 本地积压算成模型等待。
        let wait = max(30, Double(samples) / Double(IMicLink.sampleRate) * 2 + 15) + 90
        let generation = submissionGeneration
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.submissionGeneration == generation else { return }
                self.timeout()
            }
        }
        resultTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - FFT waveform history

    // MARK: - Debug speech (simulator without an input device)

    private func runDebugSpeechIfNeeded() {
        #if DEBUG
        guard let text = debugTTSText, !isPreview, !debugDidRun else { return }
        debugDidRun = true
        DebugSpeech.shared.synthesize(text) { [weak self] data in
            guard let self = self else { return }
            guard let data = data else {
                self.phase = .error
                self.message = "测试语音生成失败"
                return
            }
            self.beginSynthetic(data)
        }
        #endif
    }

    #if DEBUG
    /// 仅 DEBUG：用确定性音调验证「先缓存、连上补发」，不依赖系统 TTS 冷启动。
    func startDebugBufferTone() {
        guard !debugDidRun else { return }
        debugDidRun = true
        var data = Data(capacity: 320_000)
        for index in 0..<160_000 {
            let value = sin(2 * Double.pi * 440 * Double(index) / 16_000) * 0.22
            var sample = Int16(max(-1, min(1, value)) * 32767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        beginSynthetic(data, requireReady: false)
    }
    #endif

    /// 仅 DEBUG：在链路未就绪时开始合成语音，用来验证「先缓存、连上补发」。
    func startDebugBufferTest() {
        #if DEBUG
        guard let text = debugBufferText, !debugDidRun else { return }
        debugDidRun = true
        DebugSpeech.shared.synthesize(text) { [weak self] data in
            guard let self = self else { return }
            guard let data = data else {
                self.phase = .error
                self.message = "测试语音生成失败"
                return
            }
            self.beginSynthetic(data, requireReady: false)
        }
        #endif
    }

    private func beginSynthetic(_ data: Data, requireReady: Bool = true) {
        if requireReady, !link.phase.isReady { return }
        commitTimer?.invalidate()
        commitTimer = nil
        preRoll.removeAll()
        syntheticActive = true
        waveformTrace.begin(source: .synthetic)
        syntheticData = data
        syntheticOffset = 0
        session = UInt16.random(in: 1...65535)
        activeSession = session
        submissionGeneration &+= 1
        endInFlight = false
        isUploading = false
        uploadTimer?.invalidate()
        uploadTimer = nil
        preRollSamplesAdded = 0
        frames = 0
        samples = 0
        pending.removeAll()
        analysisWindow.removeAll()
        buffered.removeAll()
        stopLivePreview()
        audioJournal.removeAll(keepingCapacity: true)
        announcedSession = false
        streaming = false
        pendingEnd = false
        transcript = ""
        liveTranscript = ""
        pasted = false
        target = nil
        message = nil
        copied = false
        elapsed = 0
        startedAt = Date()
        phase = .listening
        spectrumStore.reset()
        if link.phase.isReady {
            beginStreaming()
        } else {
            armConnectionTimeout()
        }
        Haptics.shared.play(.recordingStarted)

        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pumpSynthetic() }
        }
        syntheticTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pumpSynthetic() {
        guard syntheticActive, phase == .listening else {
            syntheticTimer?.invalidate()
            syntheticTimer = nil
            return
        }
        if syntheticOffset >= syntheticData.count {
            syntheticTimer?.invalidate()
            syntheticTimer = nil
            elapsed = max(elapsed, Double(samples) / 16_000)
            syntheticActive = false
            pendingEnd = true
            phase = .transcribing
            isUploading = true
            message = "正在上传音频…"
            stopVisualInput()
            waveformTrace.finish()
            if streaming {
                finishStreaming()
            } else {
                armConnectionTimeout()
            }
            Haptics.shared.play(.release)
            return
        }
        let end = min(syntheticOffset + 640, syntheticData.count)
        var chunk = syntheticData.subdata(in: syntheticOffset..<end)
        if chunk.count % 2 == 1 { chunk.removeLast() }
        guard !chunk.isEmpty else {
            syntheticOffset = syntheticData.count
            return
        }
        syntheticOffset += chunk.count
        analyzeVisuals(chunk)
        captureChunk(chunk)
        elapsed = Double(samples) / 16_000
        if samples >= IMicLink.sampleRate * IMicLink.maxSessionSeconds {
            submitAtRecordingLimit()
        }
    }

    // MARK: - Link events

    private func handleLinkReady() {
        IMicLog.write("iphone.session", "link ready phase=\(phase) session=\(session) announced=\(announcedSession) samples=\(samples) frames=\(frames) buffered=\(buffered.count)")
        guard phase == .listening || phase == .transcribing else { return }
        guard activeSession != nil else { return }
        // 链路在按住的前 0.5 秒就绪时也不提前发送，等本地短按判定通过。
        guard pendingEnd || samples - preRollSamplesAdded >= IMicLink.minimumSamples else { return }
        beginStreaming()
    }

    private func handle(_ message: LinkMessage) {
        guard let active = activeSession else {
            IMicLog.write("iphone.session", "\(message.t) ignored no active session session=\(message.session ?? -1)")
            return
        }
        IMicLog.write("iphone.session", "receive \(message.t) session=\(message.session ?? -1) active=\(active) frames=\(frames) samples=\(samples)")
        if let sid = message.session, sid != Int(active) { return }
        wantsRecording = false
        timer?.invalidate()
        timer = nil
        syntheticTimer?.invalidate()
        syntheticTimer = nil
        uploadTimer?.invalidate()
        uploadTimer = nil
        submissionGeneration &+= 1
        endInFlight = false
        isUploading = false
        buffered.removeAll()
        pending.removeAll()
        syntheticData.removeAll()
        stopVisualInput()
        activeSession = nil
        streaming = false
        pendingEnd = false
        syntheticActive = false
        commitTimer?.invalidate()
        commitTimer = nil
        resultTimer?.invalidate()
        resultTimer = nil
        connectionTimer?.invalidate()
        connectionTimer = nil
        audioJournal.removeAll(keepingCapacity: true)
        announcedSession = false
        if message.t == "failure" {
            stopLivePreview()
            phase = .error
            if !liveTranscript.isEmpty { transcript = liveTranscript }
            self.message = message.message ?? "识别失败，请重试"
            Haptics.shared.play(.error)
            return
        }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            stopLivePreview()
            phase = .error
            if !liveTranscript.isEmpty { transcript = liveTranscript }
            self.message = "没有听清，再试一次"
            Haptics.shared.play(.warning)
            return
        }
        transcript = text
        self.message = nil
        pasted = message.pasted == true
        target = message.target
        phase = .result
        copied = false
        Haptics.shared.play(.result)
    }

    private func handleLinkLost() {
        guard phase == .listening || phase == .transcribing else { return }
        failActiveSession("与 Mac 的连接已断开，已保留本机识别文字", cancelRemote: false)
    }

    private func timeout() {
        guard phase == .transcribing else { return }
        failActiveSession("识别超时，已保留本机识别文字，可复制后重试")
    }

    func cancelForDeviceSwitch() {
        wantsRecording = false
        guard phase == .listening || phase == .transcribing else {
            stopLivePreview()
            return
        }
        failActiveSession("已取消旧 Mac 的语音会话")
        phase = .idle
        message = nil
        notice = "已保留本机识别文字"
    }

    // MARK: - Actions

    func reset() {
        guard phase != .listening else { return }
        waveformTrace.cancel()
        submissionGeneration &+= 1
        wantsRecording = false
        endInFlight = false
        isUploading = false
        uploadTimer?.invalidate()
        uploadTimer = nil
        syntheticTimer?.invalidate()
        syntheticTimer = nil
        syntheticData.removeAll()
        if streaming { link.cancelSession(session) }
        timer?.invalidate()
        timer = nil
        commitTimer?.invalidate()
        commitTimer = nil
        resultTimer?.invalidate()
        resultTimer = nil
        connectionTimer?.invalidate()
        connectionTimer = nil
        preRoll.removeAll()
        syntheticActive = false
        buffered.removeAll()
        pending.removeAll()
        stopLivePreview()
        audioJournal.removeAll(keepingCapacity: true)
        announcedSession = false
        streaming = false
        pendingEnd = false
        activeSession = nil
        phase = .idle
        message = nil
        notice = nil
        transcript = ""
        liveTranscript = ""
        pasted = false
        target = nil
        stopVisualInput(reset: true)
    }

    /// 中心弦手势：回车 / 删除 / 左右移动光标。Mac 端设置关闭时会忽略。
    @discardableResult
    func sendInput(_ action: String) -> Bool {
        guard link.phase.isReady else {
            Haptics.shared.play(.warning)
            return false
        }
        link.sendInput(action)
        return true
    }

    func showGestureNotice(_ text: String?) {
        notice = text
        noticeTask?.cancel()
        guard let text else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            if self?.notice == text { self?.notice = nil }
        }
    }

    func copyTranscript() {
        guard !transcript.isEmpty else { return }
        UIPasteboard.general.string = transcript
        copied = true
        Haptics.shared.play(.copy)
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func prepareHaptics() {
        Haptics.shared.prepare()
    }

    func handleForeground() {
        Haptics.shared.prepare(force: true)
        link.activate()
        if AudioCapture.permissionGranted { micDenied = false }
        activateAudio()
    }

    func handleBackground() {
        if phase == .listening { endListening(cancelled: true) }
        deactivateAudio()
        Haptics.shared.stop()
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Preview

    private func configurePreview() {
        switch previewMode {
        case "listening":
            phase = .listening
            elapsed = 2.8
            spectrumStore.reset()
            startPreviewSpectrum()
        case "transcribing":
            phase = .transcribing
            elapsed = 3.4
            spectrumStore.reset()
        case "result":
            phase = .result
            transcript = "把今天讨论的交互细节整理成一页说明，重点保留按住说话、松开即输入的节奏。"
            pasted = true
            target = "Craft"
            elapsed = 2.3
            spectrumStore.reset()
        case "error":
            phase = .error
            message = "没有听清，再试一次"
        default:
            phase = .idle
        }
    }

    private func previewBegin() {
        phase = .listening
        elapsed = 0
        transcript = ""
        message = nil
        spectrumStore.reset()
        startPreviewSpectrum()
    }

    private func startPreviewSpectrum() {
        previewTimer?.invalidate()
        previewSpectrumGeneration &+= 1
        let generation = previewSpectrumGeneration
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.phase == .listening,
                      self.previewSpectrumGeneration == generation else { return }
                let t = Date().timeIntervalSinceReferenceDate
                var next = [CGFloat](repeating: 0, count: 44)
                for index in 0..<44 {
                    let x = CGFloat(index) / 43
                    let first = 0.70 * exp(-pow((x - (0.24 + 0.07 * CGFloat(sin(t * 0.72)))) / 0.07, 2))
                    let second = 0.52 * exp(-pow((x - (0.62 + 0.09 * CGFloat(sin(t * 0.51)))) / 0.09, 2))
                    let base = 0.05 + 0.035 * sin(t * 0.9 + Double(index) * 0.17)
                    next[index] = CGFloat(min(1, max(0, Double(first + second) + base)))
                }
                let level = CGFloat(0.45 + 0.28 * (0.5 + 0.5 * sin(t * 0.9)))
                self.spectrumStore.set(next, level: level)
                if self.phase == .listening { self.elapsed += 0.04 }
            }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
