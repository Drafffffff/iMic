import Foundation

let queue = DispatchQueue(label: "capture.tests")
let center = NotificationCenter()
let names = CaptureNotifications(interruption: .init("interruption"), route: .init("route"),
    configuration: .init("config"), reset: .init("reset"), foreground: .init("foreground"),
    interruptionBegan: { $0.userInfo?["began"] as? Bool == true },
    oldDeviceUnavailable: { $0.userInfo?["oldDevice"] as? Bool == true },
    routeReason: { $0.userInfo?["reason"] as? String ?? "unknown" },
    previousInputs: { $0.userInfo?["previousInputs"] as? [CaptureInputPort] ?? [] })
let builtIn = CaptureInputPort(uid: "built-in", type: "MicrophoneBuiltIn", name: "Phone mic")
let headset = CaptureInputPort(uid: "headset", type: "BluetoothHFP", name: "Headset mic")
let headsetRoute = CaptureInputRoute(inputs: [headset], available: [headset, builtIn])
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
var vpioRecoveries = 0
var startBarrier: (DispatchSemaphore, DispatchSemaphore)?
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError("FAIL: \(message), trace=\(trace)") }
}
final class FakeHardware: CaptureHardware {
    let id: Int
    var running = false
    var voiceProcessing = true
    var sampleRate: Double = 48000
    var sessionChannels = 1
    var nativeRate: Double = 48000
    var channels: UInt32 = 1
    var inputFormatAvailable = true
    var inputRoute = validRoute
    var meter: ((CaptureMeter) -> Void)?
    var failure: ((String) -> Void)?
    var notificationObject: AnyObject { self }
    var diagnostics: CaptureDiagnostics { CaptureDiagnostics(sampleRate: sampleRate, sessionChannels: sessionChannels, nativeRate: nativeRate, channels: channels, running: running, inputRoute: inputRoute, voiceProcessing: voiceProcessing, mode: voiceProcessing ? "voiceChat" : "measurement") }
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
let controller = AudioCaptureController(queue: queue, center: center, names: names, makeHardware: { vpio in
    let device = FakeHardware(devices.count)
    device.voiceProcessing = vpio
    if let route = nextInputRoute { device.inputRoute = route; nextInputRoute = nil }
    devices.append(device)
    return device
}, deactivate: { notify in trace.append("deactivate"); deactivationOptions.append(notify) }, rebuildRoute: {
    rebuilds += 1
    trace.append("playback-mixing-no-audio")
    if failRebuild { throw NSError(domain: "test.playback", code: 1) }
    nextInputRoute = routeAfterRebuild
}, log: { trace.append($0) }, now: { clock })
func start(_ monitor: Bool = true, vpio: Bool = true, microphoneTest: Bool = true) {
    queue.sync {
        try! controller.start(voiceProcessing: vpio, microphoneTest: microphoneTest, onVoiceProcessingRecovered: { vpioRecoveries += 1 }, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) })
        controller.setMonitoring(monitor)
    }
}
func post(_ name: Notification.Name, object: AnyObject? = nil, began: Bool = false, oldDevice: Bool = false, reason: String = "unknown", previousInputs: [CaptureInputPort] = []) {
    center.post(name: name, object: object, userInfo: ["began": began, "oldDevice": oldDevice || reason == "oldDeviceUnavailable", "reason": reason, "previousInputs": previousInputs])
    queue.sync {}
}
func pulse(callbacks: UInt64 = 50, zero: Bool = false, samples: Bool = true, elapsed: Double = 0.5, peak: Double = 0.01, rms: Double? = nil) {
    clock += elapsed
    devices.last!.meter?(CaptureMeter(rms: zero ? 0 : (rms ?? peak), peak: zero ? 0 : peak,
        callbacks: callbacks, hasSamples: samples, allZero: zero, elapsed: elapsed))
    queue.sync {}
}
// Every invalidating notification releases a warm lease, and active holds cancel once.
for warm in [false, true] {
    for event in [names.interruption, names.route, names.reset] {
        start(!warm)
        let device = devices.last!
        let count = failures.count
        if event == names.route { device.inputRoute = headsetRoute }
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
// Session format metadata is NOT physical device identity.
unchanged.sampleRate = 24000
unchanged.sessionChannels = 3
post(names.route)
expect(unchanged.running, "same mic survives rate/channel metadata change")
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
// A meter report also recovers a stopped engine if its config notification is delayed.
start()
let beforeStopped = devices.count
let beforeStoppedFailure = failures.count
devices.last!.running = false
pulse()
expect(devices.count == beforeStopped + 1 && devices.last!.running, "stopped engine is rebuilt once within the active hold")
expect(failures.count == beforeStoppedFailure, "recoverable engine stop preserves current hold")
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
expect(snapshots.last!.recoveryResult == .lowLevel, "tiny nonzero recovery remains lowLevel")
expect(devices.last!.running, "MIC TEST keeps low nonzero input visible for comparison")
pulse(zero: true); pulse(peak: 1e-12); pulse(zero: true)
expect(devices.last!.running, "nonzero resets consecutive silence")
queue.sync { controller.setMonitoring(false); controller.setMonitoring(true) }
pulse(zero: true); pulse(zero: true)
expect(devices.count == count + 2, "new hold has its own retry budget")
// Stop/start ordering is the actual production serial queue, not a shadow policy.
let old = devices.last!
queue.async { controller.stop() }
queue.async { try! controller.start(microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
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
queue.async { try! controller.start(microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
expect(entered.wait(timeout: .now() + 5) == .success, "fake activation is in flight")
queue.async { controller.stop() }
queue.async { try! controller.start(microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
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
        try controller.start(microphoneTest: true, onFailure: { _ in }, onDiagnostics: { _ in })
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
expect(snapshots.last!.recoveryResult == .signalDetected, "normal-level native sample verifies recovery signal")
expect(!queue.sync { controller.recoverManually() }, "manual cannot get a second recovery after silence")
// Deliberate manual rebuild after an exhausted run starts a fresh test and
// spends that new test's sole budget before any ordinary engine start.
let explicitManual = rebuilds
queue.sync { try! controller.start(rebuildFirst: true, microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }); controller.setMonitoring(true) }
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
        do { try controller.start(microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
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
    do { try controller.start(microphoneTest: true, onFailure: { failures.append($0) }, onDiagnostics: { snapshots.append($0) }) }
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
// Regression: VPIO often changes SESSION rate/channels without changing input.
// Check every route reason, including the three self-induced causes, and raw mode.
let routeReasons = ["unknown", "newDeviceAvailable", "oldDeviceUnavailable", "categoryChange",
                    "override", "wakeFromSleep", "noSuitableRouteForCategory", "routeConfigurationChange"]
for vpio in [true, false] {
    for reason in routeReasons {
        start(vpio: vpio, microphoneTest: false)
        pulse()
        let device = devices.last!
        let created = devices.count
        let failed = failures.count
        let attempts = rebuilds
        device.sampleRate = 24000 // was 48000
        device.sessionChannels = 3 // was 1
        post(names.route, reason: reason, previousInputs: [builtIn])
        expect(device.running && devices.count == created && failures.count == failed, "\(reason) same-port session format change never cancels VPIO=\(vpio)")
        expect(rebuilds == attempts && snapshots.last!.attempt == 0, "healthy same-port route doesn't consume recovery budget")
        expect(snapshots.last!.sampleRate == 24000 && snapshots.last!.sessionChannels == 3, "format metadata remains visible without waiting for next callback")
        device.nativeRate = 24000
        device.channels = 3
        post(names.configuration, object: device)
        expect(device.running && devices.count == created && failures.count == failed, "running graph with valid changed format survives config notification")
        pulse()
        expect(snapshots.last!.meter.callbacks > 0 && snapshots.last!.running && snapshots.last!.nativeRate == 24000 && snapshots.last!.channels == 3, "same engine continues callbacks and reports new format")
    }
}
start(microphoneTest: false)
let foregroundMetadata = devices.last!
foregroundMetadata.sampleRate = 24000
foregroundMetadata.sessionChannels = 3
post(names.foreground)
expect(foregroundMetadata.running, "foreground identity also ignores sample-rate/channel metadata")
// Benign notifications don't reset the timer or grant another recovery budget.
start()
let routeStormRebuilds = rebuilds
pulse(zero: true)
for reason in routeReasons { post(names.route, reason: reason) }
pulse(zero: true)
expect(rebuilds == routeStormRebuilds + 1, "same-port notifications cannot indefinitely postpone silence detection")
pulse(zero: true)
for reason in routeReasons { post(names.route, reason: reason) }
pulse(zero: true)
expect(rebuilds == routeStormRebuilds + 1 && !devices.last!.running, "same-port notification storm cannot reset spent recovery budget")
// Identity is an unordered set of UID + type, never a display name or delimiter string.
nextInputRoute = CaptureInputRoute(inputs: [builtIn, headset], available: [builtIn, headset])
start()
let multiple = devices.last!
var renamedHeadset = headset; renamedHeadset.name = "New display name"
multiple.inputRoute = CaptureInputRoute(inputs: [renamedHeadset, builtIn, builtIn], available: [builtIn, headset])
let beforeReorder = failures.count
post(names.route, reason: "routeConfigurationChange")
expect(multiple.running && failures.count == beforeReorder, "input order, duplicate descriptors and names don't change device set")
for reason in ["newDeviceAvailable", "categoryChange", "override", "routeConfigurationChange"] {
    start()
    pulse()
    let switched = devices.last!
    let failed = failures.count
    let before = rebuilds
    switched.inputRoute = headsetRoute
    post(names.route, reason: reason)
    expect(!switched.running && failures.count == failed + 1 && failures.last == "Microphone input changed. Hold again to record.", "genuine built-in to Bluetooth UID change still cancels for \(reason)")
    expect(rebuilds == before, "new input selection never silently continues old capture")
}
start()
let changedType = devices.last!
var alternateType = builtIn; alternateType.type = "USB"
changedType.inputRoute = CaptureInputRoute(inputs: [alternateType], available: [alternateType])
post(names.route)
expect(!changedType.running, "same UID but changed port type is a device change")
// An INPUT disconnect can already have fallen back to a healthy built-in mic.
nextInputRoute = headsetRoute
start()
let disconnected = devices.last!
let beforeDisconnect = rebuilds
let beforeDisconnectFailure = failures.count
disconnected.inputRoute = validRoute
post(names.route, reason: "oldDeviceUnavailable", previousInputs: [headset])
expect(rebuilds == beforeDisconnect + 1 && devices.last!.running && failures.count == beforeDisconnectFailure, "lost leased headset input recovers once onto available built-in input")
let replacement = devices.last!
post(names.route, reason: "oldDeviceUnavailable", previousInputs: [headset])
post(names.configuration, object: disconnected)
expect(devices.last === replacement && replacement.running && rebuilds == beforeDisconnect + 1, "delayed old disconnect/config notification cannot spend a second budget")
start()
let outputDisconnect = rebuilds
post(names.route, reason: "oldDeviceUnavailable", previousInputs: [builtIn])
expect(devices.last!.running && rebuilds == outputDisconnect, "output-only disconnect with unchanged input isn't input loss")
start()
let unrelatedPrevious = devices.last!
let unrelatedRebuilds = rebuilds
unrelatedPrevious.inputRoute = headsetRoute
post(names.route, reason: "oldDeviceUnavailable", previousInputs: [headset])
expect(!unrelatedPrevious.running && rebuilds == unrelatedRebuilds, "unavailable previous input must belong to leased input before auto recovery")
// Configuration changes only recover an actually stopped/unusable graph.
for vpio in [true, false] {
    for stopped in [true, false] {
        start(vpio: vpio, microphoneTest: false)
        pulse()
        let broken = devices.last!
        let created = devices.count
        let before = rebuilds
        let failed = failures.count
        if stopped { broken.running = false } else { broken.inputFormatAvailable = false }
        post(names.configuration, object: broken)
        expect(devices.count == created + 1 && rebuilds == before + 1 && devices.last!.running, "stopped=\(stopped) VPIO=\(vpio) config loss rebuilds once")
        expect(failures.count == failed && snapshots.last!.attempt == 1 && snapshots.last!.recoveryResult == .awaitingSignal, "configuration recovery preserves hold and waits for signal")
        expect(devices.last!.voiceProcessing == vpio, "configuration recovery retains VPIO selection")
        broken.failure?("stale graph failure")
        broken.meter?(CaptureMeter(callbacks: 0, elapsed: 10))
        queue.sync {}
        post(names.configuration, object: broken)
        post(names.configuration, object: devices.last!)
        expect(devices.count == created + 1 && failures.count == failed, "old callbacks and healthy new config cannot cancel recovered engine")
        pulse()
        expect(snapshots.last!.recoveryResult == .signalDetected, "new callback confirms real config recovery")
        devices.last!.running = false
        post(names.configuration, object: devices.last!)
        expect(devices.count == created + 1 && failures.count == failed + 1 && !devices.last!.running, "second config failure is terminal, no loop")
    }
}
// A healthy warm graph survives config metadata, but idle broken graphs never restart.
for stopped in [true, false] {
    start(false)
    let idle = devices.last!
    let before = rebuilds
    post(names.configuration, object: idle)
    expect(idle.running && rebuilds == before, "healthy warm config doesn't expire lease")
    if stopped { idle.running = false } else { idle.inputFormatAvailable = false }
    post(names.configuration, object: idle)
    expect(!idle.running && rebuilds == before, "broken warm config drops lease without unattended recovery")
}
start(false)
let invalidWarmConfig = devices.last!
let invalidWarmRebuilds = rebuilds
invalidWarmConfig.inputRoute = emptyRoute
post(names.configuration, object: invalidWarmConfig)
expect(!invalidWarmConfig.running && rebuilds == invalidWarmRebuilds, "invalid warm input on config notification releases without restart")
start()
let invalidActiveConfig = devices.last!
let invalidActiveRebuilds = rebuilds
invalidActiveConfig.inputRoute = emptyRoute
post(names.configuration, object: invalidActiveConfig)
expect(devices.last!.running && rebuilds == invalidActiveRebuilds + 1, "invalid active route on config notification retains #27 recovery")
start()
let pendingConfig = devices.last!
let pendingFailure = failures.count
let pendingRebuild = rebuilds
pendingConfig.running = false
post(names.route, reason: "categoryChange")
expect(failures.count == pendingFailure && rebuilds == pendingRebuild, "same-port route only logs; actual graph loss belongs to config/watchdog")
post(names.configuration, object: pendingConfig)
expect(devices.last!.running && rebuilds == pendingRebuild + 1, "subsequent config recovers stopped graph")
// Config recovery shares the SAME hold budget with every existing recovery cause.
for cause in ["zeros", "invalid-route", "manual", "low-level"] {
    start(vpio: cause != "low-level", microphoneTest: cause != "low-level")
    devices.last!.running = false
    post(names.configuration, object: devices.last!)
    let created = devices.count
    let before = rebuilds
    let failed = failures.count
    switch cause {
    case "zeros": pulse(zero: true); pulse(zero: true)
    case "invalid-route": devices.last!.inputRoute = emptyRoute; post(names.route)
    case "manual": expect(!queue.sync { controller.recoverManually() }, "manual cannot reset config recovery budget")
    default: for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
    }
    expect(devices.count == created && rebuilds == before, "config then \(cause) cannot recover twice")
    if cause != "manual" { expect(failures.count == failed + 1, "exhausted \(cause) fails once") }
}
start(vpio: false, microphoneTest: false)
for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
let fallbackBudget = devices.count
devices.last!.running = false
post(names.configuration, object: devices.last!)
expect(devices.count == fallbackBudget && !devices.last!.running, "VPIO fallback and config recovery share one budget in reverse order")
start()
let configFailureCount = failures.count
failNextStart = true
devices.last!.running = false
post(names.configuration, object: devices.last!)
expect(failures.count == configFailureCount + 1 && !devices.last!.running, "config recovery activation failure stops and notifies once")
let closedEngine = devices.last!
queue.sync { controller.stop() }
let afterClosedConfig = devices.count
post(names.configuration, object: closedEngine)
expect(devices.count == afterClosedConfig, "late config notification cannot restart explicitly closed capture")
// VPIO startup ordering is shared with the actual AVAudioEngine adapter.
for vpio in [false, true] {
    var steps: [String] = []
    let format: Int = try! CaptureStartup.prepare(voiceProcessing: vpio,
        configureSession: { config in
            expect(config.mode == (vpio ? .voiceChat : .measurement), "VPIO selects voiceChat; raw keeps measurement")
            expect(config.defaultToSpeaker && config.automaticGain && !config.bypass && !config.advancedDucking, "speaker policy, AGC, AEC and minimal ducking policy")
            steps.append(config.mode == .voiceChat ? "voiceChat" : "measurement")
        },
        activate: { steps.append("activate") },
        enableVoiceProcessing: { steps.append("enable-vpio") },
        configureProcessing: { _ in steps.append("AGC-AEC-min-ducking") },
        readFormat: { steps.append("actual-format"); return vpio ? 48000 : 16000 })
    expect(steps == (vpio ? ["voiceChat", "activate", "enable-vpio", "AGC-AEC-min-ducking", "actual-format"] : ["measurement", "activate", "actual-format"]), "configure and activate before VPIO, actual format after processing")
    expect(format == (vpio ? 48000 : 16000), "uses post-VPIO actual format")
}
var readAfterEnableFailure = false
do {
    _ = try CaptureStartup.prepare(voiceProcessing: true, configureSession: { _ in }, activate: {},
        enableVoiceProcessing: { throw NSError(domain: "vpio", code: 1) }, configureProcessing: { _ in },
        readFormat: { readAfterEnableFailure = true })
} catch {}
expect(!readAfterEnableFailure, "VPIO failure propagates instead of silently using raw input")
let suite = "imic.vpio-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
expect(VoiceProcessingPreference.enabled(in: defaults), "new and existing installations default on")
defaults.set(false, forKey: "micDebug.voiceProcessing")
expect(VoiceProcessingPreference.enabled(in: defaults), "legacy diagnostic OFF key ignored")
defaults.set(false, forKey: VoiceProcessingPreference.key)
expect(!VoiceProcessingPreference.enabled(in: defaults), "explicit new preference OFF retained")
var comparison = MicrophoneTestProcessing(defaults: defaults)
comparison.toggle()
expect(comparison.enabled && !VoiceProcessingPreference.enabled(in: defaults), "MIC TEST temporary ON doesn't write saved OFF")
comparison.toggle()
expect(!comparison.enabled, "MIC TEST toggles both directions")
defaults.set(true, forKey: VoiceProcessingPreference.key)
comparison = MicrophoneTestProcessing(defaults: defaults)
comparison.toggle()
expect(!comparison.enabled && VoiceProcessingPreference.enabled(in: defaults), "MIC TEST temporary OFF doesn't write saved ON")
expect(MicrophoneTestProcessing(defaults: defaults).enabled, "leaving test restores saved value on next entry")
defaults.removePersistentDomain(forName: suite)
expect(CaptureLevel.classify(CaptureMeter(rms: 0.0002, peak: 0.0008, callbacks: 10, hasSamples: true)) == .lowLevel, "field nonzero noise classified low")
expect(CaptureLevel.classify(CaptureMeter(rms: 0.001, peak: 0.002, callbacks: 10, hasSamples: true)) == .normal, "RMS threshold is strict")
expect(CaptureLevel.classify(CaptureMeter(rms: 0.0005, peak: 0.003, callbacks: 10, hasSamples: true)) == .normal, "peak threshold is strict")
expect(CaptureLevel.classify(CaptureMeter(callbacks: 10, hasSamples: true, allZero: true)) == .allZero, "digital zero distinct from low nonzero")
start(vpio: false, microphoneTest: false)
let rawDevices = devices.count
let rawPlayback = rebuilds
let recoveredBefore = vpioRecoveries
pulse(peak: 0.0008, rms: 0.0002); pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == rawDevices, "one second low nonzero doesn't trigger early")
pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == rawDevices + 1 && devices.last!.voiceProcessing, "1.5 seconds nearly silent raw switches to VPIO")
expect(rebuilds == rawPlayback && snapshots.last!.attempt == 1, "VPIO path switch uses shared budget without playback kick")
pulse(peak: 0.0008, rms: 0.0002)
expect(snapshots.last!.recoveryResult == .lowLevel && vpioRecoveries == recoveredBefore, "noise floor never claims restored signal or persists setting")
pulse()
expect(snapshots.last!.recoveryResult == .signalDetected && vpioRecoveries == recoveredBefore + 1, "normal VPIO level confirms fallback exactly once")
pulse()
expect(vpioRecoveries == recoveredBefore + 1, "recovered notification fires once")
expect(!queue.sync { controller.recoverManually() }, "fallback consumes same manual/route recovery budget")
// Rebuild current VPIO profile, including explicit raw comparison.
for vpio in [false, true] {
    start(vpio: vpio)
    expect(queue.sync { controller.recoverManually() }, "manual route rebuild accepted")
    expect(devices.last!.voiceProcessing == vpio, "route rebuild preserves selected VPIO configuration")
}
start(vpio: false, microphoneTest: false)
pulse()
let spokeDevices = devices.count
for _ in 0..<5 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == spokeDevices && devices.last!.running, "normal input followed by quiet pause doesn't trigger fallback")
start(false, vpio: false, microphoneTest: false)
let idleDevices = devices.count
for _ in 0..<5 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == idleDevices, "warm lease low input doesn't trigger fallback")
queue.sync { controller.setMonitoring(true) }
pulse(peak: 0.0008, rms: 0.0002); pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == idleDevices, "warm low history doesn't shorten hold timer")
pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == idleDevices + 1, "fresh hold low duration triggers fallback")
let beforeWarmConfirmation = vpioRecoveries
queue.sync { controller.setMonitoring(false) }
pulse()
expect(vpioRecoveries == beforeWarmConfirmation, "post-release normal input cannot persist fallback preference")
start(vpio: false)
let comparisonDevices = devices.count
for _ in 0..<5 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == comparisonDevices && !devices.last!.voiceProcessing, "MIC TEST keeps temporary raw low input for comparison")
start(false, vpio: false, microphoneTest: false)
queue.sync { controller.setMonitoring(true) }
let lowBoundary = devices.count
clock += 0.01
devices.last!.meter?(CaptureMeter(rms: 0.0002, peak: 0.0008, callbacks: 50, hasSamples: true, elapsed: 0.5))
queue.sync {}
pulse(peak: 0.0008, rms: 0.0002); pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == lowBoundary, "low watchdog clips warm report to actual held time")
pulse(peak: 0.0008, rms: 0.0002)
expect(devices.count == lowBoundary + 1, "low fallback after full held 1.5 seconds")
start(vpio: true, microphoneTest: false)
let vpioDevices = devices.count
for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == vpioDevices && !devices.last!.running && failures.last == AudioCaptureController.noAudioMessage, "VPIO low input fails clearly without repeated recovery")
expect(snapshots.last!.recoveryResult == .lowLevel, "terminal low remains distinct from signalDetected")
start(vpio: false, microphoneTest: false)
failNextStart = true
for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
expect(!devices.last!.running && failures.last == AudioCaptureController.noAudioMessage, "fallback activation failure stops and reports no audio")
nextInputRoute = emptyRoute
start(vpio: false, microphoneTest: false)
let usedRouteBudget = devices.count
for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == usedRouteBudget && !devices.last!.running, "route recovery exhausts budget before later low-level fallback")
start(vpio: false, microphoneTest: false)
pulse(zero: true); pulse(zero: true)
expect(devices.last!.voiceProcessing && snapshots.last!.attempt == 1, "raw exact-zero recovery uses VPIO and same budget")
let zeroBudget = devices.count
for _ in 0..<3 { pulse(peak: 0.0008, rms: 0.0002) }
expect(devices.count == zeroBudget && !devices.last!.running, "fallback still-low cannot loop")
expect(snapshots.last!.report.contains("vpio=on") && snapshots.last!.report.contains("mode=voiceChat") && snapshots.last!.report.contains("ducking=") && snapshots.last!.report.contains("level=lowLevel"), "diagnostic copy includes VPIO, mode, format, ducking and classification")
let oldGate = CaptureDeliveryGate()
var delivered = 0
oldGate.deliver { delivered += 1 }
oldGate.close()
let newGate = CaptureDeliveryGate()
oldGate.deliver { delivered += 100 }
newGate.deliver { delivered += 1 }
expect(delivered == 2, "drained old buffers cannot feed a new speech segment")
print("PASS: \(checks) capture assertions (route validation/recovery, shared budget, notifications, warm leases, native silence, generations, VPIO configuration/fallback/preferences/comparison, same-port route/config recovery)")
