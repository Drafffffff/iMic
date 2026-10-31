import Foundation
import Network
import CryptoKit

/// iMic 在局域网中作为 Bonjour 服务端出现；一台 Mac 同一时刻只服务一台 iPhone。
/// 所有链路状态都在私有串行队列上读写，UI 回调统一切回主线程。
final class LinkServer {
    enum State: Equatable {
        case starting
        case advertising
        case connected(String)
        case failed(String)
    }

    private enum Phase {
        case awaitingHello
        case awaitingAuth
        case awaitingPair
        case ready
    }

    /// 单条 TCP 连接及其握手状态。新连接先作为候选完成握手，
    /// 认证或配对成功后才替换当前 iPhone，未认证连接不能挤掉已就绪的链路。
    private final class Peer {
        let connection: NWConnection
        var decoder = LinkFrameDecoder()
        var phase: Phase = .awaitingHello
        var cipher: LinkCipher?
        var privateKey: Curve25519.KeyAgreement.PrivateKey?
        var peerPublicKey: String?
        var deviceID: String?
        var name: String?
        var pairAttempts = 0
        var lastReceiveAt = Date()
        var handshakeTimeout: DispatchWorkItem?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// 同时握手的候选连接上限；超出时淘汰最早的候选，不影响已就绪链路。
    private static let maxPendingPeers = 4

    let store: PairingStore
    private let fixedPort: UInt16?
    private let queue = DispatchQueue(label: "imic.link.server")
    private var listener: NWListener?
    private var active: Peer?
    private var pending: [Peer] = []
    private var heartbeat: DispatchSourceTimer?
    private var listenerPort: UInt16?

    var onState: ((State) -> Void)?
    var onMessage: ((LinkMessage) -> Void)?
    /// 第二个参数是 iPhone 在 `polish.settings` 中声明的能力位。
    var onPolishPreferences: ((LinkPolishPreferences, Int) -> Void)?
    var onAudio: ((AudioPacket) -> Void)?
    var onPairRequest: (() -> Void)?
    var onDisconnect: (() -> Void)?

    var connectedDeviceName: String? {
        queue.sync { active?.name }
    }

    var isConnected: Bool {
        queue.sync { active != nil }
    }

    /// 本机回环端口，供蓝牙 GATT 兜底桥接使用。
    var localPort: UInt16? {
        queue.sync { listenerPort }
    }

    init(store: PairingStore, port: UInt16? = nil) {
        self.store = store
        self.fixedPort = port
    }

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async {
            self.closeAllLocked(notify: false)
            self.listener?.cancel()
            self.listener = nil
            self.listenerPort = nil
        }
    }

    /// 主动断开当前 iPhone（例如用户在设置里解除配对）。
    func disconnect() {
        queue.async { self.closeAllLocked(notify: true) }
    }

    private func startLocked() {
        stopListenerLocked()
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener: NWListener
            if let port = fixedPort, let endpointPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: parameters, on: endpointPort)
            } else {
                listener = try NWListener(using: parameters)
            }
            let txt = NetService.data(fromTXTRecord: [
                "id": Data(store.macID.utf8),
                "v": Data("1".utf8)
            ])
            listener.service = NWListener.Service(
                name: Self.serviceName(store.macName),
                type: IMicLink.serviceType,
                domain: nil,
                txtRecord: txt
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.listenerPort = listener.port?.rawValue
                    self.emit(.advertising)
                case .failed(let error):
                    self.emit(.failed(error.localizedDescription))
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            emit(.starting)
            listener.start(queue: queue)
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private func stopListenerLocked() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        IMicLog.write("mac.link", "accept candidate peer=\(connection.endpoint) pending=\(pending.count) active=\(active != nil)")
        if pending.count >= Self.maxPendingPeers {
            closeLocked(pending[0], notify: false)
        }
        let peer = Peer(connection: connection)
        pending.append(peer)

        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer, self.isCurrent(peer) else { return }
            switch state {
            case .ready:
                self.armHandshakeTimeout(peer)
                self.receiveLocked(peer)
            case .failed, .cancelled:
                self.closeLocked(peer, notify: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func isCurrent(_ peer: Peer) -> Bool {
        active === peer || pending.contains { $0 === peer }
    }

    private func armHandshakeTimeout(_ peer: Peer) {
        peer.handshakeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak peer] in
            guard let self, let peer, self.isCurrent(peer), peer.phase != .ready else { return }
            self.sendErrorAndClose(peer, "handshake_timeout", L10n.text("Connection timed out. Please retry."))
        }
        peer.handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + IMicLink.handshakeTimeout, execute: work)
    }

    private func receiveLocked(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.isCurrent(peer) else { return }
                peer.lastReceiveAt = Date()
                if let data = data, !data.isEmpty {
                    do {
                        let frames = try peer.decoder.append(data)
                        for frame in frames {
                            try self.handle(frame, from: peer)
                            guard self.isCurrent(peer) else { return }
                        }
                    } catch {
                        self.sendErrorAndClose(peer, "protocol_data", L10n.text("Invalid connection data"))
                        return
                    }
                }
                if isComplete || error != nil {
                    self.closeLocked(peer, notify: true)
                    return
                }
                self.receiveLocked(peer)
            }
        }
    }

    private func handle(_ frame: LinkFrame, from peer: Peer) throws {
        switch peer.phase {
        case .ready:
            guard frame.kind != .json else {
                sendErrorAndClose(peer, "protocol_plaintext", L10n.text("Plaintext frames are not accepted after connection"))
                return
            }
            guard let cipher = peer.cipher else {
                sendErrorAndClose(peer, "protocol_key_missing", L10n.text("Connection key missing"))
                return
            }
            let plaintext = try cipher.open(frame.payload)
            switch frame.kind {
            case .sealedAudio:
                let packet = try AudioPacket.decode(plaintext)
                DispatchQueue.main.async { [weak self] in self?.onAudio?(packet) }
            case .sealedJSON:
                let message = try LinkMessage.decode(plaintext)
                if message.t == "audio.end" {
                    guard let samples = message.samples, let frames = message.frames,
                          IMicLink.isValidAudioEnd(samples: samples, frames: frames) else {
                        sendErrorAndClose(peer, "audio_end_invalid", L10n.text("Invalid audio end frame or sample count"))
                        return
                    }
                }
                if message.t == "polish.settings", let preferences = message.polish {
                    // LinkMessage 已验证 bit7 请求包含合法的完整模式、语气与语言。
                    // 将能力位一并交给 Mac 保存层，旧手机只能改开关，不覆盖新选项。
                    let features = message.features ?? 0
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.queue.sync(execute: { self.active === peer }) else { return }
                        self.onPolishPreferences?(preferences, features)
                    }
                } else if ["polish.saved", "settings", "input.state", "input.result"].contains(message.t) {
                    sendErrorAndClose(peer, "protocol_settings_direction", L10n.text("An iPhone cannot send Mac settings state"))
                } else if message.t == "ping" {
                    try sendLocked(.pong(message.ts ?? 0), to: peer)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.queue.sync(execute: { self.active === peer }) else { return }
                        self.onMessage?(message)
                    }
                }
            case .json:
                break
            }

        case .awaitingAuth:
            guard frame.kind == .sealedJSON, let cipher = peer.cipher else {
                sendErrorAndClose(peer, "handshake_frame", L10n.text("Invalid handshake frame"))
                return
            }
            guard let message = try? LinkMessage.decode(cipher.open(frame.payload)) else {
                sendErrorAndClose(peer, "auth", L10n.text("Incorrect pairing code or expired connection"))
                return
            }
            IMicLog.write("mac.link", "handshake message=\(message.t)")
            guard message.t == "auth", message.deviceID == nil || message.deviceID == peer.deviceID else {
                sendErrorAndClose(peer, "auth", L10n.text("Device token mismatch"))
                return
            }
            becomeReady(peer)

        case .awaitingPair:
            guard frame.kind == .sealedJSON,
                  let key = peer.privateKey,
                  let peerPublic = peer.peerPublicKey,
                  let deviceID = peer.deviceID else {
                sendErrorAndClose(peer, "handshake_frame", L10n.text("Invalid handshake frame"))
                return
            }
            // 冷却期间不解密，也不计入错误次数，避免冷却本身成为猜码通道。
            if let remaining = store.pairingLockRemaining() {
                try sendPlainLocked(.error("pair_locked", Self.lockedMessage(remaining)), to: peer)
                return
            }
            // 每次尝试都按当前配对码派生密钥，配对码在等待期间过期或被手动更换也能用新码配对。
            let pairCipher = try LinkCrypto.pairingCipher(
                privateKey: key,
                peerPublicKey: peerPublic,
                code: store.currentCode()
            )
            guard let message = try? LinkMessage.decode(pairCipher.open(frame.payload)) else {
                peer.pairAttempts += 1
                if let remaining = store.recordPairFailure() {
                    IMicLog.write("mac.link", "pair locked seconds=\(Int(remaining.rounded(.up)))")
                    try sendPlainLocked(.error("pair_locked", Self.lockedMessage(remaining)), to: peer)
                } else if peer.pairAttempts < 3 {
                    try sendPlainLocked(.error("pair_code", L10n.text("Incorrect pairing code")), to: peer)
                } else {
                    sendErrorAndClose(peer, "auth", L10n.text("Incorrect pairing code or expired connection"))
                }
                return
            }
            IMicLog.write("mac.link", "handshake message=\(message.t)")
            guard message.t == "pair",
                  message.deviceID == deviceID,
                  let rawToken = message.token,
                  let token = Data(base64Encoded: rawToken),
                  token.count == 32,
                  let name = message.deviceName ?? peer.name
            else {
                sendErrorAndClose(peer, "pair_invalid", L10n.text("Invalid pairing information"))
                return
            }
            do {
                try store.trust(deviceID: deviceID, name: name, token: token)
            } catch {
                IMicLog.write("mac.link", "trust save failed=\(String(describing: error))")
                sendErrorAndClose(peer, "pair_save_failed", L10n.text("Could not save pairing information"))
                return
            }
            // 先用配对密钥确认成功，再切换到长期令牌派生的会话密钥。
            try sendLocked(.paired(macID: store.macID, name: store.macName), to: peer, using: pairCipher)
            peer.cipher = try LinkCrypto.sessionCipher(privateKey: key, peerPublicKey: peerPublic, token: token)
            becomeReady(peer)

        case .awaitingHello:
            guard frame.kind == .json else {
                sendErrorAndClose(peer, "handshake_required", L10n.text("Handshake required"))
                return
            }
            let message = try LinkMessage.decode(frame.payload)
            IMicLog.write("mac.link", "hello device=\(message.deviceName ?? "-") hasToken=\(message.hasToken ?? false)")
            guard message.t == "hello",
                  let deviceID = message.deviceID,
                  UUID(uuidString: deviceID) != nil,
                  let name = message.deviceName, !name.isEmpty,
                  let peerPublic = message.publicKey,
                  (try? LinkCrypto.parsePublicKey(peerPublic)) != nil
            else {
                sendErrorAndClose(peer, "handshake_invalid", L10n.text("Invalid handshake information"))
                return
            }
            peer.deviceID = deviceID
            peer.name = String(name.prefix(64))
            peer.peerPublicKey = peerPublic
            let key = LinkCrypto.makePrivateKey()
            peer.privateKey = key
            let serverPublic = LinkCrypto.publicKeyBase64(key)

            if message.hasToken == true, let token = store.token(for: deviceID) {
                guard let session = try? LinkCrypto.sessionCipher(
                    privateKey: key,
                    peerPublicKey: peerPublic,
                    token: token
                ) else {
                    sendErrorAndClose(peer, "crypto", L10n.text("Could not negotiate a session key"))
                    return
                }
                peer.cipher = session
                peer.phase = .awaitingAuth
                try sendPlainLocked(.helloReply(
                    macID: store.macID,
                    name: store.macName,
                    publicKey: serverPublic,
                    status: "auth"
                ), to: peer)
            } else {
                peer.phase = .awaitingPair
                try sendPlainLocked(.helloReply(
                    macID: store.macID,
                    name: store.macName,
                    publicKey: serverPublic,
                    status: "pair_required"
                ), to: peer)
                DispatchQueue.main.async { [weak self] in self?.onPairRequest?() }
            }
        }
    }

    private func becomeReady(_ peer: Peer) {
        IMicLog.write("mac.link", "become ready device=\(peer.name ?? "-") replacing=\(active != nil)")
        pending.removeAll { $0 === peer }
        // 只有通过认证的新连接才替换旧链路；旧连接按断开处理，会话状态由上层清理。
        if let previous = active {
            closeLocked(previous, notify: true)
        }
        peer.phase = .ready
        peer.handshakeTimeout?.cancel()
        peer.handshakeTimeout = nil
        active = peer
        emit(.connected(peer.name ?? "iPhone"))
        sendActiveAsync(.ready())
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, let peer = self.active else { return }
            if Date().timeIntervalSince(peer.lastReceiveAt) > 40 {
                self.sendErrorAndClose(peer, "connection_timeout", L10n.text("Connection expired"))
                return
            }
            self.sendActiveAsync(.ping(Date().timeIntervalSince1970))
        }
        heartbeat = timer
        timer.resume()
    }

    private func closeLocked(_ peer: Peer, notify: Bool) {
        let wasActive = active === peer
        guard wasActive || pending.contains(where: { $0 === peer }) else { return }
        IMicLog.write("mac.link", "close connection notify=\(notify) active=\(wasActive) phase=\(String(describing: peer.phase))")
        peer.handshakeTimeout?.cancel()
        peer.handshakeTimeout = nil
        peer.connection.stateUpdateHandler = nil
        peer.connection.cancel()
        peer.decoder.reset()
        peer.cipher = nil
        peer.privateKey = nil
        if wasActive {
            active = nil
            heartbeat?.cancel()
            heartbeat = nil
            if notify {
                DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
            }
        } else {
            pending.removeAll { $0 === peer }
        }
    }

    private func closeAllLocked(notify: Bool) {
        pending.forEach { closeLocked($0, notify: false) }
        if let active { closeLocked(active, notify: notify) }
    }

    private func sendErrorAndClose(_ peer: Peer, _ code: String, _ message: String) {
        IMicLog.write("mac.link", "error code=\(code) message=\(message)")
        guard isCurrent(peer) else { return }
        // 发送失败也要确保连接被回收；错误文本只描述原因，不包含令牌或音频。
        let data = LinkWire.encode(kind: .json, payload: (try? LinkMessage.error(code, message).encoded()) ?? Data())
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.closeLocked(peer, notify: true) }
        })
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.closeLocked(peer, notify: true)
        }
    }

    // MARK: - Sending

    // Keep message populated for old phones; new phones translate code locally.
    func send(_ message: LinkMessage) {
        sendActiveAsync(message)
    }

    private func sendActiveAsync(_ message: LinkMessage) {
        queue.async {
            guard let peer = self.active, peer.cipher != nil else { return }
            do { try self.sendLocked(message, to: peer) }
            catch { self.sendErrorAndClose(peer, "protocol_send", L10n.text("Connection send failed")) }
        }
    }

    private func sendPlainLocked(_ message: LinkMessage, to peer: Peer) throws {
        let payload = try message.encoded()
        writeFrameLocked(LinkFrame(kind: .json, payload: payload), to: peer)
    }

    private func sendLocked(_ message: LinkMessage, to peer: Peer, using explicit: LinkCipher? = nil) throws {
        guard let cipher = explicit ?? peer.cipher else { throw LinkError.encodingFailed }
        let payload = try message.encoded()
        let sealed = try cipher.seal(payload)
        writeFrameLocked(LinkFrame(kind: .sealedJSON, payload: sealed), to: peer)
    }

    private func writeFrameLocked(_ frame: LinkFrame, to peer: Peer) {
        let data = LinkWire.encode(frame)
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            IMicLog.write("mac.link", "send error: \(String(describing: error))")
            self?.queue.async { self?.closeLocked(peer, notify: true) }
        })
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private static func lockedMessage(_ remaining: TimeInterval) -> String {
        L10n.text("Too many attempts. The pairing code has changed. Wait %@ seconds, then enter the new code shown on your Mac.", L10n.argument(Int(remaining.rounded(.up))))
    }

    private static func serviceName(_ macName: String) -> String {
        var name = "iMic · \(macName)"
        // Bonjour 服务名上限为 63 字节，按 UTF-8 截断且不切断字符。
        while name.utf8.count > 60 { name.removeLast() }
        return name
    }
}
