import Foundation
import Darwin

setbuf(stdout, nil)
enum CheckFailure: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}
@MainActor func until(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    while !condition() {
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: \(description)")
        try await Task.sleep(for: .milliseconds(10))
    }
}
let args = ProcessInfo.processInfo.arguments
let port = UInt16(args.first { $0.hasPrefix("--debug-port=") }!.split(separator: "=")[1])!
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imic-polish-link-\(UUID().uuidString)")
let store = PairingStore(directory: directory)
store.overrideCode("246810")
let server = LinkServer(store: store, port: port)
let features = IMicLink.polishPreferencesFeature | IMicLink.polishOutputFeature | IMicLink.polishModesFeature
var saved = LinkPolishPreferences(enabled: true, options: .default)
var requests = 0
server.onState = { state in
    if case .connected = state { server.send(.settings(features: features, polish: saved)) }
}
server.onPolishPreferences = { requested, phoneFeatures in
    requests += 1
    saved = saved.applying(requested, features: phoneFeatures)
    server.send(.settings(features: features, polish: saved))
    // A status broadcast must not be mistaken for the explicit save confirmation.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        server.send(.polishSaved(features: features, polish: saved))
    }
}
server.start()
Task { @MainActor in
    var result: Int32 = 0
    let keys = ["imic.deviceID", "imic.preferredMacID", "imic.macNames", "imic.macLastConnected"]
    let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
        TokenStore.delete(for: store.macID)
        for (key, value) in zip(keys, previous) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    do {
        UserDefaults.standard.set(store.macID, forKey: "imic.preferredMacID")
        let client = LinkClient()
        client.start()
        try await until("authenticated settings") { client.phase.isReady && client.polishPreferences == saved }
        try require(client.polishPreferencesSupported, "New capability was not recognized")
        let creative = LinkPolishPreferences(enabled: true,
            options: PolishOptions(output: .japanese, mode: .waffle, tone: .moe))
        try require(client.updatePolishPreferences(creative), "Could not submit creative preset")
        try await until("Mac received request") { requests == 1 }
        try require(client.polishPreferencesSaving, "Ordinary settings acknowledged a pending save")
        try await until("explicit ACK") { !client.polishPreferencesSaving }
        try require(client.polishPreferences == creative && client.polishPreferencesError == nil,
                    "Mode, tone or language changed in transit")
        print("PASS authenticated mode/tone/language save; ordinary broadcast does not ACK")

        var terminal = creative
        terminal.options.mode = .terminal
        try require(client.updatePolishPreferences(terminal), "Could not select terminal")
        try await until("terminal ACK") { requests == 2 && !client.polishPreferencesSaving }
        try require(client.polishPreferences == terminal, "Terminal erased inactive choices")
        print("PASS terminal retains tone and language over real encrypted link")

        saved = LinkPolishPreferences(enabled: false,
            options: PolishOptions(output: .korean, mode: .dubbed, tone: .sarcastic))
        server.send(.settings(features: features, polish: saved))
        try await until("Mac-side change reflected") { client.polishPreferences == saved }
        print("PASS Mac-side changes reflected on phone")

        server.send(.settings(features: IMicLink.polishPreferencesFeature | IMicLink.polishOutputFeature, polish: saved))
        try await until("legacy Mac gated") { !client.polishPreferencesSupported }
        try require(!client.updatePolishPreferences(creative), "New preset was sent to a legacy Mac")
        try require(requests == 2, "Unsupported save reached server")
        print("PASS older Mac cannot receive unsupported new presets")
    } catch {
        fputs("FAIL \(error)\n", stderr)
        result = 1
    }
    let exitCode = result
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(exitCode) }
}
dispatchMain()
