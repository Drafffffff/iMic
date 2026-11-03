import Foundation
import Network
import Combine
import Darwin

setbuf(stdout, nil)
enum Failure: Error { case failed(String) }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.failed(message) }
}
@MainActor func until(_ name: String, timeout: Double = 6, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
        try check(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(name)")
        try await Task.sleep(for: .milliseconds(10))
    }
}

// Hold real encrypted server replies while forgetting the pairing. This exercises
// the production receive callback after its socket and token have been retired.
final class DelayedReplyProxy {
    private let queue = DispatchQueue(label:"imic.selection.delayed-replies")
    private let listener: NWListener
    private var phone: NWConnection?
    private var server: NWConnection?
    private var paused = false
    private var replies: [Data] = []
    var buffered: Int { queue.sync { replies.reduce(0) { $0+$1.count } } }
    init(port: UInt16, serverPort: UInt16) throws {
        listener = try NWListener(using:.tcp,on:NWEndpoint.Port(rawValue:port)!)
        listener.newConnectionHandler = { [weak self] phone in
            guard let self else { return }
            let server=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:serverPort)!,using:.tcp)
            self.phone=phone;self.server=server
            phone.start(queue:self.queue);server.start(queue:self.queue)
            self.relay(phone,to:server,reply:false)
            self.relay(server,to:phone,reply:true)
        }
        listener.start(queue:queue)
    }
    func pause() { queue.sync { paused=true } }
    func resume() { queue.sync { paused=false;for data in replies { phone?.send(content:data,completion:.contentProcessed { _ in }) };replies=[] } }
    func stop() { queue.async { self.listener.cancel();self.phone?.cancel();self.server?.cancel() } }
    private func relay(_ from: NWConnection,to: NWConnection,reply: Bool) {
        from.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,done,error in
            guard let self else { return }
            if let data,!data.isEmpty {
                if reply && self.paused { self.replies.append(data) }
                else { to.send(content:data,completion:.contentProcessed { _ in }) }
            }
            if done || error != nil { from.cancel();to.cancel();return }
            self.relay(from,to:to,reply:reply)
        }
    }
}

Task { @MainActor in
    let keys = ["imic.deviceID", "imic.preferredMacID", "imic.macNames", "imic.macLastConnected", "imic.lastConnectedMacID", "imic.forgottenMacIDs", "imic.requiresMacSelection"]
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imic-selection-\(UUID().uuidString)")
    let deviceID = UUID().uuidString
    let stores = (0..<3).map { PairingStore(directory: directory.appendingPathComponent("\($0)")) }
    let port = UInt16(ProcessInfo.processInfo.environment["IMIC_SELECTION_TEST_PORT"] ?? "47964")!
    let servers = stores.enumerated().map { LinkServer(store: $0.element, port: port + UInt16($0.offset)) }
    let macs = stores.enumerated().map {
        DiscoveredMac(id: $0.element.macID, name: "Fixture \($0.offset)",
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port + UInt16($0.offset))!))
    }
    let tokens = (0..<3).map { Data(repeating: UInt8($0 + 17), count: 32) }
    var clients: [LinkClient] = []
    var code: Int32 = 0
    defer {
        servers.forEach { $0.stop() }
        stores.forEach { TokenStore.delete(for: $0.macID) }
        for (key, value) in zip(keys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: directory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(code) }
    }
    func seed(preferred: Int?, paired: Set<Int>, recent: [String: Double] = [:]) throws {
        UserDefaults.standard.set(deviceID, forKey: "imic.deviceID")
        UserDefaults.standard.set(preferred.map { macs[$0].id }, forKey: "imic.preferredMacID")
        UserDefaults.standard.set(preferred.map { macs[$0].id }, forKey: "imic.lastConnectedMacID")
        UserDefaults.standard.removeObject(forKey: "imic.forgottenMacIDs")
        UserDefaults.standard.removeObject(forKey: "imic.requiresMacSelection")
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: macs.map { ($0.id, $0.name) }), forKey: "imic.macNames")
        UserDefaults.standard.set(recent, forKey: "imic.macLastConnected")
        for index in 0..<3 {
            stores[index].forgetAll()
            TokenStore.delete(for: macs[index].id)
            if paired.contains(index) {
                try stores[index].trust(deviceID: deviceID, name: "Selection fixture", token: tokens[index])
                try check(TokenStore.save(tokens[index], for: macs[index].id), "Cannot save isolated fixture token")
            }
        }
    }
    func makeClient() -> LinkClient {
        let client = LinkClient(); clients.append(client); return client
    }
    do {
        servers.forEach { $0.start() }
        try seed(preferred: 0, paired: [0,1,2], recent: [macs[0].id:30, macs[1].id:10, macs[2].id:20])
        var client = makeClient()
        await client.selectionTestDiscover([macs[1],macs[2]], begin:true, expired:true)
        try await Task.sleep(for:.seconds(1.8))
        try check(!client.phase.isReady && client.selectedMacID == macs[0].id, "Offline last Mac was replaced after grace")
        try check(!servers[1].isConnected && !servers[2].isConnected, "Another Mac accepted an unintended connection")
        await client.selectionTestDiscover([macs[2],macs[1],macs[0]])
        try await until("last Mac returns") { client.phase.isReady }
        try check(client.selectedMacID == macs[0].id && servers.filter(\.isConnected).count == 1, "Discovery order allowed multiple ready Macs")
        client.beginSession(901)
        await client.selectionTestDiscover([macs[2],macs[1],macs[0]])
        try await Task.sleep(for:.milliseconds(150))
        try check(client.selectedMacID == macs[0].id && servers.filter(\.isConnected).count == 1, "Late discovery switched an active session")
        client.cancelSession(901)
        await client.selectionTestStop()
        print("PASS offline last device stays selected after grace; delayed discovery and active session keep one Mac")

        try seed(preferred:0, paired:[0,1,2])
        client = makeClient()
        let failed = DiscoveredMac(id:macs[0].id,name:"Unavailable",endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port+8)!))
        await client.selectionTestDiscover([failed,macs[1],macs[2]],begin:true,expired:true)
        try await Task.sleep(for:.seconds(2.5))
        try check(!client.phase.isReady && client.selectedMacID == macs[0].id, "Failed preferred fell through to another authenticated computer")
        try check(!servers[1].isConnected && !servers[2].isConnected, "Failed target allowed another Mac to connect")
        await client.selectionTestStop()
        print("PASS network failure retries the chosen identity without fallback")

        try seed(preferred:0, paired:[0,1])
        client = makeClient()
        let wrongIdentity=DiscoveredMac(id:macs[0].id,name:"Wrong identity",endpoint:macs[1].endpoint)
        await client.selectionTestDiscover([wrongIdentity,macs[1]],begin:true)
        try await Task.sleep(for:.seconds(1))
        try check(!client.phase.isReady && !servers[1].isConnected, "Identity mismatch established an unintended connection")
        await client.selectionTestStop()
        print("PASS advertised identity cannot substitute another Mac")

        for wrongToken in [false,true] {
            try seed(preferred:0,paired:[0,1])
            if wrongToken { try check(TokenStore.save(Data(repeating:99,count:32),for:macs[0].id),"Cannot seed invalid token") }
            else { stores[0].forgetAll() }
            client=makeClient()
            var prompted=false
            let observer=client.$phase.sink { if case .needsCode=$0 { prompted=true } }
            await client.selectionTestDiscover([macs[0],macs[1]],begin:true)
            try await until("revoked token removed") { TokenStore.load(for:macs[0].id)==nil }
            try await Task.sleep(for:.milliseconds(800))
            try check(!client.phase.isReady && !prompted && !servers[1].isConnected,"Revocation prompted pairing or redirected to another Mac")
            observer.cancel()
            client.connect(to:macs[0])
            try await until("explicit retry can re-pair revoked target") { client.pairing }
            client.submitCode(stores[0].currentCode())
            try await until("revoked target manually paired again") { client.phase.isReady }
            try check(client.selectedMacID==macs[0].id && !servers[1].isConnected,"Explicit repair changed target")
            await client.selectionTestStop()
        }
        print("PASS rejected hello/auth tokens never pair or redirect automatically")

        try seed(preferred:0,paired:[0,1,2],recent:[macs[0].id:30])
        UserDefaults.standard.removeObject(forKey:"imic.lastConnectedMacID")
        UserDefaults.standard.set(macs[2].id,forKey:"imic.preferredMacID") // Old build stored an unsuccessful click.
        client=makeClient()
        try check(client.selectedMacID==macs[0].id,"Migration used a click instead of authenticated history")
        await client.selectionTestDiscover([macs[0],macs[1]],begin:true)
        try await until("migrated target authenticates") { client.phase.isReady }
        try check(UserDefaults.standard.string(forKey:"imic.lastConnectedMacID")==macs[0].id,"Ready did not persist successful identity")
        let offlineChoice = RememberedMac(id:UUID().uuidString,name:"Never advertised fixture")
        client.selectRememberedMac(offlineChoice)
        try await until("manual choice publishes") { client.selectedMacID==offlineChoice.id }
        try check(UserDefaults.standard.string(forKey:"imic.lastConnectedMacID")==macs[0].id,"Manual click changed last successful Mac before authentication")
        await client.selectionTestStop()
        client=makeClient()
        try check(client.selectedMacID==macs[0].id,"Relaunch did not restore successful device")
        await client.selectionTestStop()
        print("PASS old data migration and cold launch remember authenticated success rather than a click")

        try seed(preferred:0,paired:[0,1,2],recent:[macs[0].id:30,macs[2].id:20,macs[1].id:10])
        client=makeClient()
        await client.selectionTestDiscover([macs[0]],begin:true)
        try await until("successful A before changing target") { client.phase.isReady }
        let waitingChoice=RememberedMac(id:UUID().uuidString,name:"Never advertised D")
        client.selectRememberedMac(waitingChoice)
        try await until("manual D waits") { client.selectedMacID==waitingChoice.id && client.isManualSelection }
        let waitingEpoch=await client.selectionTestEpoch()
        client.forgetMac(id:macs[0].id)
        try await until("previous successful A removed") { TokenStore.load(for:macs[0].id)==nil && !client.rememberedMacs.contains { $0.id==macs[0].id } }
        try check(client.selectedMacID==waitingChoice.id && client.isManualSelection,"Deleting previous successful A interrupted manual D")
        let afterForgetEpoch=await client.selectionTestEpoch()
        try check(afterForgetEpoch==waitingEpoch,"Deleting non-current A retired the in-flight target epoch")
        await client.selectionTestStop()
        client=makeClient()
        await client.selectionTestDiscover([macs[2],macs[1]],begin:true,expired:true)
        try await Task.sleep(for:.seconds(1.8))
        try check(!client.phase.isReady && !client.pairing && client.selectedMacID==nil,"Deleting the stored successful A restored older history C on cold launch")
        try check(!servers[2].isConnected && !servers[1].isConnected,"Cold launch connected old history without explicit choice")
        try check(UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"Deleting successful identity did not persist explicit-choice requirement")
        client.connect(to:macs[1])
        try await until("explicit new target ready after deleting stored A") { client.phase.isReady }
        try check(client.selectedMacID==macs[1].id && !UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"New authenticated target did not clear deletion pause")
        await client.selectionTestStop()
        print("PASS deleting stored success A while manual D waits preserves D; cold launch cannot restore C; explicit B success resumes auto connect")

        try seed(preferred:0,paired:[0,1,2],recent:[macs[0].id:30,macs[2].id:20])
        client=makeClient()
        await client.selectionTestDiscover([macs[0]],begin:true)
        try await until("current Mac ready") { client.phase.isReady }
        client.beginSession(902)
        client.forgetMac(id:macs[2].id)
        try await until("offline other device deleted") { !client.rememberedMacs.contains { $0.id==macs[2].id } }
        try check(client.phase.isReady && client.selectedMacID==macs[0].id && servers[0].isConnected,"Forgetting another device interrupted current link")
        try check(!UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"Forgetting ordinary non-current C changed automatic restoration policy")
        try check(TokenStore.load(for:macs[2].id)==nil,"Forgotten token remained")
        try check((UserDefaults.standard.dictionary(forKey:"imic.macLastConnected") ?? [:])[macs[2].id]==nil,"Forgotten recency remained")
        client.cancelSession(902)
        client.forgetMac(id:macs[0].id)
        try await until("current device deleted") { client.selectedMacID==nil && TokenStore.load(for:macs[0].id)==nil }
        await client.selectionTestDiscover(macs)
        try await Task.sleep(for:.seconds(1.8))
        try check(!client.phase.isReady && !client.pairing && client.selectedMacID==nil,"Forgetting current device immediately reconnected or started pairing")
        try check(UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"Explicit selection pause was not persisted")
        let failedAfterForget=RememberedMac(id:UUID().uuidString,name:"Offline after forget")
        client.selectRememberedMac(failedAfterForget)
        try await until("manual attempt after forgetting") { client.selectedMacID==failedAfterForget.id }
        try check(UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"Unsuccessful manual attempt lifted persisted deletion pause")
        await client.selectionTestStop()
        client=makeClient()
        await client.selectionTestDiscover([macs[1]],begin:true,expired:true)
        try await Task.sleep(for:.milliseconds(400))
        try check(!client.phase.isReady && !client.pairing,"Relaunch undid deletion's selection pause")
        client.selectRememberedMac(RememberedMac(id:macs[1].id,name:macs[1].name))
        await client.selectionTestDiscover([macs[1]])
        try await until("explicit selection resumes connection") { client.phase.isReady }
        try check(client.selectedMacID==macs[1].id && !UserDefaults.standard.bool(forKey:"imic.requiresMacSelection"),"Manual connection did not clear pause")
        try await until("old server socket closed") { !servers[0].isConnected }
        try check(servers.filter(\.isConnected).count==1,"Switch retained multiple authenticated server links")
        await client.selectionTestStop()
        print("PASS forgetting offline/current devices removes records, keeps unrelated voice link, persists pause and allows explicit reconnect")

        try seed(preferred:0,paired:[0])
        client=makeClient()
        await client.selectionTestDiscover([macs[2]],begin:true,expired:true)
        try await Task.sleep(for:.milliseconds(250))
        try check(!client.phase.isReady && !client.pairing,"Paired phone connected an unpaired stranger")
        await client.selectionTestStop()
        print("PASS existing pairing prevents accidental new pairing")

        try seed(preferred:nil,paired:[])
        client=makeClient()
        await client.selectionTestDiscover([macs[2]],begin:true)
        try await until("first installation pairing") { client.pairing }
        try check(UserDefaults.standard.string(forKey:"imic.lastConnectedMacID")==nil,"Hello recorded success")
        client.submitCode(stores[2].currentCode())
        try await until("explicit pairing ready") { client.phase.isReady }
        try check(UserDefaults.standard.string(forKey:"imic.lastConnectedMacID")==macs[2].id,"Authenticated pair not remembered")
        await client.selectionTestStop()
        print("PASS first-install pairing remains explicit and success is recorded at ready")
        try seed(preferred:nil,paired:[])
        let proxy=try DelayedReplyProxy(port:port+5,serverPort:port+2)
        let delayed=DiscoveredMac(id:macs[2].id,name:macs[2].name,endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port+5)!))
        client=makeClient()
        await client.selectionTestDiscover([delayed],begin:true)
        try await until("delayed pairing prompt") { client.pairing }
        proxy.pause()
        client.submitCode(stores[2].currentCode())
        try await until("encrypted paired/ready replies held") { proxy.buffered>0 }
        client.forgetMac(id:macs[2].id)
        try await until("forget while pairing retires target") { client.selectedMacID==nil }
        proxy.resume()
        try await Task.sleep(for:.milliseconds(400))
        try check(TokenStore.load(for:macs[2].id)==nil && !client.phase.isReady && !client.hasPairedMac,"Late paired/ready reply restored forgotten credentials")
        try check(!client.gestureReady && !client.clearPending,"Retired target retained editing capability")
        await client.selectionTestStop();proxy.stop()
        print("PASS delayed encrypted paired/ready replies cannot resurrect forgotten credentials or gestures")
        print("PASS all sticky Mac and forgetting integration checks")
    } catch {
        fputs("FAIL \(error)\n",stderr); code=1
    }
    for client in clients { await client.selectionTestStop() }
}
dispatchMain()
