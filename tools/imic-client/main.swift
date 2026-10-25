import Foundation
import Network
import CryptoKit

// 端到端联调客户端：发现 iMic Bonjour 服务、完成配对/认证、按实时节奏发送 PCM。
// 仅供开发验证，不随应用分发。

func argument(_ name: String) -> String? {
    let prefix = "--\(name)="
    return CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

let code = argument("code") ?? "123456"
let wantedMacID = argument("mac-id")
let pcmPath = argument("pcm")
let timeout = Double(argument("timeout") ?? "45") ?? 45
let deviceName = argument("name") ?? "iMic Test iPhone"
let directHost = argument("host")
let directPort = argument("port").flatMap { UInt16($0) }
let skipFirstFrame = CommandLine.arguments.contains("--skip-first-frame")
let dropFrame = argument("drop-frame").flatMap { Int($0) }
let skipStart = CommandLine.arguments.contains("--skip-start")
let deviceIDFile = URL(fileURLWithPath: argument("device-id-file") ?? "/tmp/imic-device-id.txt")
let tokenFile = URL(fileURLWithPath: argument("token-file") ?? "/tmp/imic-token.txt")

let deviceID: String
if let existing = try? String(contentsOf: deviceIDFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
   UUID(uuidString: existing) != nil {
    deviceID = existing
} else {
    deviceID = UUID().uuidString
    try? Data(deviceID.utf8).write(to: deviceIDFile)
}

let savedToken: Data? = {
    guard let text = try? String(contentsOf: tokenFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let data = Data(base64Encoded: text), data.count == 32 else { return nil }
    return data
}()

final class TestClient {
    let queue = DispatchQueue(label: "imic.test.client")
    let params: NWParameters
    var browser: NWBrowser?
    var connection: NWConnection?
    var decoder = LinkFrameDecoder()
    var privateKey = LinkCrypto.makePrivateKey()
    var serverPublic: String?
    var cipher: LinkCipher?
    var pairingCipher: LinkCipher?
    var token: Data?
    var frames = 0
    var samples = 0
    var pcm = Data()
    var offset = 0
    var journal: [Data] = []
    var timer: DispatchSourceTimer?
    var finished = false
    var started = false
    var connected = false

    init() {
        params = NWParameters.tcp
        params.includePeerToPeer = true
        token = savedToken
    }

    func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    func start() {
        if let host = directHost, let port = directPort,
           let endpointPort = NWEndpoint.Port(rawValue: port) {
            connect(.hostPort(host: NWEndpoint.Host(host), port: endpointPort))
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail("timeout waiting for result")
            }
            return
        }
        let browser = NWBrowser(
            for: .bonjour(type: IMicLink.serviceType, domain: nil),
            using: params
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.fail("browser failed: \(error)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self, !self.connected else { return }
            for result in results {
                if let wanted = wantedMacID {
                    if case .bonjour(let txt) = result.metadata, txt["id"] == wanted {
                        self.connect(result.endpoint)
                        return
                    }
                } else {
                    self.connect(result.endpoint)
                    return
                }
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail("timeout waiting for result")
        }
    }

    func connect(_ endpoint: NWEndpoint) {
        guard !connected else { return }
        connected = true
        browser?.cancel()
        log("CONNECTING \(endpoint)")
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendHello()
                self.receive()
            case .failed(let error):
                self.fail("connection failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: LinkFrame) {
        guard let connection = connection else { return }
        connection.send(content: LinkWire.encode(frame), completion: .contentProcessed { [weak self] error in
            if let error = error { self?.fail("send failed: \(error)") }
        })
    }

    func sendPlain(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return fail("encode failed") }
        send(LinkFrame(kind: .json, payload: data))
    }

    func sendSealed(_ message: LinkMessage) {
        guard let cipher = cipher else { return fail("no cipher") }
        guard let data = try? message.encoded(), let sealed = try? cipher.seal(data) else {
            return fail("encrypt failed")
        }
        send(LinkFrame(kind: .sealedJSON, payload: sealed))
    }

    func sendHello() {
        log("HELLO token=\(token != nil)")
        sendPlain(.hello(
            deviceID: deviceID,
            deviceName: deviceName,
            publicKey: LinkCrypto.publicKeyBase64(privateKey),
            hasToken: token != nil
        ))
    }

    func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                if let data = data, !data.isEmpty {
                    do {
                        for frame in try self.decoder.append(data) {
                            try self.handle(frame)
                        }
                    } catch {
                        self.fail("protocol: \(error)")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.fail("connection closed")
                    return
                }
                self.receive()
            }
        }
    }

    func handle(_ frame: LinkFrame) throws {
        switch frame.kind {
        case .json:
            let message = try LinkMessage.decode(frame.payload)
            try handlePlain(message)
        case .sealedJSON:
            guard let cipher = cipher else { throw LinkError.decryptionFailed }
            let message = try LinkMessage.decode(cipher.open(frame.payload))
            try handleSealed(message)
        case .sealedAudio:
            break
        }
    }

    func handlePlain(_ message: LinkMessage) throws {
        log("PLAIN \(message.t) status=\(message.status ?? "-")")
        guard message.t == "hello" else {
            if message.t == "error" { fail("server error: \(message.code ?? "") \(message.message ?? "")") }
            return
        }
        guard let serverPublic = message.publicKey else { throw LinkError.invalidPublicKey }
        self.serverPublic = serverPublic
        if message.status == "auth" {
            guard let token = token else { throw LinkError.invalidToken }
            cipher = try LinkCrypto.sessionCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                token: token
            )
            sendSealed(.auth())
        } else {
            let pairCipher = try LinkCrypto.pairingCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                code: code
            )
            pairingCipher = pairCipher
            cipher = pairCipher
            if token == nil {
                var generator = SystemRandomNumberGenerator()
                token = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
            }
            guard let token = token else { throw LinkError.invalidToken }
            sendSealed(.pair(
                deviceID: deviceID,
                deviceName: deviceName,
                token: token.base64EncodedString()
            ))
        }
    }

    func handleSealed(_ message: LinkMessage) throws {
        log("SEALED \(message.t)")
        switch message.t {
        case "paired":
            guard let token = token, let serverPublic = serverPublic else { throw LinkError.invalidToken }
            try Data(token.base64EncodedString().utf8).write(to: tokenFile)
            cipher = try LinkCrypto.sessionCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                token: token
            )
            log("PAIRED token saved")
        case "ready":
            startAudio()
        case "ping":
            sendSealed(.pong(message.ts ?? 0))
        case "result":
            let text = message.text ?? ""
            log("RESULT_BEGIN")
            log(text)
            log("RESULT_END latency_ms=\(Int(message.latency ?? 0)) pasted=\(message.pasted == true) target=\(message.target ?? "-")")
            finish(text.isEmpty ? 1 : 0)
        case "audio.need":
            guard let from = message.seq, from >= 0 else { break }
            log("AUDIO_NEED from=\(from) available=\(journal.count)")
            if from < journal.count {
                for index in from..<journal.count {
                    let packet = AudioPacket(session: 1, seq: UInt32(index), pcm: journal[index])
                    if let cipher = cipher, let sealed = try? cipher.seal(packet.encoded()) {
                        send(LinkFrame(kind: .sealedAudio, payload: sealed))
                    }
                }
            }
        case "failure":
            fail("server failure: \(message.message ?? "")")
        default:
            break
        }
    }

    func startAudio() {
        guard !started else { return }
        started = true
        guard let path = pcmPath, var pcm = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fail("missing --pcm=path")
            return
        }
        if pcm.count % 2 == 1 { pcm.removeLast() }
        self.pcm = pcm
        samples = pcm.count / 2
        if skipFirstFrame {
            journal.append(Data(pcm.prefix(640)))
            frames = 1
            offset = min(640, pcm.count)
        }
        log("AUDIO_START samples=\(samples) skip_first=\(skipFirstFrame) skip_start=\(skipStart)")
        if !skipStart {
            sendSealed(.audioStart(session: 1))
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.offset >= self.pcm.count {
                timer.cancel()
                self.log("AUDIO_END frames=\(self.frames) samples=\(self.samples)")
                self.sendSealed(.audioEnd(session: 1, samples: self.samples, frames: self.frames))
                return
            }
            let end = min(self.offset + 640, self.pcm.count)
            var chunk = self.pcm.subdata(in: self.offset..<end)
            if chunk.count % 2 == 1 { chunk.removeLast() }
            guard !chunk.isEmpty else { return }
            self.offset += chunk.count
            self.journal.append(chunk)
            if self.frames == dropFrame {
                self.log("DROP_FRAME seq=\(self.frames)")
                self.frames += 1
                return
            }
            let packet = AudioPacket(session: 1, seq: UInt32(self.frames), pcm: chunk)
            if let cipher = self.cipher, let sealed = try? cipher.seal(packet.encoded()) {
                self.send(LinkFrame(kind: .sealedAudio, payload: sealed))
                self.frames += 1
            }
        }
        timer.resume()
    }

    func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        log("FAILURE \(reason)")
        connection?.cancel()
        browser?.cancel()
        exit(2)
    }

    func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        log("DONE")
        connection?.cancel()
        browser?.cancel()
        exit(code)
    }
}

if pcmPath == nil {
    print("usage: imic-client --pcm=<raw pcm> [--code=123456] [--mac-id=UUID] [--name=...]")
    exit(2)
}
let client = TestClient()
client.start()
dispatchMain()
