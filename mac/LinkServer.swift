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

    let store: PairingStore
    private let fixedPort: UInt16?
    private let queue = DispatchQueue(label: "imic.link.server")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = LinkFrameDecoder()
    private var phase: Phase = .awaitingHello
    private var cipher: LinkCipher?
    private var pendingPairCipher: LinkCipher?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var peerPublicKey: String?
    private var clientDeviceID: String?
    private var clientName: String?
    private var pairAttempts = 0
    private var lastReceiveAt = Date()
    private var heartbeat: DispatchSourceTimer?
    private var handshakeTimeout: DispatchWorkItem?
    private var everConnected = false
    private var listenerPort: UInt16?

    var onState: ((State) -> Void)?
    var onMessage: ((LinkMessage) -> Void)?
    var onPolishPreferences: ((LinkPolishPreferences) -> Void)?
    var onAudio: ((AudioPacket) -> Void)?
    var onPairRequest: (() -> Void)?
    var onDisconnect: (() -> Void)?

    var connectedDeviceName: String? {
        queue.sync { phase == .ready ? clientName : nil }
    }

    var isConnected: Bool {
        queue.sync { phase == .ready }
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
            self.closeConnectionLocked(notify: false)
            self.listener?.cancel()
            self.listener = nil
            self.listenerPort = nil
            self.heartbeat?.cancel()
            self.heartbeat = nil
        }
    }

    /// 主动断开当前 iPhone（例如用户在设置里解除配对）。
    func disconnect() {
        queue.async { self.closeConnectionLocked(notify: true) }
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

    private func accept(_ newConnection: NWConnection) {
        IMicLog.write("mac.link", "accept new connection peer=\(newConnection.endpoint); replacing current")
        // 同一时间只保留最新连接；旧连接立即释放，避免僵尸链路占用识别通道。
        closeConnectionLocked(notify: true)
        connection = newConnection
        decoder.reset()
        phase = .awaitingHello
        cipher = nil
        pendingPairCipher = nil
        privateKey = nil
        peerPublicKey = nil
        clientDeviceID = nil
        clientName = nil
        pairAttempts = 0
        lastReceiveAt = Date()
        everConnected = false

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.armHandshakeTimeout()
                self.receiveLocked()
            case .failed, .cancelled:
                self.dropIfCurrent(newConnection)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func armHandshakeTimeout() {
        handshakeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.phase != .ready else { return }
            self.sendErrorAndClose("timeout", "连接超时，请重试")
        }
        handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + IMicLink.handshakeTimeout, execute: work)
    }

    private func receiveLocked() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                self.lastReceiveAt = Date()
                if let data = data, !data.isEmpty {
                    do {
                        let frames = try self.decoder.append(data)
                        for frame in frames {
                            try self.handle(frame, on: connection)
                        }
                    } catch {
                        self.sendErrorAndClose("protocol", "链路数据无效")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.dropIfCurrent(connection)
                    return
                }
                self.receiveLocked()
            }
        }
    }

    private func handle(_ frame: LinkFrame, on connection: NWConnection) throws {
        switch phase {
        case .ready:
            guard frame.kind != .json else {
                sendErrorAndClose("protocol", "已连接后不接受明文帧")
                return
            }
            guard let cipher = cipher else {
                sendErrorAndClose("protocol", "链路密钥缺失")
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
                        sendErrorAndClose("audio", "语音结束帧数或采样数无效")
                        return
                    }
                }
                if message.t == "polish.settings", let preferences = message.polish {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.queue.sync(execute: { self.connection === connection && self.phase == .ready }) else { return }
                        self.onPolishPreferences?(preferences)
                    }
                } else if message.t == "polish.saved" || message.t == "settings" {
                    sendErrorAndClose("protocol", "iPhone 不能发送 Mac 的设置状态")
                } else if message.t == "ping" {
                    try sendLocked(.pong(message.ts ?? 0))
                } else {
                    DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
                }
            case .json:
                break
            }

        case .awaitingAuth, .awaitingPair:
            guard frame.kind == .sealedJSON, let cipher = cipher else {
                sendErrorAndClose("protocol", "握手帧无效")
                return
            }
            let message: LinkMessage
            do {
                message = try LinkMessage.decode(cipher.open(frame.payload))
                IMicLog.write("mac.link", "handshake message=\(message.t) status=\(message.status ?? "-")")
            } catch {
                pairAttempts += 1
                if phase == .awaitingPair, pairAttempts < 3 {
                    try sendPlainLocked(.error("pair_code", "配对码不正确"))
                    return
                }
                sendErrorAndClose("auth", "配对码不正确或链路已失效")
                return
            }
            if phase == .awaitingAuth {
                guard message.t == "auth", message.deviceID == nil || message.deviceID == clientDeviceID else {
                    sendErrorAndClose("auth", "设备令牌不匹配")
                    return
                }
                becomeReady()
            } else {
                guard message.t == "pair",
                      message.deviceID == clientDeviceID,
                      let rawToken = message.token,
                      let token = Data(base64Encoded: rawToken),
                      token.count == 32,
                      let deviceID = clientDeviceID,
                      let name = message.deviceName ?? clientName
                else {
                    sendErrorAndClose("pair", "配对信息无效")
                    return
                }
                do {
                    try store.trust(deviceID: deviceID, name: name, token: token)
                } catch {
                    IMicLog.write("mac.link", "trust save failed=\(String(describing: error))")
                    sendErrorAndClose("pair", "无法保存配对信息")
                    return
                }
                // 先用配对密钥确认成功，再切换到长期令牌派生的会话密钥。
                if let pairCipher = pendingPairCipher, let key = privateKey, let peer = peerPublicKey {
                    try sendLocked(.paired(macID: store.macID, name: store.macName), using: pairCipher)
                    self.cipher = try LinkCrypto.sessionCipher(privateKey: key, peerPublicKey: peer, token: token)
                }
                becomeReady()
            }

        case .awaitingHello:
            guard frame.kind == .json else {
                sendErrorAndClose("protocol", "请先握手")
                return
            }
            let message = try LinkMessage.decode(frame.payload)
            IMicLog.write("mac.link", "hello device=\(message.deviceName ?? "-") hasToken=\(message.hasToken ?? false)")
            guard message.t == "hello",
                  let deviceID = message.deviceID,
                  UUID(uuidString: deviceID) != nil,
                  let name = message.deviceName, !name.isEmpty,
                  let peer = message.publicKey
            else {
                sendErrorAndClose("protocol", "握手信息无效")
                return
            }
            clientDeviceID = deviceID
            clientName = String(name.prefix(64))
            peerPublicKey = peer
            let key = LinkCrypto.makePrivateKey()
            privateKey = key
            let serverPublic = LinkCrypto.publicKeyBase64(key)

            if message.hasToken == true, let token = store.token(for: deviceID) {
                guard let session = try? LinkCrypto.sessionCipher(
                    privateKey: key,
                    peerPublicKey: peer,
                    token: token
                ) else {
                    sendErrorAndClose("crypto", "无法协商会话密钥")
                    return
                }
                cipher = session
                phase = .awaitingAuth
                try sendPlainLocked(.helloReply(
                    macID: store.macID,
                    name: store.macName,
                    publicKey: serverPublic,
                    status: "auth"
                ))
            } else {
                guard let pairCipher = try? LinkCrypto.pairingCipher(
                    privateKey: key,
                    peerPublicKey: peer,
                    code: store.currentCode()
                ) else {
                    sendErrorAndClose("crypto", "无法协商配对密钥")
                    return
                }
                cipher = pairCipher
                pendingPairCipher = pairCipher
                phase = .awaitingPair
                try sendPlainLocked(.helloReply(
                    macID: store.macID,
                    name: store.macName,
                    publicKey: serverPublic,
                    status: "pair_required"
                ))
                DispatchQueue.main.async { [weak self] in self?.onPairRequest?() }
            }
        }
    }

    private func becomeReady() {
        IMicLog.write("mac.link", "become ready device=\(clientName ?? "-")")
        phase = .ready
        pendingPairCipher = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        let name = clientName ?? "iPhone"
        everConnected = true
        emit(.connected(name))
        sendLockedAsync(.ready())
        startHeartbeat()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.phase == .ready else { return }
            if Date().timeIntervalSince(self.lastReceiveAt) > 40 {
                self.sendErrorAndClose("timeout", "连接已超时")
                return
            }
            self.sendLockedAsync(.ping(Date().timeIntervalSince1970))
        }
        heartbeat = timer
        timer.resume()
    }

    private func dropIfCurrent(_ candidate: NWConnection) {
        guard connection === candidate else { return }
        closeConnectionLocked(notify: true)
    }

    private func closeConnectionLocked(notify: Bool) {
        let wasReady = phase == .ready && everConnected
        IMicLog.write("mac.link", "close connection notify=\(notify) wasReady=\(wasReady) phase=\(String(describing: phase))")
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        heartbeat?.cancel()
        heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        decoder.reset()
        cipher = nil
        pendingPairCipher = nil
        privateKey = nil
        peerPublicKey = nil
        clientDeviceID = nil
        clientName = nil
        pairAttempts = 0
        phase = .awaitingHello
        everConnected = false
        if notify && wasReady {
            DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
        }
    }

    private func sendErrorAndClose(_ code: String, _ message: String) {
        IMicLog.write("mac.link", "error code=\(code) message=\(message)")
        // 发送失败也要确保连接被回收；错误文本只描述原因，不包含令牌或音频。
        if let connection = connection {
            let data = LinkWire.encode(kind: .json, payload: (try? LinkMessage.error(code, message).encoded()) ?? Data())
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.closeConnectionLocked(notify: true) }
            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.queue.async { self?.dropIfCurrent(connection) }
            }
        } else {
            closeConnectionLocked(notify: true)
        }
    }

    // MARK: - Sending

    func send(_ message: LinkMessage) {
        sendLockedAsync(message)
    }

    private func sendLockedAsync(_ message: LinkMessage) {
        queue.async {
            guard self.phase == .ready, self.cipher != nil else { return }
            do { try self.sendLocked(message) }
            catch { self.sendErrorAndClose("protocol", "链路发送失败") }
        }
    }

    private func sendPlainLocked(_ message: LinkMessage) throws {
        let payload = try message.encoded()
        try writeFrameLocked(LinkFrame(kind: .json, payload: payload))
    }

    private func sendLocked(_ message: LinkMessage, using explicit: LinkCipher? = nil) throws {
        guard let cipher = explicit ?? cipher else { throw LinkError.encodingFailed }
        let payload = try message.encoded()
        let sealed = try cipher.seal(payload)
        try writeFrameLocked(LinkFrame(kind: .sealedJSON, payload: sealed))
    }

    private func writeFrameLocked(_ frame: LinkFrame) throws {
        guard let connection = connection else { throw LinkError.encodingFailed }
        let data = LinkWire.encode(frame)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            IMicLog.write("mac.link", "send error: \(String(describing: error))")
            self?.queue.async {
                if self?.connection === connection {
                    self?.closeConnectionLocked(notify: true)
                }
            }
        })
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private static func serviceName(_ macName: String) -> String {
        var name = "iMic · \(macName)"
        // Bonjour 服务名上限为 63 字节，按 UTF-8 截断且不切断字符。
        while name.utf8.count > 60 { name.removeLast() }
        return name
    }
}
