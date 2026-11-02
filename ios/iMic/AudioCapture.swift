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
            interruptionBegan: { ($0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue }),
        makeHardware: { [unowned self] in AVMicHardware(onChunk: chunk, onBuffer: buffer) },
        deactivate: {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { IMicLog.write("iphone.audio", "deactivate failed: \(error.localizedDescription)") }
        }, log: { IMicLog.write("iphone.audio", $0) })

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

    func start(onChunk: @escaping (Data) -> Void,
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
                try controller.start(onFailure: { [weak self] message in
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
            sampleRate: session.sampleRate, nativeRate: nativeRate, channels: channels, running: engine.isRunning)
    }
    init(onChunk: @escaping (Data) -> Void, onBuffer: ((AVAudioPCMBuffer) -> Void)?) {
        self.onChunk = onChunk; self.onBuffer = onBuffer
    }
    func start(meter: @escaping (CaptureMeter) -> Void, failure: @escaping (String) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
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
