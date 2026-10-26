import Foundation
import Network
import Darwin

setbuf(stdout, nil)

// Runs the production phone LinkClient and Mac LinkServer through a byte-for-byte
// loopback proxy. Old tunnels can silently blackhole traffic while new ones work.
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
    var accepted: Int { queue.sync { count } }
    init(port: UInt16, serverPort: UInt16) throws {
        self.serverPort = serverPort
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.count += 1
            let tunnel = Tunnel(phone: connection, port: self.serverPort)
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
    func blackhole() { queue.sync { tunnels.forEach { $0.blackholed = true } } }
    func stop() {
        queue.sync {
            listener.cancel()
            tunnels.forEach { $0.phone.cancel(); $0.mac.cancel() }
            tunnels.removeAll()
        }
    }
}

enum CheckFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}
@MainActor func until(_ description: String, timeout: Double = 4, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(description)")
        try await Task.sleep(for: .milliseconds(10))
    }
}

let args = ProcessInfo.processInfo.arguments
let proxyPort = UInt16(args.first { $0.hasPrefix("--debug-port=") }!.split(separator: "=")[1])!
let serverPort = proxyPort + 1
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imic-resume-\(UUID().uuidString)")
let store = PairingStore(directory: directory)
store.overrideCode("246810")
let server = LinkServer(store: store, port: serverPort)
let proxy = try ResumeProxy(port: proxyPort, serverPort: serverPort)
var serverConnections = 0
var voiceStarts = 0
server.onState = { state in if case .connected = state { serverConnections += 1 } }
server.onMessage = { message in if message.t == "audio.start" { voiceStarts += 1 } }
server.start()

Task { @MainActor in
    var exitCode: Int32 = 0
    let preferenceKeys = ["imic.deviceID", "imic.preferredMacID", "imic.macNames"]
    let saved = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
        TokenStore.delete(for: store.macID)
        for (key, value) in zip(preferenceKeys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        server.stop(); proxy.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    do {
        UserDefaults.standard.set(store.macID, forKey: "imic.preferredMacID")
        let client = LinkClient()
        var readyCount = 0
        var losses = 0
        client.onReady = { _ in readyCount += 1 }
        client.onLost = { losses += 1 }
        client.start()
        try await until("initial encrypted pairing") { client.phase.isReady && readyCount == 1 }
        let initialConnections = serverConnections
        client.beginSession(700)
        try await until("pending voice session") { voiceStarts == 1 }

        client.enterBackground()
        try await Task.sleep(for: .milliseconds(100))
        var started = ProcessInfo.processInfo.systemUptime
        client.activate()
        try await until("healthy connection probe") { readyCount == 2 && client.phase.isReady }
        let healthy = ProcessInfo.processInfo.systemUptime - started
        try require(serverConnections == initialConnections && losses == 0, "Healthy resume replaced a live voice link")
        try require(voiceStarts == 1, "Healthy resume restarted the pending voice session")
        try require(healthy < 0.5, "Healthy resume is too slow")
        print("PASS healthy resume \(Int(healthy * 1000))ms; same encrypted connection")
        client.cancelSession(700)
        client.beginSession(701)
        try await until("old session before suspension") { voiceStarts == 2 }

        client.enterBackground()
        proxy.blackhole()
        let backgroundWait = args.contains("--long-background") ? 55.0 : 1.0
        print("Background blackhole: \(Int(backgroundWait))s; waiting across the Mac heartbeat deadline when long")
        try await Task.sleep(for: .seconds(backgroundWait))
        started = ProcessInfo.processInfo.systemUptime
        client.activate()
        try await until("silent stale connection replacement", timeout: 3) { readyCount == 3 && client.phase.isReady }
        let stale = ProcessInfo.processInfo.systemUptime - started
        try require(stale < 1.8 && losses == 1, "Stale resume delayed or failed to notify the old voice session")
        try require(serverConnections == initialConnections + 1, "Stale resume didn't complete a fresh encrypted handshake")
        print("PASS stale resume \(Int(stale * 1000))ms; loss delivered once; authenticated without re-pairing")

        // A fresh local recording buffered during the probe never used this socket.
        // Replacing an idle old connection must not report a loss against it.
        client.enterBackground()
        proxy.blackhole()
        try await Task.sleep(for: .milliseconds(100))
        client.activate()
        try await until("idle stale socket replaced") { readyCount == 4 && client.phase.isReady }
        try require(losses == 1, "Foreground reconnect cancelled a new locally buffered recording")
        print("PASS idle stale reconnect preserves newly buffered recording")

        // Accumulate failed attempts, then return before the pending backoff expires.
        client.enterBackground()
        server.stop()
        try await until("lost old connection") { !client.phase.isReady }
        try await Task.sleep(for: .seconds(5))
        server.start()
        started = ProcessInfo.processInfo.systemUptime
        client.activate()
        client.activate() // Repeated foreground notifications must coalesce.
        try await until("foreground overrides retry backoff", timeout: 2) { readyCount == 5 && client.phase.isReady }
        let retry = ProcessInfo.processInfo.systemUptime - started
        try require(retry < 1, "Foreground waited for retry backoff")
        print("PASS backoff bypass \(Int(retry * 1000))ms")
        try await Task.sleep(for: .seconds(1))
        try require(readyCount == 5, "Cancelled foreground timeout replaced a good connection later")
        print("PASS all foreground reconnect checks")
    } catch {
        fputs("FAIL \(error)\n", stderr)
        exitCode = 1
    }
    // Run defer cleanup before stopping the process.
    let result = exitCode
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(result) }
}
dispatchMain()
