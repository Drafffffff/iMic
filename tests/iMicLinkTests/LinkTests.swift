import XCTest
import CryptoKit
@testable import iMicLink

final class LinkWireTests: XCTestCase {
    func testFramesSurviveArbitrarySplits() throws {
        let payload = Data((0..<3000).map { UInt8($0 & 0xff) })
        let encoded = LinkWire.encode(kind: .sealedAudio, payload: payload)
        var decoder = LinkFrameDecoder()
        var frames: [LinkFrame] = []
        for byte in encoded {
            frames += try decoder.append(Data([byte]))
        }
        XCTAssertEqual(frames, [LinkFrame(kind: .sealedAudio, payload: payload)])
    }

    func testMultipleFramesInOneRead() throws {
        let first = LinkWire.encode(kind: .json, payload: Data("one".utf8))
        let second = LinkWire.encode(kind: .json, payload: Data("two".utf8))
        var decoder = LinkFrameDecoder()
        let frames = try decoder.append(first + second)
        XCTAssertEqual(frames.map { String(decoding: $0.payload, as: UTF8.self) }, ["one", "two"])
    }

    func testRejectsOversizedFrame() {
        var decoder = LinkFrameDecoder()
        let header = Data([0xff, 0xff, 0xff, 0xff, 1])
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? LinkError, .invalidFrameLength(Int(UInt32.max)))
        }
    }

    func testRejectsUnknownKind() {
        var decoder = LinkFrameDecoder()
        let header = Data([0, 0, 0, 1, 9, 0])
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? LinkError, .unknownFrameKind(9))
        }
    }

    func testAudioPacketRoundTrip() throws {
        let pcm = Data((0..<640).map { UInt8($0 & 0xff) })
        let packet = AudioPacket(session: 7, seq: 42, pcm: pcm)
        let decoded = try AudioPacket.decode(packet.encoded())
        XCTAssertEqual(decoded, packet)
    }

    func testAudioPacketRejectsShortPayload() {
        var data = AudioPacket(session: 1, seq: 1, pcm: Data(repeating: 1, count: 640)).encoded()
        data.removeLast()
        XCTAssertThrowsError(try AudioPacket.decode(data)) { error in
            XCTAssertEqual(error as? LinkError, .invalidAudio)
        }
    }

    func testAudioNeedRoundTrip() throws {
        let message = LinkMessage.audioNeed(session: 7, from: 42)
        XCTAssertEqual(message.t, "audio.need")
        XCTAssertEqual(try LinkMessage.decode(message.encoded()), message)
        let object = try JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any]
        XCTAssertEqual(object?["session"] as? Int, 7)
        XCTAssertEqual(object?["seq"] as? Int, 42)
    }

    func testInputRoundTrip() throws {
        let message = LinkMessage.input("return")
        XCTAssertEqual(message.t, "input")
        XCTAssertEqual(message.action, "return")
        XCTAssertEqual(try LinkMessage.decode(message.encoded()), message)
    }

    func testPreviewAndSettingsRoundTrip() throws {
        let preview = LinkMessage.preview("临时文本")
        XCTAssertEqual(try LinkMessage.decode(preview.encoded()), preview)
        let settings = LinkMessage.settings(features: 0b1111)
        XCTAssertEqual(try LinkMessage.decode(settings.encoded()), settings)
        XCTAssertEqual(settings.features, 0b1111)
    }

    func testMessageUsesSnakeCase() throws {
        let message = LinkMessage.hello(
            deviceID: "phone-id",
            deviceName: "iPhone",
            publicKey: "abc",
            hasToken: true
        )
        let object = try JSONSerialization.jsonObject(with: message.encoded()) as? [String: Any]
        XCTAssertEqual(object?["device_id"] as? String, "phone-id")
        XCTAssertEqual(object?["public_key"] as? String, "abc")
        XCTAssertEqual(try LinkMessage.decode(message.encoded()), message)
    }
}

final class LinkCryptoTests: XCTestCase {
    func testPairingDerivesTheSameKeyOnBothSides() throws {
        let phone = LinkCrypto.makePrivateKey()
        let mac = LinkCrypto.makePrivateKey()
        let phoneCipher = try LinkCrypto.pairingCipher(
            privateKey: phone,
            peerPublicKey: LinkCrypto.publicKeyBase64(mac),
            code: "123456"
        )
        let macCipher = try LinkCrypto.pairingCipher(
            privateKey: mac,
            peerPublicKey: LinkCrypto.publicKeyBase64(phone),
            code: "123456"
        )
        let sealed = try phoneCipher.seal(Data("hello".utf8))
        XCTAssertEqual(try macCipher.open(sealed), Data("hello".utf8))
    }

    func testDifferentCodesCannotOpen() throws {
        let phone = LinkCrypto.makePrivateKey()
        let mac = LinkCrypto.makePrivateKey()
        let phoneCipher = try LinkCrypto.pairingCipher(
            privateKey: phone,
            peerPublicKey: LinkCrypto.publicKeyBase64(mac),
            code: "123456"
        )
        let macCipher = try LinkCrypto.pairingCipher(
            privateKey: mac,
            peerPublicKey: LinkCrypto.publicKeyBase64(phone),
            code: "654321"
        )
        let sealed = try phoneCipher.seal(Data("hello".utf8))
        XCTAssertThrowsError(try macCipher.open(sealed)) { error in
            XCTAssertEqual(error as? LinkError, .decryptionFailed)
        }
    }

    func testSessionUsesStoredToken() throws {
        let phone = LinkCrypto.makePrivateKey()
        let mac = LinkCrypto.makePrivateKey()
        let token = Data((0..<32).map { UInt8($0) })
        let phoneCipher = try LinkCrypto.sessionCipher(
            privateKey: phone,
            peerPublicKey: LinkCrypto.publicKeyBase64(mac),
            token: token
        )
        let macCipher = try LinkCrypto.sessionCipher(
            privateKey: mac,
            peerPublicKey: LinkCrypto.publicKeyBase64(phone),
            token: token
        )
        let sealed = try phoneCipher.seal(Data("audio".utf8))
        XCTAssertEqual(try macCipher.open(sealed), Data("audio".utf8))
    }

    func testTamperingIsRejected() throws {
        let phone = LinkCrypto.makePrivateKey()
        let mac = LinkCrypto.makePrivateKey()
        let token = Data(repeating: 7, count: 32)
        let phoneCipher = try LinkCrypto.sessionCipher(
            privateKey: phone,
            peerPublicKey: LinkCrypto.publicKeyBase64(mac),
            token: token
        )
        var sealed = try phoneCipher.seal(Data("audio".utf8))
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try phoneCipher.open(sealed))
    }

    func testPairingCodeIsAlwaysSixDigits() {
        for _ in 0..<200 {
            let code = PairingCode.make()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
            XCTAssertEqual(PairingCode.formatted(code).count, 7)
        }
    }
}

final class DeepSeekPolicyTests: XCTestCase {
    func testRejectsAnswerToQuestion() {
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(
            raw: "这样表达清楚，我按这个方式整理就行，可以吗？",
            polished: "可以，这样表达清楚，我按这个方式整理就行。"
        ))
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(
            raw: "这样可以吗",
            polished: "可以。"
        ))
    }

    func testKeepsQuestionAndRequest() {
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: "嗯，这样表达清楚，我按这个方式整理就行，可以吗？",
            polished: "这样表达清楚，我按这个方式整理就行，可以吗？"
        ))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: "那个，帮我整理一下这段，可以吗？",
            polished: "帮我整理一下这段，可以吗？"
        ))
    }

    func testRejectsOverCompression() {
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(
            raw: "我想让你把今天讨论的交互细节整理成一页说明，重点保留按住说话和松开即输入的节奏。",
            polished: "整理一页说明。"
        ))
    }
}
