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

    func testTerminalTextNeverContainsReturnOrTab() {
        let polished = "第一段整理好的内容。\n\nrm -rf ~\r\n最后\t一行\u{2028}结束"
        let safe = TypedTextSafety.sanitize(polished, terminal: true)
        XCTAssertNil(safe.rangeOfCharacter(from: .newlines))
        XCTAssertFalse(safe.contains("\t"))
        // One space per break keeps revision arithmetic over characters aligned.
        XCTAssertEqual(safe.count, polished.count)
        XCTAssertEqual(TypedTextSafety.sanitize("a\nb", terminal: false), "a\nb")
    }

    func testControlCharactersAreDroppedInEveryTarget() {
        let hostile = "删除\u{1b}[3~单词\u{7f}\u{0}\u{9b}结束"
        for terminal in [true, false] {
            let safe = TypedTextSafety.sanitize(hostile, terminal: terminal)
            XCTAssertEqual(safe, "删除[3~单词结束")
        }
        XCTAssertEqual(TypedTextSafety.sanitize("emoji 👩🏽‍💻 与中文", terminal: true), "emoji 👩🏽‍💻 与中文")
    }

    func testTerminalDetectionByBundleOrFocusedControl() {
        XCTAssertTrue(TypedTextSafety.isTerminal(bundleIdentifier: "com.apple.Terminal", labels: []))
        XCTAssertTrue(TypedTextSafety.isTerminal(bundleIdentifier: "com.todesktop.230313mzl4w4u92", labels: ["Terminal 1, zsh"]))
        XCTAssertTrue(TypedTextSafety.isTerminal(bundleIdentifier: "com.microsoft.VSCode", labels: [nil, "xterm-helper-textarea"]))
        XCTAssertTrue(TypedTextSafety.isTerminal(bundleIdentifier: nil, labels: ["终端"]))
        XCTAssertFalse(TypedTextSafety.isTerminal(bundleIdentifier: "com.apple.TextEdit", labels: ["文本", nil, ""]))
    }

    func testWideCharacterDetectionForTerminalGeometry() {
        XCTAssertTrue(TypedTextSafety.containsWideCharacters("今天开会"))
        XCTAssertTrue(TypedTextSafety.containsWideCharacters("ls 文件"))
        XCTAssertTrue(TypedTextSafety.containsWideCharacters("こんにちは"))
        XCTAssertTrue(TypedTextSafety.containsWideCharacters("안녕하세요"))
        XCTAssertTrue(TypedTextSafety.containsWideCharacters("全角，标点"))
        XCTAssertFalse(TypedTextSafety.containsWideCharacters("git switch main && git pull"))
        XCTAssertFalse(TypedTextSafety.containsWideCharacters("café naïve — ok"))
    }
}
