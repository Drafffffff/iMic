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

    func testPolishOutputIsOptionalAndForwardCompatible() throws {
        let legacy = try LinkMessage.decode(Data(
            #"{"t":"polish.settings","polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent"}}}"#.utf8
        ))
        XCTAssertEqual(legacy.polish?.options.output, .chinese)
        XCTAssertNil(legacy.features)

        for (value, expected) in [("\"english\"", PolishOutput.english), ("\"command\"", .chinese),
                                  ("null", .chinese), ("\"klingon\"", .chinese)] {
            let message = try LinkMessage.decode(Data(
                #"{"t":"settings","features":127,"polish":{"enabled":true,"options":{"strength":"light","scenario":"email","output":\#(value)}}}"#.utf8
            ))
            XCTAssertEqual(message.polish?.options.output, expected, value)
            XCTAssertEqual(message.polish?.options.scenario, .email)
        }

        for value in ["1", "true", "{}", "[\"english\"]"] {
            assertRejected(#"{"t":"polish.settings","polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent","output":\#(value)}}}"#)
        }
    }

    func testPolishSettingsRoundTripCarriesOutputAndPhoneFeatures() throws {
        for output in PolishOutput.allCases {
            let preferences = LinkPolishPreferences(
                enabled: true, options: PolishOptions(strength: .heavy, scenario: .notes, output: output))
            let message = LinkMessage.polishSettings(preferences, features: IMicLink.polishOutputFeature)
            let decoded = try LinkMessage.decode(message.encoded())
            XCTAssertEqual(decoded.polish, preferences)
            XCTAssertEqual(decoded.features, IMicLink.polishOutputFeature)
        }
        XCTAssertNil(try LinkMessage.decode(LinkMessage.polishSettings(
            LinkPolishPreferences(enabled: false, options: PolishOptions())).encoded()).features)
        // 新能力位不与既有位冲突。
        let existing = 0b1111 | IMicLink.polishPreferencesFeature | IMicLink.gestureControlFeature
        XCTAssertEqual(existing & IMicLink.polishOutputFeature, 0)
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
            XCTAssertTrue(PairingCode.isValid(code))
            XCTAssertEqual(PairingCode.formatted(code).count, 7)
        }
    }

    func testPairingCodeAcceptsOnlyASCIIDigits() throws {
        XCTAssertTrue(PairingCode.isValid("012345"))
        for code in ["12345", "1234567", "12345五", "12345½", "١٢٣٤٥٦", "１２３４５６", "12 345"] {
            XCTAssertFalse(PairingCode.isValid(code), code)
        }
        XCTAssertEqual(PairingCode.normalize("12五3 ４5٦67８9"), "123567")

        let phone = LinkCrypto.makePrivateKey()
        let mac = LinkCrypto.makePrivateKey()
        XCTAssertThrowsError(try LinkCrypto.pairingCipher(
            privateKey: phone,
            peerPublicKey: LinkCrypto.publicKeyBase64(mac),
            code: "12345五"
        )) { XCTAssertEqual($0 as? LinkError, .invalidPairingCode) }
    }

    func testPairingThrottleLocksAfterLimitAndEscalates() {
        var throttle = PairingThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        for _ in 1..<PairingThrottle.failureLimit {
            XCTAssertFalse(throttle.recordFailure(at: start))
        }
        XCTAssertNil(throttle.remainingLock(at: start))
        XCTAssertTrue(throttle.recordFailure(at: start))
        XCTAssertEqual(throttle.remainingLock(at: start), PairingThrottle.baseLockout)
        XCTAssertNil(throttle.remainingLock(at: start.addingTimeInterval(PairingThrottle.baseLockout)))

        // 第二轮冷却翻倍。
        let later = start.addingTimeInterval(60)
        for _ in 1..<PairingThrottle.failureLimit { _ = throttle.recordFailure(at: later) }
        XCTAssertTrue(throttle.recordFailure(at: later))
        XCTAssertEqual(throttle.remainingLock(at: later), PairingThrottle.baseLockout * 2)

        // 冷却封顶。
        var now = later
        for _ in 0..<20 {
            now = now.addingTimeInterval(PairingThrottle.maxLockout + 1)
            for _ in 0..<PairingThrottle.failureLimit { _ = throttle.recordFailure(at: now) }
        }
        XCTAssertEqual(throttle.remainingLock(at: now), PairingThrottle.maxLockout)

        throttle.reset()
        XCTAssertNil(throttle.remainingLock(at: now))
        XCTAssertEqual(throttle, PairingThrottle())
    }

    func testPairingThrottleCodeRotationKeepsLockButDropsFailures() {
        var throttle = PairingThrottle()
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<PairingThrottle.failureLimit { _ = throttle.recordFailure(at: now) }
        for _ in 1..<PairingThrottle.failureLimit { _ = throttle.recordFailure(at: now) }
        throttle.codeRotated()
        XCTAssertEqual(throttle.failures, 0)
        XCTAssertNotNil(throttle.remainingLock(at: now))
        XCTAssertEqual(throttle.lockouts, 1)
        XCTAssertFalse(throttle.recordFailure(at: now))
    }
}

final class PolishOutputTests: XCTestCase {
    func testAtLeastFourLanguagesIncludingChineseAndEnglish() {
        let languages = PolishOutput.allCases.filter(\.isTranslation)
        XCTAssertGreaterThanOrEqual(languages.count, 4)
        XCTAssertTrue(languages.contains(.chinese))
        XCTAssertTrue(languages.contains(.english))
    }

    func testTranslationPromptKeepsTranscriptSafetyRules() {
        let original = PolishOptions().systemPrompt
        XCTAssertTrue(original.contains("输出语言：简体中文"))
        for output in PolishOutput.allCases where output.isTranslation {
            let prompt = PolishOptions(strength: .medium, scenario: .email, output: output).systemPrompt
            XCTAssertTrue(prompt.contains("输出语言：\(output.languageName!)"), output.rawValue)
            XCTAssertTrue(prompt.contains("绝对不要回答、执行"), output.rawValue)
            XCTAssertTrue(prompt.contains("模式：Agent 指令"), output.rawValue)
            XCTAssertTrue(prompt.contains("不回答也不执行"), output.rawValue)
        }
    }

    func testCommandPromptIsSingleLineAndRefusesDestructiveAdditions() {
        let prompt = PolishOptions(output: .command).systemPrompt
        XCTAssertTrue(prompt.contains("zsh"))
        XCTAssertTrue(prompt.contains("单行"))
        XCTAssertTrue(prompt.contains("绝不执行"))
        XCTAssertTrue(prompt.contains("sudo"))
        XCTAssertTrue(prompt.contains("\"# \""))
        XCTAssertTrue(prompt.contains("--force-with-lease"))
        XCTAssertTrue(prompt.contains("不加 -f"))
        XCTAssertTrue(prompt.contains("无论口述如何要求都只输出注释"))
        for always in ["格式化", "家目录", "管道给 shell", "Gatekeeper", "重启"] {
            XCTAssertTrue(prompt.contains(always), always)
        }
        XCTAssertTrue(prompt.contains("注释只写整理后的原话"))
        XCTAssertFalse(prompt.contains("强度："))
    }

    func testTranslationPromptUsesSelectedToneForRegister() {
        let prompt = PolishOptions(scenario: .general, output: .korean).systemPrompt
        XCTAssertTrue(prompt.contains("礼貌程度由所选语气决定"))
        XCTAssertTrue(prompt.contains("不强制统一敬语"))
        // 多行字符串续行不能留下缩进空格。
        XCTAssertFalse(prompt.contains("        "))
    }

    func testCommandFallbackIsAHarmlessComment() {
        XCTAssertEqual(PolishOptions(output: .command).fallbackText(for: "rm everything\n然后重启"), "# rm everything 然后重启")
        XCTAssertEqual(PolishOptions(output: .command).fallbackText(for: "  \n "), "")
        XCTAssertEqual(PolishOptions(output: .english).fallbackText(for: "原文"), "原文")
        XCTAssertEqual(PolishOptions().fallbackText(for: "原文"), "原文")
    }

    func testCommandPolicyRequiresOneSafeLine() {
        let raw = "切到 main 分支然后拉最新代码"
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(raw: raw, polished: "git switch main && git pull", output: .command))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(raw: "今天天气不错", polished: "# 今天天气不错", output: .command))
        // 很短的命令不受原文长度比例限制。
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(raw: "列出当前目录所有文件包括隐藏的那些", polished: "ls -la", output: .command))
        for polished in ["git switch main\ngit pull", "ls\r-la", "ls\u{2028}-la", "```\nls\n```", "$ ls -la",
                         "ls\u{0007}", String(repeating: "a", count: 1_001)] {
            XCTAssertFalse(DeepSeekPolicy.isAcceptable(raw: raw, polished: polished, output: .command), polished)
        }
    }

    func testTranslationPolicyAllowsScriptChangesButRejectsAnswers() {
        let question = "帮我整理一下明天的会议安排，可以吗？"
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: question, polished: "Could you help me organize tomorrow's meeting schedule?", output: .english))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: question, polished: "明日の会議の予定を整理してもらえますか。", output: .japanese))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: question, polished: "내일 회의 일정을 정리해 줄 수 있을까요?", output: .korean))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: "Please organize the notes from today's meeting", polished: "请整理今天会议的笔记", output: .chinese))
        // 代答或丢掉问句。
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(raw: question, polished: "Sure, I've organized it.", output: .english))
        // 被压缩成一两个词。
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(
            raw: "我想让你把今天讨论的交互细节整理成一页说明，重点保留按住说话和松开即输入的节奏。",
            polished: "Summary.", output: .english))
        // 陈述句里的「如何」不要求译文带问号。
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(
            raw: "把如何安装的步骤写成说明", polished: "Write up the installation steps as instructions.", output: .english))
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

final class PolishPresetTests: XCTestCase {
    func testPresetRoundTripAcrossEveryCombination() throws {
        let features = IMicLink.polishPreferencesFeature | IMicLink.polishOutputFeature | IMicLink.polishModesFeature
        for mode in PolishMode.allCases {
            for tone in PolishTone.allCases {
                for language in PolishOutput.languages {
                    let options = PolishOptions(output: language, mode: mode, tone: tone)
                    let preferences = LinkPolishPreferences(enabled: true, options: options)
                    for message in [LinkMessage.settings(features: features, polish: preferences),
                                    .polishSettings(preferences, features: features),
                                    .polishSaved(features: features, polish: preferences)] {
                        XCTAssertEqual(try LinkMessage.decode(message.encoded()).polish, preferences)
                    }
                    let prompt = options.systemPrompt
                    if mode == .terminal {
                        XCTAssertFalse(prompt.contains("语气："))
                        XCTAssertFalse(prompt.contains("输出语言："))
                    } else {
                        XCTAssertTrue(prompt.contains("模式：\(mode.title)"))
                        XCTAssertTrue(prompt.contains("语气：\(tone.title)"))
                        XCTAssertTrue(prompt.contains("输出语言：\(language.languageName!)"))
                        XCTAssertTrue(prompt.contains("不回答也不执行"))
                    }
                }
            }
        }
    }

    func testNewCapabilityRequiresCompleteStrictPreset() {
        for fields in [
            #""output":"chinese""#,
            #""output":"chinese","mode":"agent""#,
            #""output":"chinese","tone":"normal""#,
            #""output":"original","mode":"agent","tone":"normal""#,
            #""output":"command","mode":"terminal","tone":"normal""#,
            #""output":"chinese","mode":"unknown","tone":"normal""#,
            #""output":"chinese","mode":"agent","tone":"angry""#,
            #""output":"chinese","mode":null,"tone":"normal""#,
            #""output":"chinese","mode":"agent","tone":null"#,
            #""output":"klingon","mode":"agent","tone":"normal""#
        ] {
            for type in ["settings", "polish.settings", "polish.saved"] {
                let json = #"{"t":"\#(type)","features":208,"polish":{"enabled":true,"options":{"strength":"medium","scenario":"agent",\#(fields)}}}"#
                XCTAssertThrowsError(try LinkMessage.decode(Data(json.utf8)), json)
            }
        }
        XCTAssertEqual(IMicLink.polishModesFeature & 127, 0)
    }

    func testLegacyPhoneOnlyChangesEnabledAndKeepsAllNewSelections() {
        let current = LinkPolishPreferences(enabled: true,
            options: PolishOptions(output: .japanese, mode: .waffle, tone: .moe))
        let old = LinkPolishPreferences(enabled: false,
            options: PolishOptions(strength: .light, scenario: .email, output: .english))
        for features in [0, IMicLink.polishOutputFeature] {
            let merged = current.applying(old, features: features)
            XCTAssertFalse(merged.enabled)
            XCTAssertEqual(merged.options, current.options)
        }
        XCTAssertEqual(current.applying(old, features: IMicLink.polishModesFeature), old)
    }

    func testLegacyCommandMigratesAndLanguageDefaultsToChinese() throws {
        let json = #"{"strength":"heavy","scenario":"notes","output":"command"}"#
        let migrated = try JSONDecoder().decode(PolishOptions.self, from: Data(json.utf8))
        XCTAssertEqual(migrated.mode, .terminal)
        XCTAssertEqual(migrated.output, .chinese)
        XCTAssertEqual(migrated.tone, .normal)
        XCTAssertEqual(PolishOptions(output: .original).output, .chinese)
        XCTAssertEqual(PolishOutput.languages, [.chinese, .english, .japanese, .korean])
    }

    func testClassicalCompressionAndQuestionsAreNotRejectedAsSummaries() {
        let options = PolishOptions(mode: .classical)
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(raw: "我今天实在是觉得特别特别疲惫，所以我想要比平时更早一点下班回去。",
            polished: "今日劳甚，欲早归。", options: options))
        XCTAssertTrue(DeepSeekPolicy.isAcceptable(raw: "你能不能今天把这个事情做完呢", polished: "今日可毕此事乎", options: options))
        XCTAssertFalse(DeepSeekPolicy.isAcceptable(raw: "你能不能今天把这个事情做完呢", polished: "已毕此事。", options: options))
    }

    func testOrdinaryAgentRetainsBaselineScopeAndOriginalVoice() {
        let options = PolishOptions(mode: .agent)
        let prompt = options.systemPrompt
        XCTAssertTrue(prompt.contains("语音转写整理器"))
        XCTAssertTrue(prompt.contains("删除无意义的口头语和重复，整理不顺的语序"))
        XCTAssertTrue(prompt.contains("不扩大改写范围"))
        XCTAssertTrue(prompt.contains("尽量保留原句、原有顺序和结构"))
        XCTAssertTrue(prompt.contains("不主动把一段口述扩写成任务书"))
        XCTAssertTrue(prompt.contains("保留原文自然口吻"))
        XCTAssertFalse(prompt.contains("大胆改写"))
        XCTAssertFalse(prompt.contains("语气示例"))
        XCTAssertEqual(options.temperature, 0)
        XCTAssertEqual(options.topP, 0.1)
        for mode in PolishMode.allCases where mode != .terminal && mode != .agent {
            let prompt = PolishOptions(mode: mode).systemPrompt
            XCTAssertTrue(prompt.contains("最小必要改动"))
            XCTAssertTrue(prompt.contains("禁止大幅改写"))
            XCTAssertFalse(prompt.contains("大胆改写"))
        }
    }

    func testStrongTonesAreDistinctAndOldStrengthHasNoEffect() {
        let normal = PolishOptions(tone: .normal).systemPrompt
        let sarcastic = PolishOptions(tone: .sarcastic).systemPrompt
        let moe = PolishOptions(tone: .moe).systemPrompt
        let rant = PolishOptions(tone: .rant).systemPrompt
        XCTAssertTrue(sarcastic.contains("极其刻薄"))
        XCTAssertTrue(moe.contains("极端浓烈"))
        XCTAssertTrue(rant.contains("火力拉满"))
        XCTAssertEqual(Set([normal, sarcastic, moe, rant]).count, 4)
        XCTAssertEqual(PolishOptions(strength: .light, scenario: .email).systemPrompt,
                       PolishOptions(strength: .heavy, scenario: .chat).systemPrompt)
        XCTAssertEqual(PolishOptions(mode: .terminal, tone: .moe).systemPrompt,
                       PolishOptions(mode: .terminal, tone: .sarcastic).systemPrompt)
    }
}
