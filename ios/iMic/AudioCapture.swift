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

    // Session activation and engine start/stop block for 0.2–1s on device. They run on this
    // serial queue, never the main thread, so pressing the bar no longer freezes the UI.
    // engine and inputBridge are confined to `lifecycle`; requests are made on the main thread.
    private let lifecycle = DispatchQueue(label: "imic.audio.lifecycle", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var inputBridge: IMicAudioInputBridge?
    private var requested = false
    private var request: UInt64 = 0

    /// The owner's requested state (main thread): true from start() until stop() or a failed start.
    var isRunning: Bool { requested }

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
    /// Returns at once; `completion` runs on the main thread when the engine is up or failed.
    func start(
        onChunk: @escaping (Data) -> Void,
        onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil,
        onFailure: @escaping (String) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard !requested else { return }
        requested = true
        request &+= 1
        let current = request
        IMicLog.write("iphone.audio", "sink engine start requested")
        lifecycle.async { [self] in
            do {
                try startEngine(onChunk: onChunk, onBuffer: onBuffer, onFailure: onFailure)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { [self] in
                    // A later start/stop request owns the state; only reset our own.
                    if request == current { requested = false }
                    completion(error)
                }
            }
        }
    }

    private func startEngine(
        onChunk: @escaping (Data) -> Void,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?,
        onFailure: @escaping (String) -> Void
    ) throws {
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

    /// Returns at once; teardown runs after any pending start on the lifecycle queue.
    func stop() {
        guard requested else { return }
        requested = false
        request &+= 1
        lifecycle.async { [self] in
            guard engine != nil else { return }
            IMicLog.write("iphone.audio", "sink engine stop; draining worker")
            tearDownInput()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
    }

    deinit {
        lifecycle.sync {
            guard engine != nil else { return }
            tearDownInput()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
