import Foundation

struct CaptureMeter {
    var rms: Double = 0
    var peak: Double = 0
    var callbacks: UInt64 = 0
    var hasSamples = false
    var allZero = false
    var elapsed: TimeInterval = 0
}

struct CaptureDiagnostics {
    var meter = CaptureMeter()
    var input = "—"
    var route = "none"
    var sampleRate: Double = 0
    var nativeRate: Double = 0
    var channels: UInt32 = 0
    var running = false
    var attempt = 0
    var event = "idle"

    var report: String {
        "iMic MIC TEST\ninput=\(input) route=\(route)\nsessionRate=\(sampleRate) nativeRate=\(nativeRate) channels=\(channels)\nengineRunning=\(running) attempt=\(attempt) event=\(event)\nRMS=\(meter.rms) peak=\(meter.peak) callbacks=\(meter.callbacks) interval=\(meter.elapsed) allZero=\(meter.allZero)"
    }
}

/// All methods and hardware operations belong to ONE serial lifecycle queue. Backend
/// callbacks are enqueued on it too. No deferred old-generation deactivation exists.
/// Foundation-only so the production controller can be exercised with fake hardware.
protocol CaptureHardware: AnyObject {
    var notificationObject: AnyObject { get }
    var diagnostics: CaptureDiagnostics { get }
    var inputIdentity: String { get }
    func start(meter: @escaping (CaptureMeter) -> Void, failure: @escaping (String) -> Void) throws
    func stop()
}

struct CaptureNotifications {
    var interruption: Notification.Name
    var route: Notification.Name
    var configuration: Notification.Name
    var reset: Notification.Name
    var foreground: Notification.Name
    var interruptionBegan: (Notification) -> Bool
}

final class AudioCaptureController {
    let queue: DispatchQueue
    private let center: NotificationCenter
    private let names: CaptureNotifications
    private let makeHardware: () -> CaptureHardware
    private let deactivate: () -> Void
    private let log: (String) -> Void
    private let now: () -> TimeInterval
    private var measuredAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var hardware: CaptureHardware?
    private var active = false
    private var identity = ""
    private var epoch: UInt64 = 0
    private var retried = false
    private var monitoring = false
    private var noCallbacks: TimeInterval = 0
    private var zeroSamples: TimeInterval = 0
    private var interrupted = false
    private var onFailure: ((String) -> Void)?
    private var onDiagnostics: ((CaptureDiagnostics) -> Void)?
    private var last = CaptureDiagnostics()

    init(queue: DispatchQueue, center: NotificationCenter, names: CaptureNotifications,
         makeHardware: @escaping () -> CaptureHardware, deactivate: @escaping () -> Void,
         log: @escaping (String) -> Void, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.queue = queue; self.center = center; self.names = names
        self.makeHardware = makeHardware; self.deactivate = deactivate; self.log = log; self.now = now
        for name in [names.interruption, names.route, names.configuration, names.reset, names.foreground] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                // Capture the originating engine, never substitute whichever engine is
                // current when a delayed configuration notification finally arrives.
                self?.queue.async { [weak self] in self?.receive(note) }
            })
        }
    }

    func start(onFailure: @escaping (String) -> Void,
               onDiagnostics: @escaping (CaptureDiagnostics) -> Void) throws {
        stop()
        self.onFailure = onFailure; self.onDiagnostics = onDiagnostics
        retried = false
        guard !interrupted else { throw NSError(domain: "iMic.Audio", code: 1) }
        active = true
        do { try build() }
        catch { stop(); throw error }
    }

    private func build() throws {
        epoch &+= 1
        let token = epoch
        noCallbacks = 0; zeroSamples = 0
        measuredAt = now()
        let new = makeHardware()
        hardware = new
        do {
            try new.start(meter: { [weak self] meter in
                self?.queue.async { [weak self] in
                    guard let self, self.epoch == token else { return }
                    self.measure(meter)
                }
            }, failure: { [weak self] message in
                self?.queue.async { [weak self] in
                    guard let self, self.epoch == token else { return }
                    self.invalidate(message)
                }
            })
            identity = new.inputIdentity
            publish(event: retried ? "retry" : "started")
        } catch {
            log("engine start failed: \(error.localizedDescription)")
            publish(event: "start-failed: \(error.localizedDescription)")
            releaseHardware()
            throw error
        }
    }

    /// A fresh hold re-arms the watchdog even when reusing a warm engine. It does
    /// not carry a previous utterance's retry budget or accumulated silence.
    func setMonitoring(_ enabled: Bool) {
        guard monitoring != enabled else { return }
        monitoring = enabled
        measuredAt = now()
        noCallbacks = 0; zeroSamples = 0
        if enabled { retried = false }
    }

    private func measure(_ meter: CaptureMeter) {
        guard let hardware else { return }
        last = hardware.diagnostics
        last.meter = meter
        publish(event: "meter")
        log("level rms=\(meter.rms) peak=\(meter.peak) callbacks=\(meter.callbacks) route=\(last.route) sessionRate=\(last.sampleRate) nativeRate=\(last.nativeRate) channels=\(last.channels) running=\(last.running)")
        guard monitoring else { return }
        guard last.running else {
            log("engine-stopped; cancel current capture")
            invalidate("Microphone configuration changed. Hold again to record.")
            return
        }
        // Clip a report that spans the warm-to-held boundary to this hold's time.
        let time = now()
        let interval = min(meter.elapsed, max(0, time - measuredAt))
        measuredAt = time
        // Native exact zeros only. A tiny nonzero signal resets the zero streak.
        noCallbacks = meter.callbacks == 0 || !meter.hasSamples ? noCallbacks + interval : 0
        zeroSamples = meter.hasSamples && meter.allZero ? zeroSamples + interval : 0
        guard noCallbacks >= 1 || zeroSamples >= 1 else { return }
        let reason = noCallbacks >= 1 ? (meter.callbacks == 0 ? "no-callbacks" : "no-samples") : "digital-zero"
        log("silent-capture reason=\(reason) retry=\(retried)")
        if !retried {
            retried = true
            log("silent-capture retry=1 fresh-engine reactivate-session")
            releaseHardware()
            do { try build() }
            catch { invalidate("No audio received") }
        } else {
            invalidate("No audio received")
        }
    }

    private func receive(_ note: Notification) {
        log("notification=\(note.name.rawValue)")
        if note.name == names.interruption {
            interrupted = names.interruptionBegan(note)
            log("interruption \(interrupted ? "began" : "ended"); no automatic resume")
            if interrupted { invalidate("Microphone interrupted. Hold again to record.") }
            return
        }
        // The app can be suspended while an interruption ends. Foreground permits
        // a NEW user request; it never restarts the old one automatically.
        if note.name == names.foreground || note.name == names.reset { interrupted = false }
        guard let hardware else { return }
        if note.name == names.configuration {
            guard let object = note.object as AnyObject?, object === hardware.notificationObject else { return }
            invalidate("Microphone configuration changed. Hold again to record.")
        } else if note.name == names.route {
            // setCategory/setActive may emit a route notification for our own start.
            // Ignore it only if actual input identity, format and running state agree.
            log("route-change current=\(hardware.inputIdentity) leased=\(identity) running=\(hardware.diagnostics.running)")
            guard hardware.inputIdentity != identity || !hardware.diagnostics.running else { return }
            invalidate("Microphone input changed. Hold again to record.")
        } else if note.name == names.reset {
            invalidate("Microphone services reset. Hold again to record.")
        } else if note.name == names.foreground {
            if !hardware.diagnostics.running || hardware.inputIdentity != identity || !monitoring {
                invalidate("Microphone lease expired. Hold again to record.")
            }
        }
    }

    private func invalidate(_ message: String) {
        guard active else { return }
        log("invalidate event=\(message); release warm lease")
        let failure = onFailure
        stop()
        publish(event: message)
        failure?(message)
    }

    private func publish(event: String) {
        if let hardware {
            let meter = last.meter
            last = hardware.diagnostics
            last.meter = meter
        } else { last.running = false }
        last.attempt = retried ? 1 : 0
        last.event = event
        onDiagnostics?(last)
    }

    private func releaseHardware() {
        epoch &+= 1 // Reject meter/failure callbacks queued during stop/drain.
        guard let old = hardware else { return }
        hardware = nil
        old.stop()
        deactivate()
    }

    func stop() {
        active = false
        releaseHardware()
        monitoring = false
        noCallbacks = 0; zeroSamples = 0
    }

    deinit { for observer in observers { center.removeObserver(observer) } }
}

/// Fences non-realtime PCM delivery when the main-thread owner cancels/replaces a
/// request. Draining the old worker must not feed the next SpeechPreview segment.
final class CaptureDeliveryGate {
    private let lock = NSLock()
    private var open = true
    func deliver(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if open { body() }
    }
    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}
