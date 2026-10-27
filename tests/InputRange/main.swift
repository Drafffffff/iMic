import Foundation
import XCTest

final class InputRangeTests: XCTestCase {
    func testExplicitClearRequiresAnEditableTextRole() {
        XCTAssertTrue(InputTarget.clearRoleAllowed("AXTextArea", valueSettable: true))
        XCTAssertTrue(InputTarget.clearRoleAllowed("AXTextField", valueSettable: true))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXWebArea", valueSettable: true))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXTextArea", valueSettable: false))
        XCTAssertFalse(InputTarget.clearRoleAllowed(nil, valueSettable: true))
        XCTAssertTrue(InputTarget.clearRoleAllowed("AXTextArea", valueSettable: false, selectedTextSettable: true))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXWebArea", valueSettable: false, selectedTextSettable: true))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXTextField", valueSettable: true, subrole: "AXSecureTextField"))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXTextArea", valueSettable: true, editable: false))
        XCTAssertFalse(InputTarget.clearRoleAllowed("AXTextArea", valueSettable: true, selectedTextSettable: false))
    }

    func testUnknownKeyboardSelectionDoesNotAcceptGhostCompletion() {
        XCTAssertEqual(InputTarget.keyboardInitialPreparation(selection: nil), .ready,
                       "An unreadable editor must receive text without a speculative Right or Tab key")
        XCTAssertEqual(InputTarget.keyboardInitialPreparation(selection: CFRange(location: 12, length: 0)), .ready)
        XCTAssertEqual(InputTarget.keyboardInitialPreparation(selection: CFRange(location: 4, length: 3)), .collapseSelection)
    }

    func testClearRequiresTheCompleteUnchangedFieldSelection() {
        let text = "清空👨‍👩‍👧‍👦这个输入框"
        XCTAssertTrue(InputTarget.clearSelectionMatches(original: text, current: text,
            selected: CFRange(location: 0, length: text.utf16.count)))
        XCTAssertFalse(InputTarget.clearSelectionMatches(original: text, current: text,
            selected: CFRange(location: 0, length: text.count)), "AX ranges use UTF-16, not graphemes")
        XCTAssertFalse(InputTarget.clearSelectionMatches(original: text, current: text,
            selected: CFRange(location: 1, length: text.utf16.count - 1)))
        XCTAssertFalse(InputTarget.clearSelectionMatches(original: text, current: text + "用户新输入",
            selected: CFRange(location: 0, length: text.utf16.count)))
        XCTAssertFalse(InputTarget.clearSelectionMatches(original: text, current: nil, selected: nil))
        XCTAssertFalse(InputTarget.clearSelectionMatches(original: "", current: "", selected: CFRange(location: 0, length: 0)))
    }

    func testSelectionFailureRecoversBeforeKeyboardFallbackWithoutWriting() {
        var selectionVisible = true
        var writes = 0
        let outcome = InputTailTransaction.perform(
            select: { false }, verify: { XCTFail("Cannot verify failed selection"); return false },
            restoreOriginal: { selectionVisible = false; return true },
            write: { writes += 1; return true }, restoreFinal: { true })
        XCTAssertEqual(outcome, .keyboard)
        XCTAssertFalse(selectionVisible)
        XCTAssertEqual(writes, 0)
    }

    func testTailVerificationFailureFallsBackOnlyAfterRecovery() {
        var calls: [String] = []
        let outcome = InputTailTransaction.perform(
            select: { calls.append("select"); return true },
            verify: { calls.append("verify"); return false },
            restoreOriginal: { calls.append("restore"); return true },
            write: { calls.append("write"); return true }, restoreFinal: { true })
        XCTAssertEqual(outcome, .keyboard)
        XCTAssertEqual(calls, ["select", "verify", "restore"])
    }

    func testUnrecoverableSelectionOrUserTakeoverBlocksFallback() {
        let outcome = InputTailTransaction.perform(
            select: { true }, verify: { false }, restoreOriginal: { false },
            write: { XCTFail("Must not modify text after failed recovery"); return true },
            restoreFinal: { XCTFail("Must not move caret after takeover"); return true })
        XCTAssertEqual(outcome, .blocked)
    }

    func testWriteThatTakesEffectButReportsFailureIsNeverReplayed() {
        var text = "原稿你好啊"
        var writes = 0
        let outcome = InputTailTransaction.perform(
            select: { true }, verify: { true },
            restoreOriginal: { XCTFail("Cannot restore old state after a write"); return true },
            write: { writes += 1; text = "原稿你好"; return false },
            restoreFinal: { XCTFail("Await fresh evidence after ambiguous write"); return true })
        XCTAssertEqual(outcome, .needsConfirmation)
        XCTAssertEqual(text, "原稿你好")
        XCTAssertEqual(writes, 1)
    }

    func testCaretFailureAfterSuccessfulWriteNeedsConfirmationNotFallback() {
        var writes = 0
        let outcome = InputTailTransaction.perform(
            select: { true }, verify: { true },
            restoreOriginal: { XCTFail("Do not restore original caret after replacement"); return true },
            write: { writes += 1; return true }, restoreFinal: { false })
        XCTAssertEqual(outcome, .needsConfirmation)
        XCTAssertEqual(writes, 1)
    }

    func testSuccessfulTransactionDoesNotUseRecovery() {
        let outcome = InputTailTransaction.perform(
            select: { true }, verify: { true },
            restoreOriginal: { XCTFail("Unexpected recovery"); return false },
            write: { true }, restoreFinal: { true })
        XCTAssertEqual(outcome, .applied)
    }

    func testCodexUsesKeyboardEvenWhenItAdvertisesRangeSupport() {
        // Regression: appending worked, but an earlier-word revision selected
        // the tail, opened the format popover, then froze the session.
        for canObserve in [true, false] {
            XCTAssertEqual(InputTarget.initialMode(bundleIdentifier: "com.openai.codex",
                                                   canObserveRange: canObserve), .keyboard)
        }
    }

    func testOttyPresentationRangesDoNotEnableAXRevision() {
        XCTAssertEqual(InputTarget.initialMode(bundleIdentifier: "io.appmakes.otty",
                                               canObserveRange: true), .keyboard)
    }

    func testOtherTargetsKeepRangeVerificationWhenAvailable() {
        for bundleIdentifier in [Optional("com.google.Chrome"), Optional("com.apple.Terminal"), nil] {
            XCTAssertEqual(InputTarget.initialMode(bundleIdentifier: bundleIdentifier,
                                                   canObserveRange: true), .verifiedRange)
            XCTAssertEqual(InputTarget.initialMode(bundleIdentifier: bundleIdentifier,
                                                   canObserveRange: false), .keyboard)
        }
    }

    func testFirstCharacterWrapMovesStartWithoutChangingOwnedText() {
        // The failure log had caret = expected + 1 after emitting one character.
        // A new display line before that character must not look like user editing.
        let range = InputRangeMatcher.range(in: "draft\n你", location: 858, text: "你", context: "draft")
        XCTAssertEqual(range?.location, 864)
        XCTAssertEqual(range?.length, 1)
    }

    func testWrapAfterLastCharacterKeepsTheRenderedCaretInTheOwnedSpan() {
        let range = InputRangeMatcher.range(in: "draft你\n", location: 858, text: "你", context: "draft")
        XCTAssertEqual(range?.location, 863)
        XCTAssertEqual(range?.length, 2)
    }

    func testWrappedTranscriptAndReflowedContextRemainVerifiable() {
        let range = InputRangeMatcher.range(in: "prefix draft你\n好吗", location: 100,
                                            text: "你好吗", context: "prefix\n draft")
        XCTAssertEqual(range?.location, 112)
        XCTAssertEqual(range?.length, 4)
    }

    func testNonBMPContextAndJoinedEmojiKeepUTF16Coordinates() {
        let range = InputRangeMatcher.range(in: "旧稿🧠\n你\n👩🏽‍💻", location: 200,
                                            text: "你👩🏽‍💻", context: "旧稿🧠")
        XCTAssertEqual(range?.location, 205)
        XCTAssertEqual(range?.length, 9)
    }

    func testDifferentOwnedTextCannotBeRevised() {
        XCTAssertNil(InputRangeMatcher.range(in: "draft你\n呀", location: 0,
                                              text: "你好", context: "draft"))
    }

    func testMatchingTextInAnotherDraftDoesNotTransferOwnership() {
        XCTAssertNil(InputRangeMatcher.range(in: "other draft你好", location: 0,
                                              text: "你好", context: "user draft"))
    }

    func testSpacesAndMissingExplicitLineBreaksAreNotSilentlyDiscarded() {
        XCTAssertNil(InputRangeMatcher.range(in: "draft你 好", location: 0,
                                              text: "你好", context: "draft"))
        XCTAssertNil(InputRangeMatcher.range(in: "draft你好", location: 0,
                                              text: "你\n好", context: "draft"))
    }

    func testEmptyTextCannotClaimAnArbitraryRange() {
        XCTAssertNil(InputRangeMatcher.range(in: "existing draft", location: 0,
                                              text: "", context: "draft"))
    }
}

let suite = XCTestSuite(forTestCaseClass: InputRangeTests.self)
suite.run()
guard let result = suite.testRun, result.executionCount > 0 else { fatalError("未发现输入范围行为测试") }
exit(result.totalFailureCount == 0 ? 0 : 1)
