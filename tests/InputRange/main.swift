import Foundation
import XCTest

final class InputRangeTests: XCTestCase {
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
