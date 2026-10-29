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

Task { @MainActor in
    let keys = ["imic.deviceID", "imic.preferredMacID", "imic.macNames", "imic.macLastConnected"]
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
        try seed(preferred: 0, paired: [0,1,2], recent: [macs[1].id: 10, macs[2].id: 20])
        var client = makeClient()
        let started = ProcessInfo.processInfo.systemUptime
        await client.selectionTestDiscover([macs[1], macs[2]], begin: true)
        try await Task.sleep(for: .milliseconds(250))
        try check(!client.phase.isReady, "Fallback raced the preferred grace")
        try await until("recent paired fallback") { client.phase.isReady }
        try check(ProcessInfo.processInfo.systemUptime - started >= MacSelection.preferredGrace, "Grace finished early")
        try check(client.selectedMacID == macs[2].id, "Did not choose the most recent paired Mac")
        try check(UserDefaults.standard.string(forKey: "imic.preferredMacID") == macs[2].id, "Successful fallback was not remembered")
        let timestamps = UserDefaults.standard.dictionary(forKey: "imic.macLastConnected") as? [String: Double] ?? [:]
        try check((timestamps[macs[2].id] ?? 0) > 20, "Authenticated readiness did not update recency")
        client.beginSession(901)
        await client.selectionTestDiscover(macs)
        try await Task.sleep(for: .milliseconds(150))
        try check(client.phase.isReady && client.selectedMacID == macs[2].id, "Late discovery switched a live session")
        client.cancelSession(901)
        await client.selectionTestStop()
        print("PASS grace, authenticated fallback identity/recency, late discovery preserves active link")

        try seed(preferred: 0, paired: [0,1,2])
        client = makeClient()
        await client.selectionTestDiscover([macs[1]], begin: true)
        try await Task.sleep(for: .milliseconds(200))
        await client.selectionTestDiscover([macs[1],macs[0]])
        try await until("preferred discovered inside grace") { client.phase.isReady }
        try check(client.selectedMacID == macs[0].id, "Early fallback stole preferred's connection")
        await client.selectionTestStop()
        print("PASS preferred wins when discovered 200ms later")

        try seed(preferred: 0, paired: [0,1,2], recent: [macs[2].id:20, macs[1].id:10])
        client = makeClient()
        let failed = DiscoveredMac(id: macs[2].id, name:"Unavailable", endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port+8)!))
        await client.selectionTestDiscover([failed, macs[1]], begin:true, expired:true)
        try await until("failed candidate falls through") { client.phase.isReady }
        try check(client.selectedMacID == macs[1].id, "Failed candidate was retried before the next candidate")
        let failureTimes = UserDefaults.standard.dictionary(forKey:"imic.macLastConnected") as? [String:Double] ?? [:]
        try check(failureTimes[macs[2].id] == 20, "Failed handshake changed successful recency")
        await client.selectionTestStop()
        print("PASS failed network target advances to next candidate without recording success")

        try seed(preferred:nil, paired:[0,1,2], recent:[macs[1].id:20,macs[0].id:10])
        client = makeClient()
        let wrongIdentity = DiscoveredMac(id:macs[1].id,name:"Wrong identity",endpoint:macs[2].endpoint)
        await client.selectionTestDiscover([wrongIdentity,macs[0]],begin:true)
        try await until("mismatched identity is rejected") { client.phase.isReady }
        try check(client.selectedMacID == macs[0].id, "Fallback relaxed the expected Mac identity check")
        await client.selectionTestStop()
        print("PASS discovered endpoint cannot substitute another Mac identity")

        try seed(preferred:nil, paired:[1,2], recent:[macs[2].id:20,macs[1].id:10])
        client = makeClient()
        let unavailable = [1,2].map {
            DiscoveredMac(id:macs[$0].id,name:"Unavailable \($0)",
                endpoint:.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port+UInt16($0)+8)!))
        }
        await client.selectionTestDiscover(unavailable,begin:true)
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 6
        var retryState = await client.selectionTestRetryState()
        while !retryState.2, ProcessInfo.processInfo.systemUptime < retryDeadline {
            try await Task.sleep(for:.milliseconds(10))
            retryState = await client.selectionTestRetryState()
        }
        try check(retryState.0 == Set(unavailable.map(\.id)) && retryState.1 == 1 && retryState.2,
                  "Exhausted candidates did not enter a single backoff")
        try await Task.sleep(for:.milliseconds(250))
        let stillWaiting = await client.selectionTestRetryState()
        try check(stillWaiting.1 == 1 && stillWaiting.2, "Exhausted candidates rapidly retried instead of backing off")
        await client.selectionTestStop()
        print("PASS exhausted candidate round uses existing backoff without rapid ping-pong")

        try seed(preferred:0, paired:[0,1])
        stores[0].forgetAll() // The Mac revoked this phone; its local token is stale.
        client = makeClient()
        var prompted = false
        let observer = client.$phase.sink { if case .needsCode = $0 { prompted = true } }
        await client.selectionTestDiscover([macs[0],macs[1]], begin:true)
        try await until("revoked token fallback") { client.phase.isReady }
        try check(client.selectedMacID == macs[1].id && !prompted, "Automatic token rejection opened pairing instead of falling back")
        try check(TokenStore.load(for:macs[0].id) == nil, "Revoked token was not removed")
        observer.cancel()
        await client.selectionTestStop()
        print("PASS revoked automatic token skips pairing and authenticates the next Mac")

        try seed(preferred:0,paired:[0,1])
        try check(TokenStore.save(Data(repeating:99,count:32),for:macs[0].id), "Cannot prepare stale auth token")
        client = makeClient()
        var authPrompted = false
        let authObserver = client.$phase.sink { if case .needsCode = $0 { authPrompted = true } }
        await client.selectionTestDiscover([macs[0],macs[1]],begin:true)
        try await until("authentication rejection fallback") { client.phase.isReady }
        try check(client.selectedMacID == macs[1].id && !authPrompted, "Rejected auth token prompted automatic pairing")
        try check(TokenStore.load(for:macs[0].id) == nil, "Rejected auth token was retained")
        authObserver.cancel()
        await client.selectionTestStop()
        print("PASS auth rejection removes only the stale token and falls back without pairing")

        try seed(preferred:0, paired:[0,1])
        servers[0].stop() // This public foreground path creates a real browser: A must really be offline.
        client = makeClient()
        await client.selectionTestDiscover([], begin:true)
        client.selectRememberedMac(RememberedMac(id:macs[0].id,name:macs[0].name))
        try await until("manual mode published") { client.isManualSelection }
        await client.selectionTestDiscover([macs[1]])
        try await Task.sleep(for:.seconds(1.7))
        try check(!client.phase.isReady && client.selectedMacID == macs[0].id, "Manual offline choice was overridden")
        client.enterBackground(); client.activate()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await client.selectionTestHasBrowser()), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        await client.selectionTestDiscover([macs[1]])
        try await until("foreground resets manual lock") { client.phase.isReady }
        try check(client.selectedMacID == macs[1].id && !client.isManualSelection, "Foreground did not restore automatic policy: selected=\(client.selectedMacID ?? "nil") expected=\(macs[1].id) manual=\(client.isManualSelection)")
        client.forgetMac()
        try await until("forget deletes recency") {
            (UserDefaults.standard.dictionary(forKey:"imic.macLastConnected") as? [String:Double])?[macs[1].id] == nil
                && client.selectedMacID == nil
        }
        await client.selectionTestStop()
        print("PASS manual offline wait, foreground unlock, forget removes authenticated recency")

        try seed(preferred:0, paired:[0])
        client = makeClient()
        await client.selectionTestDiscover([macs[2]], begin:true, expired:true)
        try await Task.sleep(for:.milliseconds(250))
        try check(!client.phase.isReady && !client.pairing && client.phase == .searching, "Paired-but-offline phone connected an unpaired stranger")
        await client.selectionTestStop()
        print("PASS any offline pairing prevents automatic pairing with an unpaired discovery")

        try seed(preferred:nil, paired:[])
        client = makeClient()
        await client.selectionTestDiscover([macs[2]], begin:true)
        try await until("first installation requests pairing") { client.pairing }
        try check((UserDefaults.standard.dictionary(forKey:"imic.macLastConnected") ?? [:]).isEmpty, "Unauthenticated connection recorded success")
        try check(UserDefaults.standard.string(forKey:"imic.preferredMacID") == nil, "Unauthenticated hello changed preferred")
        client.submitCode(stores[2].currentCode())
        try await until("explicit pairing becomes ready") { client.phase.isReady }
        try check(client.selectedMacID == macs[2].id, "First-install pairing selected wrong Mac")
        await client.selectionTestStop()
        print("PASS first-install single-Mac pairing stays explicit and records success only after ready")
        print("PASS all automatic Mac selection integration checks")
    } catch {
        fputs("FAIL \(error)\n",stderr); code=1
    }
    for client in clients { await client.selectionTestStop() }
}
dispatchMain()
