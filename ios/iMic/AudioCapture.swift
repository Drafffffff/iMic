import AVFoundation

/// On-demand 16 kHz / mono / PCM16 capture, with a short warm lease owned by SessionModel.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case format

        var errorDescription: String? {
            switch self {
            case .format: return "麦克风格式不可用"
            }
        }
    }

    private var engine: AVAudioEngine?
    private var inputBridge: IMicAudioInputBridge?
    private var running = false

    var isRunning: Bool { running }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Both audio callbacks and onFailure run in order on one non-realtime worker.
    /// onBuffer borrows its storage until return. onChunk owns its Data bytes.
    /// onFailure is terminal: the owner must stop capture on its lifecycle queue.
    func start(
        onChunk: @escaping (Data) -> Void,
        onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil,
        onFailure: @escaping (String) -> Void
    ) throws {
        guard !running else { return }
        IMicLog.write("iphone.audio", "sink engine start requested")
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true, options: [])
            // Preserve touch feedback and bow playback while capturing.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)

            // Every generation owns a fresh engine, sink and queue: no old IO callback
            // can enter the next recording's converter or audio callbacks.
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureError.format
            }
            let bridge = try IMicAudioInputBridge(
                format: format,
                onChunk: onChunk,
                onBuffer: onBuffer,
                onFailure: onFailure,
                onLog: { IMicLog.write("iphone.audio", $0) }
            )
            self.engine = engine
            self.inputBridge = bridge
            engine.attach(bridge.sinkNode)
            // AVAudioSinkNode cannot convert formats: match the input output scope.
            engine.connect(input, to: bridge.sinkNode, format: format)
            engine.prepare()
            try engine.start()
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            running = true
            IMicLog.write(
                "iphone.audio",
                "sink engine running nativeRate=\(format.sampleRate) channels=\(format.channelCount) sessionRate=\(session.sampleRate) IOBufferDuration=\(session.ioBufferDuration)"
            )
        } catch {
            tearDownInput()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        guard engine != nil else { return }
        running = false
        IMicLog.write("iphone.audio", "sink engine stop; draining worker")
        tearDownInput()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tearDownInput() {
        // First synchronously stop hardware IO. Only then drain the SPSC queue and
        // converter tail before releasing buffers, closures or the sink's C state.
        if let engine = engine {
            engine.stop()
            if let bridge = inputBridge {
                engine.disconnectNodeInput(bridge.sinkNode)
                engine.detach(bridge.sinkNode)
            }
        }
        inputBridge?.finish()
        inputBridge = nil
        engine = nil
        running = false
    }

    deinit {
        stop()
    }
}
