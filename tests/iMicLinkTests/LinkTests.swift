import XCTest
import CryptoKit
@testable import iMicLink

final class GestureControlTests: XCTestCase {
    func testPipelineCompletionAndStaleLease() {
        var gate = LinkGestureLease()
        XCTAssertFalse(gate.permits(0))
        gate.update(ready: true)
        let idle = gate.revision
        XCTAssertTrue(gate.permits(idle))
        for _ in ["recording", "ASR", "polish", "sweep", "final input"] {
            gate.update(ready: false)
            XCTAssertFalse(gate.permits(idle))
            XCTAssertFalse(gate.permits(gate.revision))
        }
        gate.update(ready: true)
        XCTAssertFalse(gate.permits(idle))
        XCTAssertTrue(gate.permits(gate.revision))
        let clear = gate.revision
        gate.update(ready: false)
        XCTAssertFalse(gate.permits(clear), "A held or replayed clear cannot execute twice")
    }

    func testGestureMessagesRoundTripAndRejectMalformedState() throws {
        for message in [LinkMessage.inputState(revision: 12, ready: true),
                        .inputState(revision: 13, ready: false), .input("clear", revision: 12),
                        .inputResult(revision: 12, applied: true),
                        .inputResult(revision: 12, applied: false, message: "不可清空")] {
            XCTAssertEqual(try LinkMessage.decode(message.encoded()), message)
        }
        for invalid in [#"{"t":"input.state","status":"ready"}"#,
                        #"{"t":"input.state","seq":1,"status":"unknown"}"#,
                        #"{"t":"input.state","seq":-1,"status":"ready"}"#,
                        #"{"t":"input","action":"clear"}"#,
                        #"{"t":"input.result","seq":1,"action":"clear","status":"sent"}"#] {
            XCTAssertThrowsError(try LinkMessage.decode(Data(invalid.utf8)))
        }
        XCTAssertEqual(try LinkMessage.decode(LinkMessage.input("delete").encoded()).action, "delete")
    }

    func testFullScreenStretchKeepsInitialDeleteFeelAndReachesZone() {
        let stretch = StringClearStretch(distance: 350, depth: 330)
        var previous: CGFloat = 0
        for distance in stride(from: CGFloat(0), through: 350, by: 1) {
            let normal: CGFloat = -60 * tanh(distance * 0.72 / 60)
            let pull = stretch.pull(normal: normal, translation: -distance, limit: 60)
            XCTAssertLessThanOrEqual(pull, previous + 0.001)
            if distance < 80 { XCTAssertEqual(pull, normal, accuracy: 0.001) }
            previous = pull
        }
        XCTAssertEqual(previous, -330, accuracy: 0.001)
        XCTAssertEqual(-40 + stretch.pull(normal: -60, translation: -350, limit: 60, origin: -40), -330, accuracy: 0.001)
        XCTAssertEqual(stretch.pull(normal: 30, translation: 50, limit: 60), 30)
    }

    func testClearContactDissolvesBeforeContinuousSpringReturn() {
        let feedback = StringClearFeedback(initialPull: -325, depth: 330)
        XCTAssertEqual(feedback.frame(at: 0, reducedMotion: false).pull, -325)
        XCTAssertLessThan(feedback.frame(at: 0.06, reducedMotion: false).pull, -325)
        XCTAssertEqual(feedback.frame(at: 0.06, reducedMotion: false).opacity, 1)
        XCTAssertEqual(feedback.frame(at: 0.22, reducedMotion: false).opacity, 0)
        XCTAssertEqual(feedback.frame(at: 0.22, reducedMotion: false).pull, -330)
        XCTAssertGreaterThan(feedback.frame(at: 0.26, reducedMotion: false).pull, -190)
        XCTAssertGreaterThan(feedback.frame(at: 0.30, reducedMotion: false).pull, 0,
                             "A fully drawn string must cross neutral within 80ms of release")
        for reduced in [false, true] {
            var previous = feedback.frame(at: 0, reducedMotion: reduced)
            for index in 1...126 {
                let frame = feedback.frame(at: Double(index) / 120, reducedMotion: reduced)
                XCTAssertLessThan(abs(frame.pull - previous.pull), 55, "No contact/return teleport at 120 Hz")
                XCTAssertTrue((0...1).contains(frame.opacity))
                if reduced { XCTAssertLessThanOrEqual(frame.pull, 0) }
                previous = frame
            }
            XCTAssertTrue(previous.finished)
            XCTAssertEqual(previous.pull, 0)
            XCTAssertEqual(previous.opacity, 1)
        }
    }

    func testPullRatchetConsumesNewTeethWithoutJitterOrCatchUpBursts() {
        var ratchet = StringPullRatchet()
        XCTAssertFalse(ratchet.advance(distance: 20, now: 0))
        XCTAssertTrue(ratchet.advance(distance: 50, now: 0.1))
        XCTAssertFalse(ratchet.advance(distance: 49, now: 0.2))
        XCTAssertFalse(ratchet.advance(distance: 51, now: 0.3))
        XCTAssertTrue(ratchet.advance(distance: 300, now: 0.4))
        XCTAssertFalse(ratchet.advance(distance: 320, now: 0.41))
        XCTAssertFalse(ratchet.advance(distance: 300, now: 0.5))
        XCTAssertTrue(ratchet.advance(distance: 350, now: 0.6))
    }
}

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


    func testAudioPacketRejectsShortPayload() {
        var data = AudioPacket(session: 1, seq: 1, pcm: Data(repeating: 1, count: 640)).encoded()
        data.removeLast()
        XCTAssertThrowsError(try AudioPacket.decode(data)) { error in
            XCTAssertEqual(error as? LinkError, .invalidAudio)
        }
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
    }
}

final class LinkPolishPreferencesTests: XCTestCase {
    func testLegacySettingsRemainUnsupportedWithoutPolishState() throws {
        let message = try LinkMessage.decode(Data(#"{"t":"settings","features":15}"#.utf8))
        XCTAssertEqual((message.features ?? 0) & IMicLink.polishPreferencesFeature, 0)
        XCTAssertNil(message.polish)
    }

    func testAdvertisedCapabilityRequiresCompletePolishState() throws {
        for payload in [
            #"{"t":"settings","features":16}"#,
            #"{"t":"settings","features":31,"polish":null}"#
        ] {
            assertRejected(payload)
        }

        let message = try LinkMessage.decode(Data(
            #"{"t":"settings","features":31,"polish":{"enabled":false,"options":{"strength":"light","scenario":"chat"}}}"#.utf8
        ))
        XCTAssertNotEqual((message.features ?? 0) & IMicLink.polishPreferencesFeature, 0)
        let preferences = try XCTUnwrap(message.polish)
        XCTAssertFalse(preferences.enabled)
        XCTAssertEqual(preferences.options.strength, .light)
        XCTAssertEqual(preferences.options.scenario, .chat)
    }

    func testPolishCommandRequiresEveryPreferenceField() {
        for payload in [
            #"{"t":"polish.settings"}"#,
            #"{"t":"polish.settings","polish":null}"#,
            #"{"t":"polish.settings","polish":{}}"#,
            #"{"t":"polish.settings","polish":{"options":{"strength":"medium","scenario":"agent"}}}"#,
            #"{"t":"polish.settings","polish":{"enabled":true}}"#,
            #"{"t":"polish.settings","polish":{"enabled":true,"options":{}}}"#,
            #"{"t":"polish.settings","polish":{"enabled":true,"options":{"scenario":"agent"}}}"#,
            #"{"t":"polish.settings","polish":{"enabled":true,"options":{"strength":"medium"}}}"#
        ] {
            assertRejected(payload)
        }
    }

    func testInvalidPreferencesAreRejectedInCommandsAndState() {
        let invalidPreferences = [
            #"{"enabled":true,"options":{"strength":"extreme","scenario":"agent"}}"#,
            #"{"enabled":true,"options":{"strength":"Medium","scenario":"agent"}}"#,
            #"{"enabled":true,"options":{"strength":"medium","scenario":"unknown"}}"#,
            #"{"enabled":true,"options":{"strength":"medium","scenario":"Agent"}}"#,
            #"{"enabled":"true","options":{"strength":"medium","scenario":"agent"}}"#,
            #"{"enabled":null,"options":{"strength":"medium","scenario":"agent"}}"#,
            #"{"enabled":false,"options":{"strength":null,"scenario":"agent"}}"#,
            #"{"enabled":false,"options":{"strength":"medium","scenario":null}}"#,
            #"{"enabled":false,"options":null}"#,
            #"{"enabled":false,"options":{"strength":"medium"}}"#
        ]
        for preferences in invalidPreferences {
            assertRejected(#"{"t":"polish.settings","polish":\#(preferences)}"#)
            assertRejected(#"{"t":"settings","features":31,"polish":\#(preferences)}"#)
        }
    }

    func testSaveConfirmationRequiresCapabilityAndCompleteState() {
        for payload in [
            #"{"t":"polish.saved","features":16}"#,
            #"{"t":"polish.saved","features":16,"polish":null}"#,
            #"{"t":"polish.saved","polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent"}}}"#,
            #"{"t":"polish.saved","features":15,"polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent"}}}"#
        ] {
            assertRejected(payload)
        }
    }

    private func assertRejected(_ payload: String, file: StaticString = #filePath, line: UInt = #line) {
        let data = Data(payload.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LinkMessage.self, from: data), file: file, line: line)
        XCTAssertThrowsError(try LinkMessage.decode(data), file: file, line: line) { error in
            XCTAssertEqual(error as? LinkError, .decodingFailed, file: file, line: line)
        }
    }
}

final class AudioSessionBoundsTests: XCTestCase {
    func testLongSessionAndPartialFinalFrameAreAccepted() {
        let longSamples = IMicLink.sampleRate * 120
        XCTAssertTrue(IMicLink.isValidAudioEnd(
            samples: longSamples, frames: longSamples / IMicLink.frameSamples))
        XCTAssertTrue(IMicLink.isValidAudioEnd(
            samples: longSamples + 1, frames: longSamples / IMicLink.frameSamples + 1))
    }

    func testMismatchedAndOverflowingEndCountsAreRejected() {
        XCTAssertFalse(IMicLink.isValidAudioEnd(samples: 0, frames: 0))
        XCTAssertFalse(IMicLink.isValidAudioEnd(samples: -1, frames: 1))
        XCTAssertFalse(IMicLink.isValidAudioEnd(samples: 321, frames: 1))
        XCTAssertFalse(IMicLink.isValidAudioEnd(samples: 320, frames: 2))
        XCTAssertFalse(IMicLink.isValidAudioEnd(samples: Int.max, frames: Int.max))
        let maximum = IMicLink.sampleRate * IMicLink.maxSessionSeconds
        XCTAssertTrue(IMicLink.isValidAudioEnd(
            samples: maximum, frames: maximum / IMicLink.frameSamples))
        XCTAssertFalse(IMicLink.isValidAudioEnd(
            samples: maximum + 1, frames: maximum / IMicLink.frameSamples + 1))
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
