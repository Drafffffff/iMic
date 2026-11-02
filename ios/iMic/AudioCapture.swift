import AVFoundation
import UIKit

/// Main-thread request facade. Every activation, engine operation and deactivation
/// (including retry) is serialized by the controller's lifecycle queue.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case format
        var errorDescription: String? { L10n.text("Microphone format unavailable") }
    }
    private let lifecycle = DispatchQueue(label: "imic.audio.lifecycle", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var requested = false
    private var request: UInt64 = 0
    private var delivery: CaptureDeliveryGate?
    private var chunk: (Data) -> Void = { _ in }
    private var buffer: ((AVAudioPCMBuffer) -> Void)?
    private lazy var controller = AudioCaptureController(
        queue: lifecycle, center: .default,
        names: CaptureNotifications(
            interruption: AVAudioSession.interruptionNotification,
            route: AVAudioSession.routeChangeNotification,
            configuration: .AVAudioEngineConfigurationChange,
            reset: AVAudioSession.mediaServicesWereResetNotification,
            foreground: UIApplication.didBecomeActiveNotification,
            interruptionBegan: { ($0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue },
            oldDeviceUnavailable: { ($0.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue }),
        makeHardware: { [unowned self] in AVMicHardware(onChunk: chunk, onBuffer: buffer) },
        deactivate: { notifyOthers in
            do { try AVAudioSession.sharedInstance().setActive(false, options: notifyOthers ? .notifyOthersOnDeactivation : []) }
            catch { IMicLog.write("iphone.audio", "deactivate failed: \(error.localizedDescription)") }
        }, rebuildRoute: { try AVMicSession.rebuildRoute() },
        log: { IMicLog.write("iphone.audio", $0) })

    init() {
        lifecycle.setSpecific(key: queueKey, value: true)
        _ = controller // Register notifications before the first engine exists.
    }

    var isRunning: Bool { requested }
    static var permissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func start(rebuildFirst: Bool = false, onChunk: @escaping (Data) -> Void,
               onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil,
               onFailure: @escaping (String) -> Void,
               onDiagnostics: ((CaptureDiagnostics) -> Void)? = nil,
               completion: @escaping (Error?) -> Void) {
        guard !requested else { return }
        requested = true
        request &+= 1
        let current = request
        let gate = CaptureDeliveryGate()
        delivery = gate
        IMicLog.write("iphone.audio", "start requested generation=\(current)")
        lifecycle.async { [self] in
            chunk = { data in gate.deliver { onChunk(data) } }
            buffer = onBuffer.map { callback in { pcm in gate.deliver { callback(pcm) } } }
            do {
                try controller.start(rebuildFirst: rebuildFirst, onFailure: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request == current, self.requested else { return }
                        self.requested = false
                        gate.close()
                        onFailure(L10n.text(message))
                    }
                }, onDiagnostics: { [weak self] diagnostics in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request == current else { return }
                        onDiagnostics?(diagnostics)
                    }
                })
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.request == current, self.requested else { return }
                    completion(nil)
                }
            } catch {
                IMicLog.write("iphone.audio", "start failed generation=\(current) error=\(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.request == current else { return }
                    self.requested = false
                    gate.close()
                    completion(error)
                }
            }
        }
    }

    /// Only active holds/self-test run the silence watchdog; idle warm leases
    /// retain pre-roll without spending a retry on a quiet room.
    func setMonitoring(_ enabled: Bool) {
        lifecycle.async { [self] in controller.setMonitoring(enabled) }
    }

    /// MIC TEST only: preserves its callbacks and the controller's one-recovery
    /// budget, including after a failed start. It never opens SpeechPreview.
    func rebuildRouteForMicrophoneTest(completion: @escaping (Bool) -> Void) {
        let current = request
        let wasRequested = requested
        requested = true
        lifecycle.async { [self] in
            let accepted = controller.recoverManually()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == current else { return }
                if !accepted { self.requested = wasRequested }
                completion(accepted)
            }
        }
    }

    func stop() {
        delivery?.close()
        delivery = nil
        requested = false
        request &+= 1
        let current = request
        lifecycle.async { [self] in
            IMicLog.write("iphone.audio", "stop generation=\(current)")
            controller.stop()
            chunk = { _ in }; buffer = nil
        }
    }

    deinit {
        delivery?.close()
        if DispatchQueue.getSpecific(key: queueKey) == true { controller.stop() }
        else { lifecycle.sync { controller.stop() } }
    }
}

private final class AVMicHardware: CaptureHardware {
    private let engine = AVAudioEngine()
    private var bridge: IMicAudioInputBridge?
    private var nativeRate: Double = 0
    private var channels: UInt32 = 0
    private let onChunk: (Data) -> Void
    private let onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var notificationObject: AnyObject { engine }
    var inputIdentity: String {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.map { "\($0.uid):\($0.portType.rawValue)" }.joined(separator: ",")
            + ":\(session.sampleRate):\(session.inputNumberOfChannels)"
    }
    var diagnostics: CaptureDiagnostics {
        let session = AVAudioSession.sharedInstance()
        return CaptureDiagnostics(input: session.currentRoute.inputs.map(\.portName).joined(separator: ", "),
            route: session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
            sampleRate: session.sampleRate, nativeRate: nativeRate, channels: channels, running: engine.isRunning,
            inputRoute: AVMicSession.inputRoute())
    }
    init(onChunk: @escaping (Data) -> Void, onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        self.onChunk = onChunk; self.onBuffer = onBuffer
    }
    func start(meter: @escaping (CaptureMeter) -> Void, failure: @escaping (String) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try AVMicSession.configureCapture()
        try session.setActive(true)
        let route = AVMicSession.inputRoute()
        IMicLog.write("iphone.audio", "activated input-route \(route.report)")
        guard route.invalidReason == nil else {
            IMicLog.write("iphone.audio", "invalid-input-route \(route.report)")
            throw CaptureRouteError.invalidInputRoute
        }
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        // Preferences are hints. Read actual native format AFTER activation, connect
        // the sink at that format, then convert on the non-realtime bridge worker.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCapture.CaptureError.format }
        nativeRate = format.sampleRate; channels = format.channelCount
        let bridge = try IMicAudioInputBridge(format: format, onChunk: onChunk,
            onBuffer: onBuffer, onFailure: { message in
                IMicLog.write("iphone.audio", "bridge failure: \(message)")
                failure("Microphone input failed. Hold again to record.")
            },
            onMeter: { rms, peak, callbacks, samples, zero, elapsed in
                meter(CaptureMeter(rms: rms, peak: peak, callbacks: callbacks,
                                   hasSamples: samples, allZero: zero, elapsed: elapsed))
            }, onLog: { IMicLog.write("iphone.audio", $0) })
        self.bridge = bridge
        engine.attach(bridge.sinkNode)
        engine.connect(input, to: bridge.sinkNode, format: format)
        engine.prepare()
        try engine.start()
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        IMicLog.write("iphone.audio", "sink engine running \(diagnostics.report)")
    }
    func stop() {
        engine.stop()
        if let bridge {
            engine.disconnectNodeInput(bridge.sinkNode)
            engine.detach(bridge.sinkNode)
            bridge.finish()
        }
        bridge = nil
    }
}


extension CaptureRouteError: LocalizedError {
    var errorDescription: String? { L10n.text(Self.message) }
}

private enum AVMicSession {
    static func inputRoute() -> CaptureInputRoute {
        let session = AVAudioSession.sharedInstance()
        func port(_ value: AVAudioSessionPortDescription) -> CaptureInputPort {
            CaptureInputPort(uid: value.uid, type: value.portType.rawValue, name: value.portName)
        }
        return CaptureInputRoute(inputs: session.currentRoute.inputs.map(port), available: session.availableInputs?.map(port))
    }

    static func configureCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.01)
    }

    static func rebuildRoute() throws {
        let session = AVAudioSession.sharedInstance()
        // The old engine has stopped and the session is inactive. Mix during
        // the brief playback activation; don't render ANY buffers or UI sounds.
        // This is an attempted workaround, not an API guarantee of OS repair.
        do {
            IMicLog.write("iphone.audio", "route-recovery playback activate mixWithOthers; no rendered audio")
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try session.setActive(false)
            try configureCapture()
            IMicLog.write("iphone.audio", "route-recovery restored capture configuration; next build reactivates and validates")
        } catch {
            try? session.setActive(false)
            try? configureCapture()
            throw error
        }
    }
}
