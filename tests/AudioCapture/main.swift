import Foundation

let queue = DispatchQueue(label: "capture.tests")
let center = NotificationCenter()
let names = CaptureNotifications(interruption: .init("interruption"), route: .init("route"),
    configuration: .init("config"), reset: .init("reset"), foreground: .init("foreground"),
    interruptionBegan: { $0.userInfo?["began"] as? Bool == true },
    oldDeviceUnavailable: { $0.userInfo?["oldDevice"] as? Bool == true })
let builtIn = CaptureInputPort(uid: "built-in", type: "MicrophoneBuiltIn", name: "Phone mic")
let validRoute = CaptureInputRoute(inputs: [builtIn], available: [builtIn])
let emptyRoute = CaptureInputRoute(inputs: [], available: [builtIn])
let orphanRoute = CaptureInputRoute(inputs: [CaptureInputPort(uid: "gone", type: "BluetoothHFP", name: "Gone headset")], available: [builtIn])
var nextInputRoute: CaptureInputRoute?
var routeAfterRebuild = CaptureInputRoute(inputs: [builtIn], available: [builtIn])
var rebuilds = 0
var failRebuild = false
var deactivationOptions: [Bool] = []
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
    var inputRoute = validRoute
    var meter: ((CaptureMeter) -> Void)?
    var failure: ((String) -> Void)?
    var notificationObject: AnyObject { self }
    var diagnostics: CaptureDiagnostics { CaptureDiagnostics(sampleRate: 48000, nativeRate: 48000, channels: 1, running: running, inputRoute: inputRoute) }
    var inputIdentity: String { route }
    init(_ id: Int) { self.id = id }
    func start(meter: @escaping (CaptureMeter) -> Void, failure: @escaping (String) -> Void) throws {
        trace.append("activate\(id)"); self.meter = meter; self.failure = failure; running = true
        if let barrier = startBarrier {
            startBarrier = nil
            barrier.0.signal()
            barrier.1.wait()
        }
        if inputRoute.invalidReason != nil { throw CaptureRouteError.invalidInputRoute }
        if failNextStart { failNextStart = false; throw NSError(domain: "test.activation", code: 1) }
    }
    func stop() { trace.append("stop\(id)"); running = false }
}
let controller = AudioCaptureController(queue: queue, center: center, names: names, makeHardware: {
    let device = FakeHardware(devices.count)
    if let route = nextInputRoute { device.inputRoute = route; nextInputRoute = nil }
    devices.append(device)
    return device
}, deactivate: { notify in trace.append("deactivate"); deactivationOptions.append(notify) }, rebuildRoute: {
    rebuilds += 1
    trace.append("playback-mixing-no-audio")
    if failRebuild { throw NSError(domain: "test.playback", code: 1) }
    nextInputRoute = routeAfterRebuild
}, log: { trace.append($0) }, now: { clock })
func start(_ monitor: Bool = true) {
    queue.sync {
        try! controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) })
        controller.setMonitoring(monitor)
    }
}
func post(_ name: Notification.Name, object: AnyObject? = nil, began: Bool = false, oldDevice: Bool = false) {
    center.post(name: name, object: object, userInfo: ["began": began, "oldDevice": oldDevice])
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
expect(failures.count == failureCount + 1 && failures.last == CaptureRouteError.message, "terminal silence delivered once")
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
expect(failures.count == beforeRetryFailure + 1 && failures.last == CaptureRouteError.message, "retry startup failure is terminal")
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
let beforeHealthyStart = rebuilds
start()
expect(rebuilds == beforeHealthyStart, "healthy initial input does not enter playback")
// Pure validation uses stable UID + port type, not the display name.
expect(emptyRoute.invalidReason == "empty-input-route", "empty active route rejected")
expect(orphanRoute.invalidReason == "input-port-no-longer-available", "orphan UID rejected")
expect(CaptureInputRoute(inputs: [builtIn], available: nil).invalidReason != nil, "nil availableInputs is not evidence of validity")
expect(CaptureInputRoute(inputs: [builtIn], available: []).invalidReason != nil, "empty available list rejected")
var renamed = builtIn; renamed.name = "Renamed mic"
expect(CaptureInputRoute(inputs: [builtIn], available: [renamed]).invalidReason == nil, "display name change keeps valid UID")
var wrongType = builtIn; wrongType.type = "USB"
expect(CaptureInputRoute(inputs: [builtIn], available: [wrongType]).invalidReason != nil, "same UID with wrong port type rejected")
for fault in [emptyRoute, orphanRoute] {
    let before = rebuilds
    nextInputRoute = fault
    start()
    expect(rebuilds == before + 1 && devices.last!.running, "invalid startup route recovered once")
    expect(snapshots.last!.attempt == 1 && snapshots.last!.recoveryResult == .awaitingSignal, "route validity doesn't claim signal success")
    expect(deactivationOptions.last == false, "intermediate deactivate doesn't notify other apps")
    let playback = trace.lastIndex(of: "playback-mixing-no-audio")!
    expect(trace[playback - 1] == "deactivate" && trace[playback - 2].hasPrefix("stop") && trace[playback + 1].hasPrefix("activate"), "old engine stops before playback, fresh capture starts afterward")
    queue.sync { controller.setMonitoring(true) }
    expect(!queue.sync { controller.recoverManually() }, "initial monitor arm cannot reset startup recovery budget")
    pulse(zero: true); pulse(zero: true)
    expect(rebuilds == before + 1 && failures.last == CaptureRouteError.message, "startup route and silence share one recovery")
    expect(snapshots.last!.recoveryResult == .failed, "failed verification recorded")
}
start()
let beforeSignal = rebuilds
pulse(zero: true); pulse(zero: true)
expect(rebuilds == beforeSignal + 1, "silence uses playback route recovery")
pulse()
expect(snapshots.last!.recoveryResult == .signalDetected, "nonzero native sample verifies recovery signal")
expect(!queue.sync { controller.recoverManually() }, "manual cannot get a second recovery after silence")
// Deliberate manual rebuild after an exhausted run starts a fresh test and
// spends that new test's sole budget before any ordinary engine start.
let explicitManual = rebuilds
queue.sync { try! controller.start(rebuildFirst: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }); controller.setMonitoring(true) }
expect(rebuilds == explicitManual + 1 && snapshots.last!.attempt == 1, "explicit new manual test recovers once")
pulse(zero: true); pulse(zero: true)
expect(rebuilds == explicitManual + 1 && failures.last == CaptureRouteError.message, "new manual test cannot follow with an automatic second recovery")
// A truly invalid replacement after recovery is terminal, not another recovery.
for playbackFails in [false, true] {
    nextInputRoute = emptyRoute
    routeAfterRebuild = emptyRoute
    failRebuild = playbackFails
    let before = rebuilds
    var error: Error?
    queue.sync {
        do { try controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
        catch let caught { error = caught }
        controller.setMonitoring(true)
    }
    expect(error is CaptureRouteError && rebuilds == before + 1, "failed playback/revalidation terminates startup")
    expect(snapshots.last!.recoveryResult == .failed && !snapshots.last!.running, "failed recovery diagnostics stopped")
    expect(!queue.sync { controller.recoverManually() }, "failed recovery cannot loop manually")
}
failRebuild = false
routeAfterRebuild = validRoute
nextInputRoute = nil
start()
let manualBefore = rebuilds
pulse()
expect(queue.sync { controller.recoverManually() }, "MIC TEST manual rebuild accepted")
expect(rebuilds == manualBefore + 1, "manual rebuild executes playback exactly once")
expect(snapshots.last!.meter.peak == 0 && snapshots.last!.recoveryResult == .awaitingSignal, "rebuild clears stale levels before verification")
expect(!queue.sync { controller.recoverManually() }, "manual button is bounded")
pulse(zero: true); pulse(zero: true)
expect(rebuilds == manualBefore + 1 && failures.last == CaptureRouteError.message, "manual and silence share budget")
// Manual rebuild remains usable after a non-route startup/format failure.
failNextStart = true
queue.sync {
    do { try controller.start(onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
    catch {}
}
let afterFormatFailure = rebuilds
expect(queue.sync { controller.recoverManually() }, "MIC TEST manual after failed start accepted")
expect(rebuilds == afterFormatFailure + 1 && devices.last!.running, "manual after failed start creates new engine")
start()
let oldDeviceBefore = rebuilds
devices.last!.inputRoute = orphanRoute
post(names.route, oldDevice: true)
expect(rebuilds == oldDeviceBefore + 1 && devices.last!.running, "oldDeviceUnavailable rereads invalid route and recovers")
expect(trace.contains { $0.contains("reason=old-device-unavailable") }, "old-device reason logged")
start()
let healthyDisconnect = rebuilds
post(names.route, oldDevice: true)
expect(rebuilds == healthyDisconnect && devices.last!.running, "healthy current input doesn't need playback after output disconnect")
start(false)
let coldBefore = rebuilds
devices.last!.inputRoute = emptyRoute
post(names.route, oldDevice: true)
expect(rebuilds == coldBefore && !devices.last!.running, "invalid warm lease is released without unattended playback")
start(false)
devices.last!.inputRoute = emptyRoute
queue.sync { controller.setMonitoring(true) }
expect(rebuilds == coldBefore + 1 && devices.last!.running, "new hold validates warm route immediately")
expect(snapshots.last!.report.contains("availableInputs=") && snapshots.last!.report.contains("recoveries=1") && snapshots.last!.report.contains("recoveryResult="), "copy report includes route, inventory, recovery count/result")
start()
queue.sync { controller.stop() }
let afterExplicitStop = rebuilds
expect(!queue.sync { controller.recoverManually() } && rebuilds == afterExplicitStop, "closed/background self-test cannot be revived by a late manual request")
let oldGate = CaptureDeliveryGate()
var delivered = 0
oldGate.deliver { delivered += 1 }
oldGate.close()
let newGate = CaptureDeliveryGate()
oldGate.deliver { delivered += 100 }
newGate.deliver { delivered += 1 }
expect(delivered == 2, "drained old buffers cannot feed a new speech segment")
print("PASS: \(checks) capture assertions (route validation/recovery, shared budget, notifications, warm leases, native silence, generations)")
