import Foundation
import Network
import CryptoKit
import Security
import UIKit

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// iPhone 侧链路：Bonjour 发现 → Curve25519 握手 → 六位配对码 → 令牌会话。
/// 所有网络状态在私有串行队列，`@Published` 只在主线程更新。
final class LinkClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case connecting(String)
        case needsCode(String)
        case ready(String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var macName: String? {
            switch self {
            case .connecting(let name), .needsCode(let name), .ready(let name): return name
            default: return nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var pairingError: String?
    @Published private(set) var pairing = false
    @Published private(set) var hasPairedMac = false

    var onReady: ((String) -> Void)?
    var onLost: (() -> Void)?
    var onResult: ((LinkMessage) -> Void)?
    var onRemoteState: ((String) -> Void)?
    var onAudioNeed: ((UInt16, UInt32) -> Void)?
    var onSettings: ((Int) -> Void)?

    private let isPreview: Bool
    private let queue = DispatchQueue(label: "imic.link.ios")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var decoder = LinkFrameDecoder()
    private var privateKey = LinkCrypto.makePrivateKey()
    private var serverPublic: String?
    private var cipher: LinkCipher?
    private var pairingCipher: LinkCipher?
    private var pendingToken: Data?
    private var ready = false
    private var running = false
    private var lastMac: DiscoveredMac?
    private var currentMacID: String?
    private var currentMacName: String?
    private var preferredMacID: String?
    private var pendingCode: String?
    private var needsCode = false
    private var forcePair = false
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var waitingWork: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var connectionGeneration = 0
    private var bleClient: BLELinkClient?
    private var usingBLE = false
    private var bleFallbackWork: DispatchWorkItem?
    private let forceBLE: Bool

    private let deviceID: String
    private let deviceName: String
    private let directMac: DiscoveredMac?
    private let autoPairCode: String?

    init() {
        isPreview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-preview=") }
        if let stored = UserDefaults.standard.string(forKey: "imic.deviceID"),
           UUID(uuidString: stored) != nil {
            deviceID = stored
        } else {
            let value = UUID().uuidString
            UserDefaults.standard.set(value, forKey: "imic.deviceID")
            deviceID = value
        }
        deviceName = UIDevice.current.name.isEmpty ? "iPhone" : String(UIDevice.current.name.prefix(48))
        preferredMacID = UserDefaults.standard.string(forKey: "imic.preferredMacID")
        hasPairedMac = preferredMacID != nil

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        forceBLE = args.contains("--debug-ble")
        let host = args.first { $0.hasPrefix("--debug-host=") }
            .map { String($0.dropFirst("--debug-host=".count)) }
        let port = args.first { $0.hasPrefix("--debug-port=") }
            .flatMap { UInt16($0.dropFirst("--debug-port=".count)) }
        if let host = host, let port = port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            directMac = DiscoveredMac(
                id: "direct",
                name: "Direct Mac",
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
            )
        } else {
            directMac = nil
        }
        autoPairCode = args.first { $0.hasPrefix("--debug-pair-code=") }
            .map { PairingCode.normalize(String($0.dropFirst("--debug-pair-code=".count))) }
        #else
        directMac = nil
        autoPairCode = nil
        forceBLE = false
        #endif

        if isPreview {
            let name = "MacBook Pro"
            let mac = DiscoveredMac(
                id: "preview-mac",
                name: name,
                endpoint: .hostPort(host: "127.0.0.1", port: 1)
            )
            macs = [mac]
            lastMac = mac
            let mode = ProcessInfo.processInfo.arguments
                .first { $0.hasPrefix("--ui-preview=") }?
                .replacingOccurrences(of: "--ui-preview=", with: "") ?? "idle"
            switch mode {
            case "pairing": phase = .needsCode(name)
            case "offline": phase = .searching
            default: phase = .ready(name)
            }
            hasPairedMac = phase.isReady
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isPreview, !running else { return }
        running = true
        queue.async {
            if self.forceBLE {
                self.startBLELocked()
                return
            }
            if let mac = self.directMac {
                self.connectLocked(to: mac)
            } else {
                self.startBrowserLocked()
            }
            self.scheduleBLEFallback(after: 3)
        }
    }

    func activate() {
        guard !isPreview else { return }
        if !running {
            start()
            return
        }
        queue.async {
            if self.connection == nil, let mac = self.lastMac {
                self.connectLocked(to: mac)
            }
        }
    }

    func retry() {
        guard !isPreview else { return }
        queue.async {
            self.reconnectWork?.cancel()
            self.reconnectAttempts = 0
            self.needsCode = false
            self.bleClient?.stop()
            self.bleClient = nil
            self.usingBLE = false
            if self.forceBLE {
                self.startBLELocked()
            } else if let mac = self.lastMac {
                self.connectLocked(to: mac)
            } else {
                self.startBrowserLocked()
            }
            self.scheduleBLEFallback(after: 3)
        }
    }

    func connect(to mac: DiscoveredMac) {
        guard !isPreview else { return }
        queue.async { self.connectLocked(to: mac) }
    }

    func forgetMac() {
        guard !isPreview else { return }
        queue.async {
            if let id = self.currentMacID ?? self.preferredMacID {
                TokenStore.delete(for: id)
            }
            UserDefaults.standard.removeObject(forKey: "imic.preferredMacID")
            self.preferredMacID = nil
            self.pendingCode = nil
            self.needsCode = false
            self.forcePair = true
            self.closeConnectionLocked()
            self.startBrowserLocked()
            self.publish {
                self.phase = .searching
                self.macs = []
                self.pairingError = nil
                self.pairing = false
                self.hasPairedMac = false
            }
        }
    }

    // MARK: - Discovery

    private func startBrowserLocked() {
        guard running else { return }
        if let mac = directMac {
            connectLocked(to: mac)
            return
        }
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: IMicLink.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed(let error):
                self.publish {
                    self.phase = .failed("无法搜索 Mac · \(Self.readable(error))")
                }
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.running, !self.ready else { return }
                    self.startBrowserLocked()
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            let macs = results.compactMap { result -> DiscoveredMac? in
                var id: String?
                var name: String?
                if case .bonjour(let txt) = result.metadata {
                    id = txt["id"]
                }
                if case let .service(serviceName, _, _, _) = result.endpoint {
                    name = serviceName
                        .replacingOccurrences(of: "iMic · ", with: "")
                        .replacingOccurrences(of: "iMic - ", with: "")
                }
                let identifier = id ?? result.endpoint.debugDescription
                let display = name ?? "Mac"
                return DiscoveredMac(id: identifier, name: display, endpoint: result.endpoint)
            }
            self.publish { self.macs = macs }
            self.autoConnect(macs)
        }
        browser.start(queue: queue)
        publish {
            if !self.phase.isReady, !self.phase.macNameIsConnecting, !self.pairing {
                self.phase = .searching
            }
        }
    }

    private func autoConnect(_ discovered: [DiscoveredMac]) {
        guard !ready, connection == nil else { return }
        if let preferred = preferredMacID,
           let match = discovered.first(where: { $0.id == preferred }) {
            connectLocked(to: match)
            return
        }
        if discovered.count == 1 {
            connectLocked(to: discovered[0])
        }
    }

    // MARK: - Connection

    private func connectLocked(to mac: DiscoveredMac) {
        guard running, !ready else { return }
        reconnectWork?.cancel()
        handshakeWork?.cancel()
        closeConnectionLocked()
        lastMac = mac
        if UUID(uuidString: mac.id) != nil {
            currentMacID = mac.id
        } else if currentMacID == nil {
            currentMacID = preferredMacID
        }
        currentMacName = mac.name
        privateKey = LinkCrypto.makePrivateKey()
        decoder.reset()
        serverPublic = nil
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        forcePair = false
        connectionGeneration += 1
        let generation = connectionGeneration
        publish { self.phase = .connecting(mac.name) }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.waitingWork?.cancel()
                self.waitingWork = nil
                self.sendHello()
                self.receive()
            case .waiting(let error):
                self.publish { self.phase = .connecting("\(mac.name) · \(Self.readable(error))") }
                // NWConnection 在 localhost 上可能长期停在 waiting；主动关闭重连，
                // 让「Mac 稍后才启动」也能在录音超时前接上。
                self.waitingWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.connection === connection, !self.ready else { return }
                    self.connectionLost(generation: generation, reason: "连接重试")
                }
                self.waitingWork = work
                self.queue.asyncAfter(deadline: .now() + 2, execute: work)
            case .failed(let error):
                self.connectionLost(generation: generation, reason: Self.readable(error))
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection === connection, !self.ready else { return }
            self.connectionLost(generation: generation, reason: "连接超时")
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + IMicLink.handshakeTimeout, execute: work)
    }

    private func sendHello() {
        let token = currentMacID.flatMap { TokenStore.load(for: $0) }
        let hasToken = token != nil && !forcePair
        sendPlain(.hello(
            deviceID: deviceID,
            deviceName: deviceName,
            publicKey: LinkCrypto.publicKeyBase64(privateKey),
            hasToken: hasToken
        ))
    }

    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let data = data, !data.isEmpty {
                    do {
                        for frame in try self.decoder.append(data) {
                            try self.handle(frame)
                        }
                    } catch {
                        self.closeConnectionLocked()
                        self.fail("链路数据异常，请重试")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.connectionLost(
                        generation: self.connectionGeneration,
                        reason: error.map(Self.readable) ?? "连接已断开"
                    )
                    return
                }
                self.receive()
            }
        }
    }

    private func handle(_ frame: LinkFrame) throws {
        switch frame.kind {
        case .json:
            let message = try LinkMessage.decode(frame.payload)
            try handlePlain(message)
        case .sealedJSON:
            guard let cipher = cipher else { throw LinkError.decryptionFailed }
            let message = try LinkMessage.decode(cipher.open(frame.payload))
            handleSealed(message)
        case .sealedAudio:
            break
        }
    }

    private func handlePlain(_ message: LinkMessage) throws {
        if message.t == "error" {
            handleServerError(message)
            return
        }
        guard message.t == "hello", let serverPublic = message.publicKey else {
            throw LinkError.decodingFailed
        }
        self.serverPublic = serverPublic
        if let macID = message.macID { currentMacID = macID }
        if let name = message.name { currentMacName = name }
        if let macID = currentMacID {
            preferredMacID = macID
            UserDefaults.standard.set(macID, forKey: "imic.preferredMacID")
        }
        let name = currentMacName ?? "Mac"

        switch message.status {
        case "auth":
            guard let macID = currentMacID,
                  let token = TokenStore.load(for: macID)
            else {
                // Mac 记得我们，但本机令牌已丢失：改成首次配对。
                forcePair = true
                reconnectAfterReset()
                return
            }
            cipher = try LinkCrypto.sessionCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                token: token
            )
            sendSealed(.auth())
            publish { self.phase = .connecting(name) }
        case "pair_required":
            if let code = autoPairCode, code.count == 6 {
                publish { self.phase = .connecting(name) }
                submit(code)
            } else {
                needsCode = true
                publish {
                    self.pairing = true
                    self.pairingError = nil
                    self.phase = .needsCode(name)
                }
                if let code = pendingCode {
                    submit(code)
                }
            }
        default:
            throw LinkError.decodingFailed
        }
    }

    private func handleSealed(_ message: LinkMessage) {
        switch message.t {
        case "paired":
            if let macID = currentMacID, let token = pendingToken {
                TokenStore.save(token, for: macID)
            }
            if let token = pendingToken, let serverPublic = serverPublic {
                cipher = try? LinkCrypto.sessionCipher(
                    privateKey: privateKey,
                    peerPublicKey: serverPublic,
                    token: token
                )
            }
            pendingToken = nil
            pairingCipher = nil
            pendingCode = nil
            needsCode = false
            let name = currentMacName ?? "Mac"
            publish {
                self.pairingError = nil
                self.hasPairedMac = true
                self.phase = .connecting(name)
            }
        case "ready":
            ready = true
            needsCode = false
            bleFallbackWork?.cancel()
            bleFallbackWork = nil
            IMicLog.write("iphone.link", "ready mac=\(currentMacName ?? "-")")
            handshakeWork?.cancel()
            reconnectAttempts = 0
            let name = currentMacName ?? "Mac"
            publish {
                self.phase = .ready(name)
                self.pairing = false
                self.pairingError = nil
                self.hasPairedMac = true
            }
            DispatchQueue.main.async { self.onReady?(name) }
        case "state":
            IMicLog.write("iphone.link", "state=\(message.phase ?? "?") session=\(message.session ?? -1)")
            if let phase = message.phase {
                DispatchQueue.main.async { self.onRemoteState?(phase) }
            }
        case "settings":
            let features = message.features ?? 0
            IMicLog.write("iphone.link", "settings features=\(features)")
            DispatchQueue.main.async { self.onSettings?(features) }
        case "audio.need":
            if let rawSession = message.session, let rawFrom = message.seq,
               rawSession >= 0, rawSession <= 65_535, rawFrom >= 0 {
                IMicLog.write("iphone.link", "audio.need session=\(rawSession) from=\(rawFrom)")
                let session = UInt16(rawSession)
                let from = UInt32(clamping: rawFrom)
                DispatchQueue.main.async { self.onAudioNeed?(session, from) }
            } else {
                IMicLog.write("iphone.link", "audio.need invalid")
            }
        case "result", "failure":
            IMicLog.write("iphone.link", "\(message.t) session=\(message.session ?? -1) chars=\(message.text?.count ?? 0) code=\(message.code ?? "-")")
            DispatchQueue.main.async { self.onResult?(message) }
        case "ping":
            sendSealed(.pong(message.ts ?? 0))
        default:
            break
        }
    }

    private func handleServerError(_ message: LinkMessage) {
        let code = message.code ?? "unknown"
        let text = message.message ?? "链路错误"
        if code == "pair_code" {
            let name = currentMacName ?? "Mac"
            publish {
                self.pairing = true
                self.pairingError = "配对码不正确，请重试"
                self.phase = .needsCode(name)
            }
            return
        }
        if code == "auth" {
            if let macID = currentMacID {
                TokenStore.delete(for: macID)
            }
            forcePair = true
            reconnectAfterReset()
            return
        }
        fail(text)
    }

    private func reconnectAfterReset() {
        handshakeWork?.cancel()
        closeConnectionLocked()
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let mac = self.lastMac else { return }
            self.connectLocked(to: mac)
        }
    }

    private func connectionLost(generation: Int, reason: String) {
        guard generation == connectionGeneration else { return }
        let wasReady = ready
        ready = false
        IMicLog.write("iphone.link", "connection lost ready=\(wasReady) reason=\(reason)")
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if wasReady {
            DispatchQueue.main.async { self.onLost?() }
        }
        guard running else { return }
        if needsCode {
            needsCode = false
            publish {
                self.pairing = true
                self.pairingError = "连接已断开，请重试"
            }
            scheduleReconnect(reason: reason)
            return
        }
        publish { self.phase = .searching }
        scheduleReconnect(reason: reason)
    }

    private func scheduleBLEFallback(after delay: TimeInterval) {
        guard running, !usingBLE else { return }
        bleFallbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, !self.ready, !self.usingBLE else { return }
            self.startBLELocked()
        }
        bleFallbackWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startBLELocked() {
        guard running, !ready, !usingBLE else { return }
        bleFallbackWork?.cancel()
        bleFallbackWork = nil
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        browser?.cancel()
        browser = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        serverPublic = nil
        usingBLE = true
        let ble = BLELinkClient()
        bleClient = ble
        ble.onConnected = { [weak self] in
            self?.queue.async { self?.bleConnected(ble) }
        }
        ble.onData = { [weak self] data in
            self?.queue.async { self?.bleReceived(ble, data: data) }
        }
        ble.onLost = { [weak self] in
            self?.queue.async { self?.bleLost(ble) }
        }
        IMicLog.write("iphone.link", "start BLE fallback")
        publish { self.phase = .connecting("蓝牙") }
        ble.start()
    }

    private func bleConnected(_ ble: BLELinkClient) {
        guard running, usingBLE, bleClient === ble else { return }
        privateKey = LinkCrypto.makePrivateKey()
        decoder.reset()
        serverPublic = nil
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        forcePair = false
        currentMacID = preferredMacID ?? currentMacID
        currentMacName = "Mac"
        IMicLog.write("iphone.link", "BLE connected; send hello mac=\(currentMacID ?? "-")")
        publish { self.phase = .connecting("蓝牙") }
        sendHello()
    }

    private func bleReceived(_ ble: BLELinkClient, data: Data) {
        guard usingBLE, bleClient === ble else { return }
        do {
            for frame in try decoder.append(data) {
                try handle(frame)
            }
        } catch {
            IMicLog.write("iphone.link", "BLE frame error=\(String(describing: error))")
            bleLost(ble)
        }
    }

    private func bleLost(_ ble: BLELinkClient) {
        guard usingBLE, bleClient === ble else { return }
        IMicLog.write("iphone.link", "BLE lost")
        usingBLE = false
        bleClient = nil
        ble.stop()
        ready = false
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        publish { self.phase = .searching }
        if running {
            scheduleReconnect(reason: "蓝牙断开")
            scheduleBLEFallback(after: 3)
        }
    }

    private func scheduleReconnect(reason: String) {
        reconnectWork?.cancel()
        guard running else { return }
        reconnectAttempts += 1
        let delay = min(8, pow(1.6, Double(reconnectAttempts - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, !self.ready else { return }
            if let mac = self.lastMac {
                self.connectLocked(to: mac)
            } else {
                self.startBrowserLocked()
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        scheduleBLEFallback(after: delay + 2)
    }

    private func closeConnectionLocked() {
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        bleClient?.stop()
        bleClient = nil
        usingBLE = false
    }

    private func fail(_ message: String) {
        publish {
            self.phase = .failed(message)
            self.pairing = false
        }
        scheduleReconnect(reason: message)
    }

    // MARK: - Pairing

    /// 用户输入六位配对码。连接未就绪时会记住并在连上后自动提交。
    func submitCode(_ raw: String) {
        let code = PairingCode.normalize(raw)
        guard code.count == 6 else {
            publish { self.pairingError = "请输入 6 位配对码" }
            return
        }
        queue.async {
            self.pendingCode = code
            if self.connection == nil {
                if let mac = self.lastMac { self.connectLocked(to: mac) }
                return
            }
            self.submit(code)
        }
    }

    private func submit(_ code: String) {
        guard let serverPublic = serverPublic else { return }
        do {
            let pairCipher = try LinkCrypto.pairingCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                code: code
            )
            pairingCipher = pairCipher
            cipher = pairCipher
            var generator = SystemRandomNumberGenerator()
            let token = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
            pendingToken = token
            publish {
                self.pairing = true
                self.pairingError = nil
                self.phase = .connecting(self.currentMacName ?? "Mac")
            }
            sendSealed(.pair(
                deviceID: deviceID,
                deviceName: deviceName,
                token: token.base64EncodedString()
            ))
        } catch {
            publish { self.pairingError = "配对码格式错误" }
        }
    }

    // MARK: - Audio / control

    func beginSession(_ session: UInt16) {
        IMicLog.write("iphone.link", "send audio.start session=\(session)")
        enqueue(.audioStart(session: Int(session)))
    }

    func sendAudio(_ pcm: Data, session: UInt16, seq: UInt32) {
        queue.async {
            guard self.ready, let cipher = self.cipher, !pcm.isEmpty else {
                IMicLog.write("iphone.link", "drop audio session=\(session) seq=\(seq) bytes=\(pcm.count) ready=\(self.ready) cipher=\(self.cipher != nil)")
                return
            }
            let packet = AudioPacket(session: session, seq: seq, pcm: pcm)
            guard let sealed = try? cipher.seal(packet.encoded()) else {
                IMicLog.write("iphone.link", "seal failed session=\(session) seq=\(seq)")
                return
            }
            if seq % 25 == 0 {
                IMicLog.write("iphone.link", "send audio session=\(session) seq=\(seq) bytes=\(pcm.count)")
            }
            self.sendFrame(LinkFrame(kind: .sealedAudio, payload: sealed))
        }
    }

    func endSession(_ session: UInt16, samples: Int, frames: Int) {
        IMicLog.write("iphone.link", "send audio.end session=\(session) samples=\(samples) frames=\(frames)")
        enqueue(.audioEnd(session: Int(session), samples: samples, frames: frames))
    }

    func cancelSession(_ session: UInt16) {
        IMicLog.write("iphone.link", "send audio.cancel session=\(session)")
        enqueue(.audioCancel(session: Int(session)))
    }

    func sendInput(_ action: String) {
        IMicLog.write("iphone.link", "send input=\(action)")
        enqueue(.input(action))
    }

    func sendPreview(_ text: String) {
        enqueue(.preview(text))
    }

    private func enqueue(_ message: LinkMessage) {
        queue.async {
            guard self.ready else {
                IMicLog.write("iphone.link", "drop \(message.t) ready=false")
                return
            }
            self.sendSealed(message)
        }
    }

    private func sendPlain(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        sendFrame(LinkFrame(kind: .json, payload: data))
    }

    private func sendSealed(_ message: LinkMessage) {
        guard let cipher = cipher, let data = try? message.encoded(),
              let sealed = try? cipher.seal(data) else { return }
        sendFrame(LinkFrame(kind: .sealedJSON, payload: sealed))
    }

    private func sendFrame(_ frame: LinkFrame) {
        if usingBLE, let ble = bleClient {
            ble.send(LinkWire.encode(frame))
            return
        }
        guard let connection = connection else {
            IMicLog.write("iphone.link", "send frame without connection kind=\(frame.kind.rawValue)")
            return
        }
        connection.send(content: LinkWire.encode(frame), completion: .contentProcessed { [weak self] error in
            guard error != nil, let self = self else { return }
            IMicLog.write("iphone.link", "send error kind=\(frame.kind.rawValue): \(String(describing: error))")
            self.queue.async {
                if self.connection === connection {
                    self.connectionLost(generation: self.connectionGeneration, reason: "发送失败")
                }
            }
        })
    }

    // MARK: - Helpers

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private static func readable(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Mac 拒绝连接"
            case .ENETUNREACH, .EHOSTUNREACH: return "网络不可达"
            case .ETIMEDOUT: return "连接超时"
            default: return "网络错误"
            }
        case .dns: return "无法解析 Mac 地址"
        case .tls: return "加密握手失败"
        default: return "连接失败"
        }
    }
}

extension LinkClient.Phase {
    var macNameIsConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// 已经配对过的设备允许「先录、后连」，把 20ms 帧暂存起来。
    var allowsBufferedRecording: Bool {
        switch self {
        case .ready, .searching, .connecting, .failed, .idle: return true
        case .needsCode: return false
        }
    }
}

enum Keychain {
    private static let service = "com.drafffffff.imic.link"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 生产环境只使用钥匙串。模拟器构建未签名时 Keychain 返回 errSecMissingEntitlement，
/// 因此仅在模拟器追加一个受数据保护的应用容器文件，保证本地联调可重复。
enum TokenStore {
    static func save(_ data: Data, for macID: String) {
        Keychain.save(data, account: "token:\(macID)")
        #if targetEnvironment(simulator)
        FileToken.save(data, for: macID)
        #endif
    }

    static func load(for macID: String) -> Data? {
        if let data = Keychain.load(account: "token:\(macID)") {
            return data
        }
        #if targetEnvironment(simulator)
        return FileToken.load(for: macID)
        #else
        return nil
        #endif
    }

    static func delete(for macID: String) {
        Keychain.delete(account: "token:\(macID)")
        #if targetEnvironment(simulator)
        FileToken.delete(for: macID)
        #endif
    }
}

#if targetEnvironment(simulator)
private enum FileToken {
    static func directory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    static func url(for macID: String) -> URL? {
        guard let directory = try? directory() else { return nil }
        let digest = SHA256.hash(data: Data(macID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("token-\(digest).bin")
    }

    static func save(_ data: Data, for macID: String) {
        guard let url = url(for: macID) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(for macID: String) -> Data? {
        guard let url = url(for: macID),
              let data = try? Data(contentsOf: url),
              data.count == 32 else { return nil }
        return data
    }

    static func delete(for macID: String) {
        guard let url = url(for: macID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
