import Foundation
import Network
import Darwin
setbuf(stdout, nil)
final class ResumeProxy {
    final class Tunnel {
        let phone: NWConnection
        let mac: NWConnection
        var blackholed = false
        init(phone: NWConnection, port: UInt16) {
            self.phone = phone
            mac = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
    }
    let queue = DispatchQueue(label: "imic.resume.test.proxy")
    let listener: NWListener
    let serverPort: UInt16
    private var tunnels: [Tunnel] = []
    private var count = 0
    private var blackholeNext = false
    var accepted: Int { queue.sync { count } }
    init(port: UInt16, serverPort: UInt16) throws {
        self.serverPort = serverPort
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.count += 1
            let tunnel = Tunnel(phone: connection, port: self.serverPort)
            tunnel.blackholed = self.blackholeNext
            self.blackholeNext = false
            self.tunnels.append(tunnel)
            connection.start(queue: self.queue)
            tunnel.mac.start(queue: self.queue)
            self.relay(tunnel, from: connection, to: tunnel.mac)
            self.relay(tunnel, from: tunnel.mac, to: connection)
        }
        listener.start(queue: queue)
    }
    func relay(_ tunnel: Tunnel, from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if tunnel.blackholed { return } // Hold both sockets open, including FIN.
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if done || error != nil { from.cancel(); to.cancel(); return }
            self.relay(tunnel, from: from, to: to)
        }
    }
    func blackholeNextConnection() { queue.sync { blackholeNext = true } }
    func blackhole() { queue.sync { tunnels.forEach { $0.blackholed = true } } }
    func stop() {
        queue.sync {
            listener.cancel()
            tunnels.forEach { $0.phone.cancel(); $0.mac.cancel() }
            tunnels.removeAll()
        }
    }
}

struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
@MainActor func until(_ description: String, timeout: Double = 3, _ condition: () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime+timeout
    while !(await condition()) {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(description)")
        try await Task.sleep(for: .milliseconds(10))
    }
}
let port = UInt16(ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--test-port=") }!.split(separator:"=")[1])!
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imic-lifecycle-\(UUID())")
let store = PairingStore(directory:directory)
store.overrideCode("246810")
let server = LinkServer(store:store,port:port+1)
let proxy = try ResumeProxy(port:port,serverPort:port+1)
let mac = DiscoveredMac(id:store.macID,name:"Lifecycle fixture",endpoint:.hostPort(host:"127.0.0.1",port:.init(rawValue:port)!))
Task { @MainActor in
    let keys=["imic.deviceID","imic.preferredMacID","imic.macNames","imic.macLastConnected","imic.lastConnectedMacID", "imic.forgottenMacIDs", "imic.requiresMacSelection"]
    let saved=keys.map { UserDefaults.standard.object(forKey:$0) }
    let otherMacID=UUID().uuidString
    var failures=0
    var clients:[LinkClient]=[]
    defer {
        server.stop();proxy.stop();TokenStore.delete(for:store.macID);TokenStore.delete(for:otherMacID)
        for (key,value) in zip(keys,saved) {if let value {UserDefaults.standard.set(value,forKey:key)}else{UserDefaults.standard.removeObject(forKey:key)}}
        try? FileManager.default.removeItem(at:directory)
        let result:Int32=failures==0 ? 0:1
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {exit(result)}
    }
    for key in ["imic.lastConnectedMacID", "imic.forgottenMacIDs", "imic.requiresMacSelection"] {
        UserDefaults.standard.removeObject(forKey:key)
    }
    UserDefaults.standard.set(store.macID,forKey:"imic.preferredMacID")
    UserDefaults.standard.set([store.macID:"Lifecycle fixture"],forKey:"imic.macNames")
    UserDefaults.standard.set([String:Double](),forKey:"imic.macLastConnected")
    server.start()
    func client() -> LinkClient {let c=LinkClient();clients.append(c);return c}
    let stale=client()
    do {
        let browsers=await stale.resumeTestOldBrowserRetry()
        defer { withExtendedLifetime(browsers.old) {} }
        try await Task.sleep(for:.milliseconds(2200))
        let same = await stale.resumeTestBrowserIs(browsers.replacement)
        try require(same,"Retired browser retry replaced the current discovery instance")
        print("PASS retired browser retry cannot replace current discovery")
    } catch {failures+=1;print("FAIL stale browser: \(error)")}
    await stale.resumeTestStop()
    let handoff=client()
    do {
        try require(handoff.resumeTestRestartBeforeMainPublication(),"Old browser survives while main-thread foreground publication is pending")
        print("PASS foreground handoff retires old browser before main-thread publication")
    } catch {failures+=1;print("FAIL foreground handoff: \(error)")}
    await handoff.resumeTestStop()
    // An unrelated existing pairing must not turn the user's explicit new-Mac
    // pairing into an automatic-target attempt after foreground recovery.
    UserDefaults.standard.set([store.macID:"Lifecycle fixture",otherMacID:"Other paired fixture"],forKey:"imic.macNames")
    let savedOther = TokenStore.save(Data(repeating:51,count:32),for:otherMacID)
    let pairing=client()
    do {
        try require(savedOther,"Cannot seed unrelated paired fixture")
        await pairing.resumeTestStart(mac)
        try await until("initial code prompt") {if case .needsCode=pairing.phase{return true};return false}
        let initialPairingConnections=proxy.accepted
        pairing.enterBackground();proxy.blackhole();pairing.activate()
        try await until("fresh pairing transport after foreground",timeout:1) {proxy.accepted>initialPairingConnections}
        try await until("same explicit target's new code prompt") {if case .needsCode=pairing.phase{return pairing.selectedMacID==mac.id};return false}
        pairing.submitCode("246810")
        try await until("encrypted pairing on replacement transport") {pairing.phase.isReady}
        try require(proxy.accepted>=2,"Pairing reused the blackholed socket")
        print("PASS foreground replaces the stale pairing socket, keeps the explicit target despite another pairing, and requires the real code")
    } catch {failures+=1;print("FAIL code prompt: \(error)")}
    await pairing.resumeTestStop()
    store.forgetAll();store.overrideCode("246810");TokenStore.delete(for:store.macID)
    let connecting=client()
    do {
        proxy.blackholeNextConnection()
        let accepted=proxy.accepted
        await connecting.resumeTestStart(mac)
        try await until("manual socket before its first hello") {proxy.accepted>accepted}
        try require(!connecting.phase.isReady,"Blackholed first hello unexpectedly authenticated")
        connecting.enterBackground();connecting.activate()
        try await until("manual target reconnects before any code prompt",timeout:1) {proxy.accepted>accepted+1}
        try await until("same manual target asks for code after replacing hello-blackhole") {if case .needsCode=connecting.phase{return connecting.selectedMacID==mac.id};return false}
        connecting.submitCode("246810")
        try await until("manual first-hello recovery authenticates with code") {connecting.phase.isReady}
        print("PASS foreground preserves a manual unpaired target before its first hello, without falling back to the paired Mac")
    } catch {failures+=1;print("FAIL first hello: \(error)")}
    await connecting.resumeTestStop()
    let healthy=client()
    do {
        // Independent setup: an earlier failed pairing regression must not make
        // this healthy-transport case fail merely because its token is absent.
        let token=Data(repeating:37,count:32)
        let deviceID=UserDefaults.standard.string(forKey:"imic.deviceID")!
        try store.trust(deviceID:deviceID,name:"Lifecycle fixture",token:token)
        try require(TokenStore.save(token,for:store.macID),"Cannot seed isolated healthy fixture token")
        var readyCount=0,losses=0
        healthy.onReady={_ in readyCount+=1};healthy.onLost={losses+=1}
        await healthy.resumeTestStart(mac)
        try await until("healthy authenticated link") {healthy.phase.isReady}
        let browser=await healthy.resumeTestInstallPassiveBrowser()
        let accepted=proxy.accepted
        healthy.beginSession(871)
        healthy.enterBackground();healthy.activate()
        try await until("healthy encrypted foreground ping") {readyCount>=2 && healthy.phase.isReady}
        let sameBrowser = await healthy.resumeTestBrowserIs(browser)
        try require(!sameBrowser,"Foreground kept the suspended discovery instance")
        try require(proxy.accepted==accepted && losses==0,"Refreshing discovery replaced the healthy voice transport")
        healthy.cancelSession(871)
        print("PASS foreground refreshes discovery while preserving healthy encrypted voice connection")
    } catch {failures+=1;print("FAIL healthy discovery: \(error)")}
    do {
        await healthy.resumeTestFailBrowserWhileReady()
        try await Task.sleep(for:.milliseconds(50))
        try require(healthy.phase.isReady,"Discovery failure hid a healthy authenticated transport")
        print("PASS browser failure cannot overwrite a healthy link's ready state")
    } catch {failures+=1;print("FAIL discovery presentation: \(error)")}
    await healthy.resumeTestStop()
    let lossHandoff=client()
    do {
        var lostDelivered=false
        lossHandoff.onLost={lostDelivered=true}
        try require(lossHandoff.resumeTestConnectionLossHandoffBlocksAutoConnect(mac),"Bonjour autoConnect bypassed connectionLost main-thread handoff")
        lossHandoff.activate()
        try await until("loss callback delivered after handoff") {lostDelivered}
        let bgCleared = await lossHandoff.resumeTestBackgroundCleared()
        try require(bgCleared,"activate during loss handoff left backgroundAt set")
        let ble = await lossHandoff.resumeTestBeginBLEProbe(startedOffset: 0, initialTimeout: 1.5)
        try await Task.sleep(for: .milliseconds(900))
        ble.onWriteProgress?()
        try await Task.sleep(for: .milliseconds(900))
        ble.onWriteProgress?()
        try await Task.sleep(for: .milliseconds(300))
        let aliveAfterProgress = await lossHandoff.resumeTestBLEProbeState()
        try require(aliveAfterProgress.ready && aliveAfterProgress.probing, "BLE probe timed out prematurely at 1.5s despite write progress")
        await lossHandoff.resumeTestDeliverSealedDuringProbe()
        let completedState = await lossHandoff.resumeTestBLEProbeState()
        try require(completedState.ready && !completedState.probing, "Incoming sealed frame did not complete active BLE probe")
        let bleCapped = await lossHandoff.resumeTestBeginBLEProbe(startedOffset: 9.6, initialTimeout: 1.5)
        bleCapped.onWriteProgress?()
        try await Task.sleep(for: .milliseconds(250))
        bleCapped.onWriteProgress?() // Past 10s cap: must not postpone further.
        try await until("BLE probe outer 10s cap fires timeout", timeout: 1.5) {
            let state = await lossHandoff.resumeTestBLEProbeState()
            return !state.ready && !state.probing
        }
        print("PASS connectionLost handoff gates autoConnect, clears backgroundAt on activate, and BLE probe timer respects progress + 10s cap")
    } catch {failures+=1;print("FAIL loss handoff / BLE probe: \(error)")}
    await lossHandoff.resumeTestStop()
    print("Lifecycle regressions: \(7-failures)/7 passed")
}
dispatchMain()
