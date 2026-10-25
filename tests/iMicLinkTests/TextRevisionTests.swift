import XCTest
@testable import iMicLink

final class TextRevisionTests: XCTestCase {
    private func apply(_ revision: TextRevision, to text: String) -> String {
        String(text.dropLast(revision.deleteCount)) + revision.insertion
    }

    func testStreamingTailAndFinalCorrectionPreserveTypedPrefix() {
        let prefix = "把今天讨论的交互细节"
        let live = prefix + "整理成一页说明"
        let tail = TextRevision(from: prefix, to: live)
        XCTAssertEqual(tail.deleteCount, 0)
        XCTAssertEqual(tail.insertion, "整理成一页说明")
        let final = TextRevision(from: live, to: live + "。")
        XCTAssertEqual(final.deleteCount, 0)
        XCTAssertEqual(final.insertion, "。")
        XCTAssertEqual(apply(final, to: apply(tail, to: prefix)), live + "。")
    }

    func testCorrectionReplacesOnlyChangedTail() {
        let revision = TextRevision(from: "今天去公园散步", to: "今天去公司开会。")
        XCTAssertEqual(revision.deleteCount, 3)
        XCTAssertEqual(revision.insertion, "司开会。")
        XCTAssertEqual(apply(revision, to: "今天去公园散步"), "今天去公司开会。")
    }

    func testShorterFinalAndRepeatedFinalDoNotDuplicateText() {
        let final = "保留正文"
        let revision = TextRevision(from: final + "重复尾巴", to: final)
        XCTAssertEqual(revision.deleteCount, 4)
        XCTAssertEqual(revision.insertion, "")
        XCTAssertEqual(apply(revision, to: final + "重复尾巴"), final)
        let duplicate = TextRevision(from: final, to: final)
        XCTAssertEqual(duplicate.deleteCount, 0)
        XCTAssertEqual(duplicate.insertion, "")
    }

    func testDeletionCountsComposedCharactersNotUTF16Units() {
        let old = "文字\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}e\u{301}"
        let revision = TextRevision(from: old, to: "文字好")
        XCTAssertEqual(revision.deleteCount, 2)
        XCTAssertEqual(revision.insertion, "好")
        XCTAssertEqual(apply(revision, to: old), "文字好")
    }
}
