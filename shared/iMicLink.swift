import Foundation
import CryptoKit

/// iMic Link 1.0 — Bonjour 发现之上的加密帧协议。
///
/// 设计目标：
/// - 控件与音频共用一条 TCP 流，20ms 音频帧天然有序，不需要重传窗口。
/// - 先用 Curve25519 交换临时密钥，再用六位配对码派生密钥完成首次信任。
/// - 配对成功后双方保存 32 字节令牌，后续会话密钥 = HKDF(ECDH, salt: 令牌)。
/// - 每一帧用 AES-GCM 独立封装（随机 nonce），篡改或重放都会被拒绝。
public enum IMicLink {
    public static let version = 1
    public static let serviceType = "_imic._tcp"
    public static let maxPayload = 128 * 1024
    public static let sampleRate = 16_000
    /// 20ms @ 16kHz mono PCM16.
    public static let frameSamples = 320
    public static let maxSessionSeconds = 600
    /// 少于该时长的误触不送去识别。
    public static let minimumSamples = 8_000
    public static let handshakeTimeout: TimeInterval = 12
    public static let pairingCodeLifetime: TimeInterval = 600
    public static let polishPreferencesFeature = 1 << 4
    public static let gestureControlFeature = 1 << 5
    public static let bleServiceUUID = "7E570000-7F4A-4C7E-9A2B-1C0D5E6F7A80"
    public static let bleUplinkUUID = "7E570001-7F4A-4C7E-9A2B-1C0D5E6F7A80"
    public static let bleDownlinkUUID = "7E570002-7F4A-4C7E-9A2B-1C0D5E6F7A80"
    /// 只用于发现时筛选目标；信任仍由后续密钥握手建立。
    public static let bleIdentityUUID = "7E570003-7F4A-4C7E-9A2B-1C0D5E6F7A80"

    public static func isValidAudioEnd(samples: Int, frames: Int) -> Bool {
        guard samples > 0, samples <= sampleRate * maxSessionSeconds, frames > 0 else { return false }
        return frames == (samples + frameSamples - 1) / frameSamples
    }
}

public enum LinkFrameKind: UInt8 {
    case json = 1
    case sealedJSON = 2
    case sealedAudio = 3
}

public struct LinkFrame: Equatable {
    public let kind: LinkFrameKind
    public let payload: Data
    public init(kind: LinkFrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

public enum LinkError: Error, Equatable, CustomStringConvertible {
    case invalidFrameLength(Int)
    case unknownFrameKind(UInt8)
    case truncatedAudio
    case invalidAudio
    case invalidPublicKey
    case invalidToken
    case invalidPairingCode
    case decryptionFailed
    case encodingFailed
    case decodingFailed

    public var description: String {
        switch self {
        case .invalidFrameLength: return "链路帧长度无效"
        case .unknownFrameKind: return "链路帧类型未知"
        case .truncatedAudio: return "音频帧不完整"
        case .invalidAudio: return "音频帧格式错误"
        case .invalidPublicKey: return "链路公钥无效"
        case .invalidToken: return "设备令牌无效"
        case .invalidPairingCode: return "配对码无效"
        case .decryptionFailed: return "链路校验失败"
        case .encodingFailed: return "链路编码失败"
        case .decodingFailed: return "链路消息无效"
        }
    }
}

/// 大端 u32 长度 + u8 类型。长度只描述负载，不含 5 字节头。
public enum LinkWire {
    public static func encode(_ frame: LinkFrame) -> Data {
        var data = Data(capacity: frame.payload.count + 5)
        let length = UInt32(frame.payload.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(frame.kind.rawValue)
        data.append(frame.payload)
        return data
    }

    public static func encode(kind: LinkFrameKind, payload: Data) -> Data {
        encode(LinkFrame(kind: kind, payload: payload))
    }
}

public struct LinkFrameDecoder {
    private var buffer: [UInt8] = []
    public init() {}

    /// 增量解析。保留不完整尾帧，下一次 append 继续。
    public mutating func append(_ data: Data) throws -> [LinkFrame] {
        buffer.append(contentsOf: data)
        var frames: [LinkFrame] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let length = Int(buffer[offset]) << 24
                | Int(buffer[offset + 1]) << 16
                | Int(buffer[offset + 2]) << 8
                | Int(buffer[offset + 3])
            guard length > 0, length <= IMicLink.maxPayload else {
                throw LinkError.invalidFrameLength(length)
            }
            guard buffer.count - offset - 5 >= length else { break }
            let rawKind = buffer[offset + 4]
            guard let kind = LinkFrameKind(rawValue: rawKind) else {
                throw LinkError.unknownFrameKind(rawKind)
            }
            let start = offset + 5
            frames.append(LinkFrame(kind: kind, payload: Data(buffer[start..<(start + length)])))
            offset = start + length
        }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if offset >= 4096 {
            buffer.removeFirst(offset)
        }
        return frames
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

public struct AudioPacket: Equatable {
    public let session: UInt16
    public let seq: UInt32
    public let pcm: Data

    public init(session: UInt16, seq: UInt32, pcm: Data) {
        self.session = session
        self.seq = seq
        self.pcm = pcm
    }

    public func encoded() -> Data {
        var data = Data(capacity: pcm.count + 8)
        data.append(UInt8(session & 0xff))
        data.append(UInt8((session >> 8) & 0xff))
        data.append(UInt8((seq >> 24) & 0xff))
        data.append(UInt8((seq >> 16) & 0xff))
        data.append(UInt8((seq >> 8) & 0xff))
        data.append(UInt8(seq & 0xff))
        let samples = UInt16(pcm.count / 2)
        data.append(UInt8(samples & 0xff))
        data.append(UInt8((samples >> 8) & 0xff))
        data.append(pcm)
        return data
    }

    public static func decode(_ data: Data) throws -> AudioPacket {
        guard data.count >= 8 else { throw LinkError.truncatedAudio }
        let bytes = [UInt8](data)
        let session = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let seq = UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5])
        let samples = Int(UInt16(bytes[6]) | UInt16(bytes[7]) << 8)
        let pcm = Data(bytes[8...])
        guard pcm.count == samples * 2, !pcm.isEmpty else { throw LinkError.invalidAudio }
        return AudioPacket(session: session, seq: seq, pcm: pcm)
    }
}

public struct LinkPolishPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var options: PolishOptions

    public init(enabled: Bool, options: PolishOptions) {
        self.enabled = enabled
        self.options = options
    }
}

public struct LinkMessage: Codable, Equatable {
    public var t: String
    public var v: Int?
    public var deviceID: String?
    public var deviceName: String?
    public var publicKey: String?
    public var hasToken: Bool?
    public var macID: String?
    public var name: String?
    public var status: String?
    public var token: String?
    public var session: Int?
    public var seq: Int?
    public var samples: Int?
    public var frames: Int?
    public var text: String?
    public var latency: Double?
    public var pasted: Bool?
    public var target: String?
    public var code: String?
    public var message: String?
    public var phase: String?
    public var action: String?
    public var features: Int?
    public var polish: LinkPolishPreferences?
    public var ts: Double?

    public init(t: String) { self.t = t }

    enum CodingKeys: String, CodingKey {
        case t, v
        case deviceID = "device_id"
        case deviceName = "device_name"
        case publicKey = "public_key"
        case hasToken = "has_token"
        case macID = "mac_id"
        case name, status, token, session, seq, samples, frames, text, latency, pasted, target, code, message, phase, action, features, polish, ts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(String.self, forKey: .t)
        v = try container.decodeIfPresent(Int.self, forKey: .v)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey)
        hasToken = try container.decodeIfPresent(Bool.self, forKey: .hasToken)
        macID = try container.decodeIfPresent(String.self, forKey: .macID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        session = try container.decodeIfPresent(Int.self, forKey: .session)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        samples = try container.decodeIfPresent(Int.self, forKey: .samples)
        frames = try container.decodeIfPresent(Int.self, forKey: .frames)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        latency = try container.decodeIfPresent(Double.self, forKey: .latency)
        pasted = try container.decodeIfPresent(Bool.self, forKey: .pasted)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        features = try container.decodeIfPresent(Int.self, forKey: .features)
        polish = try container.decodeIfPresent(LinkPolishPreferences.self, forKey: .polish)
        ts = try container.decodeIfPresent(Double.self, forKey: .ts)

        if t == "input.state" {
            guard let seq, seq >= 0, status == "ready" || status == "busy" else { throw LinkError.decodingFailed }
        }
        if t == "input", action == "clear" {
            guard let seq, seq >= 0 else { throw LinkError.decodingFailed }
        }
        if t == "input.result" {
            guard action == "clear", let seq, seq >= 0, status == "applied" || status == "rejected" else {
                throw LinkError.decodingFailed
            }
        }

        if t == "polish.settings" || t == "polish.saved"
            || (t == "settings" && (features ?? 0) & IMicLink.polishPreferencesFeature != 0) {
            guard polish != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.polish,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "润色偏好必须完整提供")
                )
            }
        }
        if t == "polish.saved", (features ?? 0) & IMicLink.polishPreferencesFeature == 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .features, in: container, debugDescription: "保存确认必须声明润色偏好能力"
            )
        }
    }

    public static func hello(deviceID: String, deviceName: String, publicKey: String, hasToken: Bool) -> LinkMessage {
        var m = LinkMessage(t: "hello")
        m.v = IMicLink.version
        m.deviceID = deviceID
        m.deviceName = deviceName
        m.publicKey = publicKey
        m.hasToken = hasToken
        return m
    }

    public static func helloReply(macID: String, name: String, publicKey: String, status: String) -> LinkMessage {
        var m = LinkMessage(t: "hello")
        m.v = IMicLink.version
        m.macID = macID
        m.name = name
        m.publicKey = publicKey
        m.status = status
        return m
    }

    public static func pair(deviceID: String, deviceName: String, token: String) -> LinkMessage {
        var m = LinkMessage(t: "pair")
        m.deviceID = deviceID
        m.deviceName = deviceName
        m.token = token
        return m
    }

    public static func paired(macID: String, name: String) -> LinkMessage {
        var m = LinkMessage(t: "paired")
        m.macID = macID
        m.name = name
        return m
    }

    public static func auth() -> LinkMessage { LinkMessage(t: "auth") }
    public static func ready() -> LinkMessage { LinkMessage(t: "ready") }

    public static func error(_ code: String, _ message: String) -> LinkMessage {
        var m = LinkMessage(t: "error")
        m.code = code
        m.message = message
        return m
    }

    public static func audioStart(session: Int) -> LinkMessage {
        var m = LinkMessage(t: "audio.start")
        m.session = session
        return m
    }

    public static func audioEnd(session: Int, samples: Int, frames: Int) -> LinkMessage {
        var m = LinkMessage(t: "audio.end")
        m.session = session
        m.samples = samples
        m.frames = frames
        return m
    }

    public static func audioCancel(session: Int) -> LinkMessage {
        var m = LinkMessage(t: "audio.cancel")
        m.session = session
        return m
    }

    /// Mac → iPhone：当前会话从 from 开始缺失，请用本地音频日志补发。
    public static func audioNeed(session: Int, from: Int) -> LinkMessage {
        var m = LinkMessage(t: "audio.need")
        m.session = session
        m.seq = from
        return m
    }

    /// iPhone → Mac：中心弦的手势输入。action 为 return / delete / left / right。
    public static func input(_ action: String, revision: Int? = nil) -> LinkMessage {
        var m = LinkMessage(t: "input")
        m.action = action
        m.seq = revision
        return m
    }

    public static func inputState(revision: Int, ready: Bool) -> LinkMessage {
        var m = LinkMessage(t: "input.state")
        m.seq = revision
        m.status = ready ? "ready" : "busy"
        return m
    }

    public static func inputResult(revision: Int, applied: Bool, message: String? = nil) -> LinkMessage {
        var m = LinkMessage(t: "input.result")
        m.action = "clear"
        m.seq = revision
        m.status = applied ? "applied" : "rejected"
        m.message = message
        return m
    }

    /// iPhone → Mac：Apple Speech 的临时转写，用于实时输入预览。
    public static func preview(_ text: String) -> LinkMessage {
        var m = LinkMessage(t: "preview")
        m.text = text
        return m
    }

    /// Mac → iPhone：功能位与当前 Mac 保存的完整润色偏好。
    public static func settings(features: Int, polish: LinkPolishPreferences) -> LinkMessage {
        var m = LinkMessage(t: "settings")
        m.features = features
        m.polish = polish
        return m
    }

    /// iPhone → Mac：请求保存完整润色偏好，仅用于认证后的加密链路。
    public static func polishSettings(_ preferences: LinkPolishPreferences) -> LinkMessage {
        var m = LinkMessage(t: "polish.settings")
        m.polish = preferences
        return m
    }

    /// Mac → iPhone：本次保存请求的明确确认，不与普通状态广播混淆。
    public static func polishSaved(features: Int, polish: LinkPolishPreferences) -> LinkMessage {
        var m = settings(features: features, polish: polish)
        m.t = "polish.saved"
        return m
    }

    public static func state(session: Int, phase: String) -> LinkMessage {
        var m = LinkMessage(t: "state")
        m.session = session
        m.phase = phase
        return m
    }

    public static func result(session: Int, text: String, latency: Double, pasted: Bool, target: String?) -> LinkMessage {
        var m = LinkMessage(t: "result")
        m.session = session
        m.text = text
        m.latency = latency
        m.pasted = pasted
        m.target = target
        return m
    }

    public static func failure(session: Int, code: String, message: String) -> LinkMessage {
        var m = LinkMessage(t: "failure")
        m.session = session
        m.code = code
        m.message = message
        return m
    }

    public static func ping(_ ts: Double) -> LinkMessage {
        var m = LinkMessage(t: "ping")
        m.ts = ts
        return m
    }

    public static func pong(_ ts: Double) -> LinkMessage {
        var m = LinkMessage(t: "pong")
        m.ts = ts
        return m
    }

    public func encoded() throws -> Data {
        do { return try JSONEncoder().encode(self) }
        catch { throw LinkError.encodingFailed }
    }

    public static func decode(_ data: Data) throws -> LinkMessage {
        do { return try JSONDecoder().decode(LinkMessage.self, from: data) }
        catch { throw LinkError.decodingFailed }
    }
}

public enum LinkCrypto {
    public static let info = Data("iMic-link-v1".utf8)

    public static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public static func publicKeyBase64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    public static func parsePublicKey(_ base64: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw LinkError.invalidPublicKey
        }
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) }
        catch { throw LinkError.invalidPublicKey }
    }

    public static func pairingCipher(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: String,
        code: String
    ) throws -> LinkCipher {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw LinkError.invalidPairingCode }
        let salt = Data(SHA256.hash(data: Data(("iMic-pair-v1:" + code).utf8)))
        return try cipher(privateKey: privateKey, peerPublicKey: peerPublicKey, salt: salt, info: "iMic-pair-v1")
    }

    public static func sessionCipher(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: String,
        token: Data
    ) throws -> LinkCipher {
        guard token.count == 32 else { throw LinkError.invalidToken }
        return try cipher(privateKey: privateKey, peerPublicKey: peerPublicKey, salt: token, info: "iMic-session-v1")
    }

    private static func cipher(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: String,
        salt: Data,
        info: String
    ) throws -> LinkCipher {
        let peer = try parsePublicKey(peerPublicKey)
        let shared: SharedSecret
        do { shared = try privateKey.sharedSecretFromKeyAgreement(with: peer) }
        catch { throw LinkError.invalidPublicKey }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
        return LinkCipher(key: key)
    }
}

public struct LinkCipher {
    public let key: SymmetricKey

    public func seal(_ plaintext: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else { throw LinkError.encodingFailed }
            return combined
        } catch let error as LinkError {
            throw error
        } catch {
            throw LinkError.encodingFailed
        }
    }

    public func open(_ sealed: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw LinkError.decryptionFailed
        }
    }
}

public enum PairingCode {
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    public static func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
    }

    public static func normalize(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(6))
    }
}
