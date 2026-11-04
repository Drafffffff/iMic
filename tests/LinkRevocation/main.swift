import Foundation
import Network
import CryptoKit

// Real loopback TCP and production LinkServer/PairingStore. No fake ready state,
// private test hooks, keychain writes, or changes to the user's pairing store.
enum Failure: Error { case failed(String) }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure.failed(message) }
}
func until(_ description: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
        try require(Date() < deadline, "Timed out: \(description)")
        Thread.sleep(forTimeInterval: 0.01)
    }
}

final class Phone {
    let deviceID: String
    let key = LinkCrypto.makePrivateKey()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "imic.revocation.phone")
    private let condition = NSCondition()
    private var decoder = LinkFrameDecoder()
    private var frames: [LinkFrame] = []
    private var closed = false
    private var receiveError: Error?
    private var serverPublicKey: String?
    private var cipher: LinkCipher?

    init(port: UInt16, deviceID: String) {
        self.deviceID = deviceID
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        receive()
    }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            self.condition.lock()
            do {
                if let data { self.frames.append(contentsOf: try self.decoder.append(data)) }
            } catch { self.receiveError = error }
            self.closed = done || error != nil
            if let error { self.receiveError = error }
            self.condition.broadcast()
            let keepReceiving = !self.closed && self.receiveError == nil
            self.condition.unlock()
            if keepReceiving { self.receive() }
        }
    }

    private func nextFrame() throws -> LinkFrame {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while frames.isEmpty && !closed && receiveError == nil && Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        guard !frames.isEmpty else {
            throw Failure.failed("No response frame; closed=\(closed), error=\(String(describing: receiveError))")
        }
        return frames.removeFirst()
    }

    private func send(_ message: LinkMessage, using cipher: LinkCipher? = nil) throws {
        let payload = try message.encoded()
        let frame = try LinkFrame(kind: cipher == nil ? .json : .sealedJSON,
                                  payload: cipher.map { try $0.seal(payload) } ?? payload)
        connection.send(content: LinkWire.encode(frame), completion: .contentProcessed { _ in })
    }

    func hello(hasToken: Bool) throws {
        try send(.hello(deviceID: deviceID, deviceName: "Revocation fixture", publicKey: LinkCrypto.publicKeyBase64(key), hasToken: hasToken))
        let frame = try nextFrame()
        try require(frame.kind == .json, "Expected plaintext hello")
        let message = try LinkMessage.decode(frame.payload)
        try require(message.t == "hello" && message.status == (hasToken ? "auth" : "pair_required"), "Unexpected hello status")
        guard let publicKey = message.publicKey else { throw Failure.failed("Missing server public key") }
        serverPublicKey = publicKey
    }

    func sendAuth(token: Data) throws {
        guard let serverPublicKey else { throw Failure.failed("Missing hello") }
        cipher = try LinkCrypto.sessionCipher(privateKey: key, peerPublicKey: serverPublicKey, token: token)
        try send(.auth(), using: cipher)
    }

    func authenticate(token: Data) throws {
        try hello(hasToken: true)
        try sendAuth(token: token)
        try expectEncrypted("ready")
    }

    func pair(code: String, token: Data) throws {
        try hello(hasToken: false)
        guard let serverPublicKey else { throw Failure.failed("Missing hello") }
        let pairing = try LinkCrypto.pairingCipher(privateKey: key, peerPublicKey: serverPublicKey, code: code)
        try send(.pair(deviceID: deviceID, deviceName: "Replacement fixture", token: token.base64EncodedString()), using: pairing)
        let frame = try nextFrame()
        try require(frame.kind == .sealedJSON, "Expected encrypted pairing confirmation")
        try require(try LinkMessage.decode(pairing.open(frame.payload)).t == "paired", "Pairing failed")
        cipher = try LinkCrypto.sessionCipher(privateKey: key, peerPublicKey: serverPublicKey, token: token)
        try expectEncrypted("ready")
    }

    func expectEncrypted(_ type: String) throws {
        guard let cipher else { throw Failure.failed("Missing session cipher") }
        let frame = try nextFrame()
        try require(frame.kind == .sealedJSON, "Expected encrypted \(type), got \(frame.kind)")
        try require(try LinkMessage.decode(cipher.open(frame.payload)).t == type, "Expected \(type)")
    }

    func ping() throws { try send(.ping(123), using: cipher) }
    func expectAuthFailure() throws {
        let frame = try nextFrame()
        try require(frame.kind == .json, "Old credential received encrypted response instead of rejection")
        let message = try LinkMessage.decode(frame.payload)
        try require(message.t == "error" && message.code == "auth", "Expected auth rejection")
        try expectClosed()
    }
    func expectClosed() throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !closed && Date() < deadline { _ = condition.wait(until: deadline) }
        try require(closed, "Revoked connection remained open")
    }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imic-revocation-\(UUID().uuidString)")
let store = PairingStore(directory: directory)
let server = LinkServer(store: store)
var phones: [Phone] = []
var exitCode: Int32 = 0
do {
    server.start()
    try until("listener") { server.localPort != nil }
    let port = server.localPort!
    func phone(_ id: String) -> Phone {
        let result = Phone(port: port, deviceID: id)
        phones.append(result)
        return result
    }
    let deviceID = UUID().uuidString
    let oldToken = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let newToken = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try store.trust(deviceID: deviceID, name: "Original fixture", token: oldToken)
    let pending = phone(deviceID)
    try pending.hello(hasToken: true)
    let replacement = phone(deviceID)
    try replacement.pair(code: store.currentCode(), token: newToken)
    try pending.sendAuth(token: oldToken)
    try pending.expectAuthFailure()
    try replacement.ping()
    try replacement.expectEncrypted("pong")
    print("PASS old pending handshake rejected after real re-pairing; replacement connection survives")

    // Exercise the ready gate independently: authoritative store replacement
    // occurs before a new peer takes ownership of the server's active slot.
    let latestToken = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try store.trust(deviceID: deviceID, name: "Latest fixture", token: latestToken)
    try replacement.ping()
    try replacement.expectAuthFailure()
    let latest = phone(deviceID)
    try latest.authenticate(token: latestToken)
    try latest.ping()
    try latest.expectEncrypted("pong")
    print("PASS ready session rejects replaced token; current token reconnects normally")

    let otherID = UUID().uuidString
    try store.trust(deviceID: otherID, name: "Other fixture", token: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    let other = phone(otherID)
    try other.hello(hasToken: true)
    store.forget(deviceID: otherID)
    try other.expectClosed()
    try latest.ping()
    try latest.expectEncrypted("pong")
    store.forget(deviceID: deviceID)
    try latest.expectClosed()
    try until("active peer revoked") { !server.isConnected }
    print("PASS single-device revocation closes matching pending/active peers and preserves unrelated connection")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exitCode = 1
}
phones.forEach { $0.stop() }
server.stop()
_ = server.isConnected // Drain the server queue before removing the isolated store.
try? FileManager.default.removeItem(at: directory)
exit(exitCode)
