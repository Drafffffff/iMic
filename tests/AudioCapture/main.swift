import Foundation

let queue = DispatchQueue(label: "capture.tests")
let center = NotificationCenter()
let names = CaptureNotifications(interruption: .init("interruption"), route: .init("route"),
    configuration: .init("config"), reset: .init("reset"), foreground: .init("foreground"),
    interruptionBegan: { $0.userInfo?["began"] as? Bool == true })
var trace: [String] = []
var devices: [FakeHardware] = []
var failures: [String] = []
var snapshots: [CaptureDiagnostics] = []
var clock: TimeInterval = 0
var checks = 0
var failNextStart = false
var startBarrier: (DispatchSemaphore, DispatchSemaphore)?
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError("FAIL: \(message), trace=\(trace)") }
}
final class FakeHardware: CaptureHardware {
    let id: Int
    var running = false
    var route = "built-in:48000:1"
    var meter: ((CaptureMeter) -> Void)?
    var failure: ((String) -> Void)?
    var notificationObject: AnyObject { self }
    var diagnostics: CaptureDiagnostics { CaptureDiagnostics(sampleRate: 48000, nativeRate: 48000, channels: 1, running: running) }
    var inputIdentity: String { route }
    init(_ id: Int) { self.id = id }
    func start(meter: @escaping (CaptureMeter) -> Void, failure: @escaping (String) -> Void) throws {
        trace.append("activate\(id)"); self.meter = meter; self.failure = failure; running = true
        if let barrier = startBarrier {
            startBarrier = nil
            barrier.0.signal()
            barrier.1.wait()
        }
        if failNextStart { failNextStart = false; throw NSError(domain: "test.activation", code: 1) }
    }
    func stop() { trace.append("stop\(id)"); running = false }
}
let controller = AudioCaptureController(queue: queue, center: center, names: names, makeHardware: {
    let device = FakeHardware(devices.count)
    devices.append(device)
    return device
}, deactivate: { trace.append("deactivate") }, log: { trace.append($0) }, now: { clock })
func start(_ monitor: Bool = true) {
    queue.sync {
        try! controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) })
        controller.setMonitoring(monitor)
    }
}
func post(_ name: Notification.Name, object: AnyObject? = nil, began: Bool = false) {
    center.post(name: name, object: object, userInfo: ["began": began])
    queue.sync {}
}
func pulse(callbacks: UInt64 = 50, zero: Bool = false, samples: Bool = true, elapsed: Double = 0.5, peak: Double = 0.01) {
    clock += elapsed
    devices.last!.meter?(CaptureMeter(rms: zero ? 0 : peak, peak: zero ? 0 : peak,
        callbacks: callbacks, hasSamples: samples, allZero: zero, elapsed: elapsed))
    queue.sync {}
}
// Every invalidating notification releases a warm lease, and active holds cancel once.
for warm in [false, true] {
    for event in [names.interruption, names.route, names.configuration, names.reset] {
        start(!warm)
        let device = devices.last!
        let count = failures.count
        if event == names.route { device.route = "headset:44100:2" }
        post(event, object: event == names.configuration ? device : nil, began: true)
        expect(!device.running, "\(event) drops \(warm ? "warm" : "active") engine")
        expect(failures.count == count + 1, "one cancellation for \(event)")
        if event == names.interruption {
            let created = devices.count
            post(event, began: false)
            expect(devices.count == created, "interruption ended must not resume")
        }
    }
}
start()
let unchanged = devices.last!
post(names.route)
expect(unchanged.running, "self-induced unchanged route doesn't cancel")
// A rate-only change is a different input identity.
unchanged.route = "built-in:16000:1"
post(names.route)
expect(!unchanged.running, "rate change invalidates")
start(false)
let warm = devices.last!
post(names.foreground)
expect(!warm.running, "foreground drops unverified warm lease")
start()
let active = devices.last!
post(names.foreground)
expect(active.running, "healthy active capture survives foreground")
active.running = false
post(names.foreground)
expect(failures.last!.contains("lease expired"), "stopped engine detected at foreground")
// A stopped engine cancels, even if its configuration notification is delayed.
start()
let beforeStopped = devices.count
let beforeStoppedFailure = failures.count
devices.last!.running = false
pulse()
expect(devices.count == beforeStopped, "stopped engine never auto-resumes recording")
expect(failures.count == beforeStoppedFailure + 1, "stopped engine cancels the owner")
// Warm lease doesn't retry just because room/simulator is silent.
start(false)
let warmCount = devices.count
for _ in 0..<4 { pulse(zero: true) }
expect(devices.count == warmCount, "warm silence does not consume retry")
queue.sync { controller.setMonitoring(true) }
pulse(zero: true)
expect(devices.count == warmCount, "half second isn't silence timeout")
pulse(zero: true)
expect(devices.count == warmCount + 1, "one fresh engine after full second zeros")
let retry = devices.last!
// Delayed old-engine config/failure/meter cannot cancel the retry.
post(names.configuration, object: devices[devices.count - 2])
devices[devices.count - 2].failure?("stale")
devices[devices.count - 2].meter?(CaptureMeter(callbacks: 0, elapsed: 10))
queue.sync {}
expect(retry.running, "stale callbacks ignored")
let failureCount = failures.count
pulse(zero: true); pulse(zero: true); pulse(zero: true)
expect(devices.count == warmCount + 1, "retry is bounded to one")
expect(failures.count == failureCount + 1 && failures.last == "No audio received", "terminal silence delivered once")
// No callback branch, retry recovery, and tiny native values distinct from zero.
start()
let count = devices.count
pulse(callbacks: 0, samples: false); pulse(callbacks: 0, samples: false)
expect(devices.count == count + 1, "missing callbacks triggers retry")
for _ in 0..<4 { pulse(peak: 1e-12) }
expect(devices.last!.running, "tiny nonzero input must not be silent")
pulse(zero: true); pulse(peak: 1e-12); pulse(zero: true)
expect(devices.last!.running, "nonzero resets consecutive silence")
queue.sync { controller.setMonitoring(false); controller.setMonitoring(true) }
pulse(zero: true); pulse(zero: true)
expect(devices.count == count + 2, "new hold has its own retry budget")
// Stop/start ordering is the actual production serial queue, not a shadow policy.
let old = devices.last!
queue.async { controller.stop() }
queue.async { try! controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
queue.sync {}
let fresh = devices.last!
old.failure?("old-generation")
queue.sync {}
expect(fresh.running, "old failure cannot stop next request")
let lastActivation = trace.lastIndex(of: "activate\(fresh.id)")!
expect(!trace.suffix(from: lastActivation).contains("deactivate"), "no old deactivation after new activation")
expect(snapshots.contains { $0.meter.peak == 1e-12 && $0.running }, "diagnostics carry native levels and engine health")
// Hold hardware activation in flight while stop/new-start arrive from the owner.
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
startBarrier = (entered, release)
queue.async { try! controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
expect(entered.wait(timeout: .now() + 5) == .success, "fake activation is in flight")
queue.async { controller.stop() }
queue.async { try! controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
release.signal()
queue.sync {}
expect(devices.last!.running, "stop/start queued during activation ends in new live engine")
let activation = trace.lastIndex(of: "activate\(devices.last!.id)")!
expect(!trace.suffix(from: activation).contains("deactivate"), "blocked old start cannot deactivate new one")
// Do not count a warm report's pre-hold time toward the one-second deadline.
start(false)
queue.sync { controller.setMonitoring(true) }
let boundaryCount = devices.count
clock += 0.01
devices.last!.meter?(CaptureMeter(callbacks: 20, hasSamples: true, allZero: true, elapsed: 0.5))
queue.sync {}
pulse(zero: true)
expect(devices.count == boundaryCount, "warm report clipped to actual held duration")
pulse(zero: true)
expect(devices.count == boundaryCount + 1, "retry after full held second")
// A retry that fails during activation must still cancel the owner, even though
// teardown has already cleared the hardware reference.
start()
let beforeRetryFailure = failures.count
failNextStart = true
pulse(zero: true); pulse(zero: true)
expect(failures.count == beforeRetryFailure + 1 && failures.last == "No audio received", "retry startup failure is terminal")
expect(!devices.last!.running, "failed retry released its hardware")
// Pending user requests during an interruption fail without reactivation.
start()
post(names.interruption, began: true)
let beforeBlocked = devices.count
queue.sync {
    do {
        try controller.start(onFailure: { _ in }, onDiagnostics: { _ in })
        fatalError("interrupted start unexpectedly succeeded")
    } catch {}
}
expect(devices.count == beforeBlocked, "no engine activation inside interruption")
post(names.foreground)
start()
expect(devices.last!.running, "foreground allows new hold if ended notification was missed")
queue.sync { controller.stop() }
let oldGate = CaptureDeliveryGate()
var delivered = 0
oldGate.deliver { delivered += 1 }
oldGate.close()
let newGate = CaptureDeliveryGate()
oldGate.deliver { delivered += 100 }
newGate.deliver { delivered += 1 }
expect(delivered == 2, "drained old buffers cannot feed a new speech segment")
print("PASS: \(checks) capture assertions (notifications, warm leases, native silence, bounded retry, generations)")
