import AppKit
import XCTest

final class PolishEffectTests: XCTestCase {
    func testSingleLineCanLocateShortVisibleTailOfLongValue() {
        let visible = "这里是搜索框实际可见的结尾"
        let expected = String(repeating: "前面已经横向隐藏的文字", count: 20)+visible
        XCTAssertNil(TextRegionMatcher.match(expected: expected, fragments: [visible]))
        let match = TextRegionMatcher.locate(expected: expected, fragments: [visible], allowClipped: true)
        XCTAssertEqual(match?.spans.map(\.fragment), [0])
        XCTAssertEqual(match?.includesEnd, true)
    }
    func testSingleLineMiddleSliceDoesNotClaimHiddenEndpoint() {
        let visible = "这里是横向滚动后可见的中间文字"
        let match = TextRegionMatcher.locate(expected: "隐藏的开头"+visible+"隐藏的结尾", fragments: [visible], allowClipped: true)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.includesEnd, false)
    }
    func testSingleLineRejectsRepeatedOrVeryShortVisibleText() {
        let visible = "搜索框里重复出现的文字"
        XCTAssertNil(TextRegionMatcher.locate(expected: "隐藏开头"+visible, fragments: [visible, visible], allowClipped: true))
        XCTAssertNil(TextRegionMatcher.locate(expected: "隐藏开头后面的好的", fragments: ["好的"], allowClipped: true))
    }
    func testSingleLineDoesNotMatchSmallPhraseInUnrelatedDraft() {
        let visible = "本轮输入的独特结尾"
        XCTAssertNil(TextRegionMatcher.locate(expected: "已经隐藏的前缀"+visible,
            fragments: [String(repeating: "其他旧草稿内容", count: 20)+visible], allowClipped: true))
    }
    func testLongScrollingDocumentStillHasVisibleAnimationRegion() {
        let content = CGRect(x: 20, y: -4000, width: 700, height: 5000)
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let viewport = CGRect(x: 20, y: 300, width: 700, height: 220)
        XCTAssertFalse(window.contains(content))
        XCTAssertEqual(TextViewport.visible(content: content, window: window, clips: [viewport]), viewport)
    }
    func testNestedScrollContainersClipLongDocumentAndExcludeHiddenArea() {
        let content = CGRect(x: 20, y: -4000, width: 700, height: 5000)
        let visible = TextViewport.visible(content: content, window: CGRect(x: 0, y: 0, width: 800, height: 600),
                     clips: [CGRect(x: 20, y: 200, width: 700, height: 350), CGRect(x: 20, y: 300, width: 700, height: 150)])
        XCTAssertEqual(visible, CGRect(x: 20, y: 300, width: 700, height: 150))
        XCTAssertNil(TextViewport.visible(content: content, window: CGRect(x: 0, y: 1200, width: 800, height: 600), clips: []))
    }
    func testGesturesStayLockedThroughPostWriteRelease() {
        var effect = PolishEffectLifecycle()
        XCTAssertFalse(effect.blocksGestures)
        effect.beginPreparation()
        XCTAssertTrue(effect.blocksGestures)
        XCTAssertTrue(effect.visualPrepared())
        effect.sweepFinished()
        XCTAssertTrue(effect.blocksGestures)
        XCTAssertTrue(effect.selectResult())
        XCTAssertTrue(effect.beginWriting())
        XCTAssertTrue(effect.blocksGestures)
        XCTAssertTrue(effect.beginRelease())
        XCTAssertTrue(effect.blocksGestures, "Committing text is not the end of its release animation")
        effect.finish()
        XCTAssertFalse(effect.blocksGestures)
    }
    func testShortSingleLineExpandsWithoutWrapping() {
        let rows = PolishEndpointEstimate.layout(original: "字字", final: String(repeating: "字", count: 8),
                    rows: [CGRect(x: 10, y: 10, width: 20, height: 20)], field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(rows, [CGRect(x: 10, y: 10, width: 80, height: 20)])
    }
    func testShortSingleLineBecomesThreeLines() {
        let rows = PolishEndpointEstimate.layout(original: "字字", final: String(repeating: "字", count: 25),
                    rows: [CGRect(x: 10, y: 10, width: 20, height: 20)], field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.width), [90, 90, 70])
    }
    func testUpwardGrowingFieldRebasesOriginalText() {
        let rows = PolishEndpointEstimate.layout(original: "字字", final: String(repeating: "字", count: 25),
                    rows: [CGRect(x: 10, y: 110, width: 20, height: 20)], field: CGRect(x: 0, y: 0, width: 120, height: 140),
                    referenceField: CGRect(x: 0, y: 100, width: 120, height: 40))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.minY, 10)
        XCTAssertEqual(rows.last?.minY, 60)
    }
    func testOverflowingGrowthKeepsFinalRailAndEndpointTogether() {
        let field = CGRect(x: 0, y: 0, width: 120, height: 40)
        let original = [CGRect(x: 10, y: 10, width: 20, height: 20)]
        let final = String(repeating: "字", count: 25)
        let rows = PolishEndpointEstimate.layout(original: "字字", final: final, rows: original, field: field)
        let end = PolishEndpointEstimate.endpoint(original: "字字", final: final, rows: original, field: field)
        XCTAssertEqual(rows.last?.width, 70)
        XCTAssertEqual(end, rows.last.map { CGPoint(x: $0.maxX, y: $0.midY) })
        XCTAssertTrue(rows.allSatisfy { field.contains($0) })
    }
    func testEstimatedRailsShrinkToFinalTextAndDiscardOldRows() {
        let rows = [CGRect(x: 10, y: 10, width: 100, height: 20), CGRect(x: 10, y: 34, width: 100, height: 20)]
        let final = PolishEndpointEstimate.layout(original: String(repeating: "字", count: 20), final: String(repeating: "字", count: 6),
                                                 rows: rows, field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(final, [CGRect(x: 10, y: 10, width: 60, height: 20)])
    }
    func testEstimatedRailsRespectExplicitLineBreakAndFinalTail() {
        let final = PolishEndpointEstimate.layout(original: String(repeating: "字", count: 10), final: "字字\n字字字",
                    rows: [CGRect(x: 10, y: 10, width: 100, height: 20)], field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(final.last?.width, 30)
        XCTAssertGreaterThan(final[1].minY, final[0].maxY)
    }
    func testShorterResultMovesEstimatedEndpointUp() {
        let rows = [CGRect(x: 10, y: 10, width: 100, height: 20), CGRect(x: 10, y: 34, width: 100, height: 20)]
        let point = PolishEndpointEstimate.endpoint(original: String(repeating: "字", count: 20), final: String(repeating: "字", count: 10),
                                                    rows: rows, field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(point?.y, 20)
        XCTAssertEqual(point?.x, 110)
    }
    func testLongerResultWrapsToANewEstimatedLine() {
        let rows = [CGRect(x: 10, y: 10, width: 100, height: 20), CGRect(x: 10, y: 34, width: 100, height: 20)]
        let point = PolishEndpointEstimate.endpoint(original: String(repeating: "字", count: 20), final: String(repeating: "字", count: 25),
                                                    rows: rows, field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(point?.y, 68)
        XCTAssertEqual(point?.x, 60)
    }
    func testEstimatedEndpointPreservesFirstLineDraftIndent() {
        let rows = [CGRect(x: 50, y: 10, width: 60, height: 20), CGRect(x: 10, y: 34, width: 100, height: 20)]
        let point = PolishEndpointEstimate.endpoint(original: String(repeating: "字", count: 16), final: String(repeating: "字", count: 5),
                                                    rows: rows, field: CGRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertEqual(point, CGPoint(x: 100, y: 20))
    }
    func testEstimatedEndpointIsClampedToViewport() {
        let field = CGRect(x: 0, y: 0, width: 120, height: 70)
        let point = PolishEndpointEstimate.endpoint(original: String(repeating: "字", count: 100), final: String(repeating: "字", count: 500),
                    rows: [CGRect(x: 10, y: 10, width: 100, height: 20)], field: field, visibleUnits: 10)
        XCTAssertNotNil(point)
        XCTAssertTrue(field.contains(point!))
    }
    func testSlowResultHoldsAfterIntroUntilResultIsReady() {
        var flow = PolishEffectLifecycle()
        flow.beginPreparation()
        XCTAssertTrue(flow.visualPrepared())
        flow.sweepFinished()
        XCTAssertEqual(flow.phase, .holding)
        XCTAssertFalse(flow.beginWriting())
        XCTAssertTrue(flow.selectResult())
        XCTAssertTrue(flow.beginWriting())
        XCTAssertEqual(flow.phase, .writing)
    }
    func testFastResultStillWaitsForIntroAndWritesOnlyOnce() {
        var flow = PolishEffectLifecycle()
        flow.beginPreparation()
        XCTAssertTrue(flow.selectResult())
        XCTAssertFalse(flow.beginWriting())
        XCTAssertTrue(flow.visualPrepared())
        XCTAssertFalse(flow.beginWriting())
        flow.sweepFinished()
        XCTAssertTrue(flow.beginWriting())
        XCTAssertFalse(flow.beginWriting())
        XCTAssertFalse(flow.selectResult())
    }
    func testResultArrivingMidSweepDoesNotRemoveOverlay() {
        var flow = PolishEffectLifecycle()
        flow.beginPreparation(); XCTAssertTrue(flow.visualPrepared())
        XCTAssertTrue(flow.selectResult())
        XCTAssertEqual(flow.phase, .sweeping)
        XCTAssertFalse(flow.beginRelease())
        flow.sweepFinished(); XCTAssertTrue(flow.beginWriting())
        XCTAssertTrue(flow.beginRelease())
        XCTAssertFalse(flow.beginRelease())
        XCTAssertFalse(flow.beginWriting())
    }
    func testMissingGeometryDoesNotBlockFinalResult() {
        var flow = PolishEffectLifecycle()
        flow.beginPreparation(); flow.skipVisual()
        XCTAssertTrue(flow.selectResult())
        XCTAssertTrue(flow.beginWriting())
    }
    func testCancelledIntroCannotResumeFromLateOCRorResult() {
        var flow = PolishEffectLifecycle()
        flow.beginPreparation(); flow.cancel()
        XCTAssertFalse(flow.visualPrepared())
        XCTAssertFalse(flow.selectResult())
        flow.sweepFinished(); flow.skipVisual()
        XCTAssertFalse(flow.beginWriting())
    }
    func testFailedWriteCanFinishWithoutSuccessRelease() {
        var flow = PolishEffectLifecycle()
        flow.skipVisual(); XCTAssertTrue(flow.selectResult())
        XCTAssertTrue(flow.beginWriting()); flow.finish()
        XCTAssertFalse(flow.beginRelease())
        XCTAssertFalse(flow.selectResult())
    }
    func testNewPreparationDoesNotInheritPreviousResult() {
        var flow = PolishEffectLifecycle()
        XCTAssertTrue(flow.selectResult()); XCTAssertTrue(flow.beginWriting())
        flow.finish(); flow.beginPreparation()
        XCTAssertFalse(flow.hasResult)
        XCTAssertEqual(flow.phase, .locating)
    }
    func testOCRFragmentsMergeIntoRowsInReadingOrder() {
        let firstLeft = CGRect(x: 20, y: 100, width: 80, height: 18)
        let firstRight = CGRect(x: 110, y: 101, width: 90, height: 17)
        let second = CGRect(x: 20, y: 125, width: 150, height: 18)
        XCTAssertEqual(SweepLineLayout.rows(in: [second, firstRight, .zero, firstLeft]),
                       [firstLeft.union(firstRight), second])
    }
    func testSeparateLinesDoNotBecomeOneParagraphBox() {
        let rows = [CGRect(x: 10, y: 20, width: 100, height: 18),
                    CGRect(x: 10, y: 42, width: 60, height: 18)]
        XCTAssertEqual(SweepLineLayout.rows(in: rows), rows)
    }
    func testRowStaggerIsOrderedAndHandoffRemainsBounded() {
        for count in [1, 3, 8, 40] {
            let delays = (0..<count).map { SweepLineLayout.delay(row: $0, lineCount: count) }
            XCTAssertEqual(delays, delays.sorted())
            XCTAssertEqual(delays[0], 0)
            XCTAssertLessThanOrEqual(SweepLineLayout.duration(lineCount: count), 0.5)
            XCTAssertEqual(delays.last! + SweepLineLayout.lineDuration,
                           SweepLineLayout.duration(lineCount: count), accuracy: 0.0001)
        }
    }
    func testSuccessfulPolishWinsExactlyOnce() {
        var choice = PolishFinalChoice()
        XCTAssertEqual(choice.settle(raw: "原文", polished: " 整理后的文字\n"), "整理后的文字")
        XCTAssertNil(choice.settle(raw: "原文", polished: nil))
        XCTAssertEqual(choice.source, .polished)
    }
    func testTimeoutWinsOverLateResponse() {
        var choice = PolishFinalChoice()
        XCTAssertEqual(choice.settle(raw: "百炼完整原文", polished: nil), "百炼完整原文")
        XCTAssertNil(choice.settle(raw: "百炼完整原文", polished: "迟到的润色"))
        XCTAssertEqual(choice.source, .original)
    }
    func testEmptyPolishFallsBackWithoutDroppingOriginal() {
        var choice = PolishFinalChoice()
        XCTAssertEqual(choice.settle(raw: "完整原文", polished: " \n"), "完整原文")
    }
    func testFindsOwnedTextAcrossWrappedLinesAndExcludesDraft() {
        let draft = "原稿不要覆盖。"
        let fragments = [draft + "今天讨论覆盖层的视觉效果", "希望扫光只覆盖本轮新增的文字", "然后一次替换成整理后的内容"]
        let text = "今天讨论覆盖层的视觉效果，希望扫光只覆盖本轮新增的文字，然后一次替换成整理后的内容。"
        let result = TextRegionMatcher.match(expected: text, fragments: fragments)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?.first?.range.location, draft.utf16.count)
        XCTAssertEqual(result?.last?.fragment, 2)
    }
    func testNormalizationKeepsOriginalUTF16Coordinates() {
        let draft = "旧稿👩🏽‍💻："
        let text = "今天讨论 IMIC 的文字覆盖效果，最终只回写一次完整结果。"
        let fragment = draft + "今天讨论ｉＭｉｃ的文字覆盖效果最终只回写一次完整结果"
        let result = TextRegionMatcher.match(expected: text, fragments: [fragment])
        XCTAssertEqual(result?.first?.range.location, draft.utf16.count)
        XCTAssertEqual(result?.count, 1)
    }
    func testOneOCRSubstitutionDoesNotLoseWholeRegion() {
        let expected = "今天讨论文字区域的覆盖效果希望高亮只覆盖本轮新增的文字同时保留之前已经写好的原稿内容"
        let source = expected.replacingOccurrences(of: "高亮", with: "高壳")
        XCTAssertNotNil(TextRegionMatcher.match(expected: expected, fragments: [source]))
    }
    func testRepeatedDraftIsAmbiguousAndMustNotBeHighlighted() {
        let text = "这是一段可能在原稿和本轮输入中重复出现的完整文字"
        XCTAssertNil(TextRegionMatcher.match(expected: text, fragments: [text, text]))
    }
    func testUnrelatedTextAndShortCommonWordsAreRejected() {
        XCTAssertNil(TextRegionMatcher.match(expected: "完整的语音识别文字需要及时保留", fragments: ["这是另一段完全无关的原稿内容"]))
        XCTAssertNil(TextRegionMatcher.match(expected: "好的", fragments: ["之前的原稿里也有好的两个字"]))
    }
    func testVeryLongDictationMatchesVisibleTailBeyondMatcherBudget() {
        let suffix = "最后可见的本轮文字包含一个独特结论：滚动输入框必须按可见区域定位动画，并保留屏幕外已经输入的全部内容。"
        let text = String(repeating: "这部分已经滚出输入框的可见区域。", count: 300)+suffix
        let result = TextRegionMatcher.match(expected: text, fragments: ["旧草稿的尾部", suffix])
        XCTAssertEqual(result?.map(\.fragment), [1])
        XCTAssertEqual(result?.last?.range.length, (suffix as NSString).length-1)
    }
    func testOnlyVisibleSuffixOfLongTranscriptCanBeMatched() {
        let suffix = "这是当前输入框最后可见的文字需要保留完整的逐行区域并在润色结束后播放扫光"
        let text = String(repeating: "前面已经滚出屏幕的内容", count: 30) + suffix
        let result = TextRegionMatcher.match(expected: text, fragments: ["其他原稿", suffix])
        XCTAssertEqual(result?.first?.fragment, 1)
    }
    func testCancelledSessionCannotPublishMatch() {
        XCTAssertNil(TextRegionMatcher.match(expected: "这是一段完整的测试文字", fragments: ["这是一段完整的测试文字"], cancelled: { true }))
    }
    func testMissingPermissionOrLocationReleasesFinalDeliveryImmediately() {
        let effect = TextPolishEffect()
        var commits = 0
        effect.deliverAfterSweep { commits += 1 }
        XCTAssertEqual(commits, 1)
        effect.cancel()
        XCTAssertFalse(effect.didShowSweep)
    }
}

func runSingleLineFixture() {
    TextPolishEffect.prewarm()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let previous = NSWorkspace.shared.frontmostApplication
    let window = NSWindow(contentRect: NSRect(x: 200, y: 330, width: 540, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "iMic · SINGLE LINE TEST"
    let field = NSTextField(frame: NSRect(x: 30, y: 50, width: 480, height: 36))
    field.font = .systemFont(ofSize: 20)
    field.isEditable = true; field.isSelectable = true; field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false; field.cell?.isScrollable = true
    let preview = String(repeating: "前面的文字横向隐藏。", count: 12)+"这里是输入框当前可见的独特尾部文字"
    let final = preview+"，这是润色后的结论。"
    field.stringValue = preview
    window.contentView?.addSubview(field)
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
    app.activate(ignoringOtherApps: true)
    func scrollToEnd() {
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
    let effect = TextPolishEffect()
    DispatchQueue.main.asyncAfter(deadline: .now()+2) {
        scrollToEnd()
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = InputTarget.capture(pid: pid)
        print("VISUAL_SINGLE_LINE focus=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        effect.prepare(pid: pid, element: target.visualElement, text: preview,
                       allowed: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }, interrupted: {})
        DispatchQueue.main.asyncAfter(deadline: .now()+4) {
            effect.deliverAfterSweep {
                field.stringValue = final; scrollToEnd()
                effect.finishDelivery(succeeded: true, finalText: final, verified: false)
                print("VISUAL_SINGLE_LINE sweep=\(effect.didShowSweep) commits=1 chars=\(final.count)")
                DispatchQueue.main.asyncAfter(deadline: .now()+1.3) {
                    effect.cancel(); window.orderOut(nil); previous?.activate(options: [])
                    app.stop(nil)
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(event, atStart: true) }
                }
            }
        }
    }
    app.run()
}

if CommandLine.arguments.contains("--single-line") {
    runSingleLineFixture()
} else if CommandLine.arguments.contains("--visual") {
    TextPolishEffect.prewarm()
    let previous = NSWorkspace.shared.frontmostApplication
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 180, y: 280, width: 760, height: 270), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "iMic · POLISH SWEEP TEST"
    let growing = CommandLine.arguments.contains("--grow")
    let long = CommandLine.arguments.contains("--long")
    let text = NSTextView(frame: NSRect(x: 24, y: 24, width: 712, height: growing ? 70 : 210))
    text.font = .systemFont(ofSize: 19)
    text.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    text.textColor = .white
    text.textContainerInset = NSSize(width: 12, height: 12)
    if growing { text.isVerticallyResizable = false }
    let prefix = growing || long ? "" : "原稿：这一行需要保留，不能被扫光覆盖。\n"
    let preview = long ? String(repeating: "较早输入的内容已经滚动到可见区域以外，需要保留完整正文。", count: 80)+"这是本轮长文独有的可见尾段。动画需要跟随当前可见文字，不能因为整篇文档高度超出窗口就停止。我们继续检查自动滚动后的每一行坐标是否仍然可以获取。" : growing ? "请把这句话扩展为四行说明文字" : "今天讨论文字区域覆盖的效果希望高亮只覆盖这次新增的文字不要覆盖前面的原稿继续补充一段较长的文字检查自动换行后每一行的坐标最后统一替换成整理后的内容"
    text.string = prefix + preview
    if long {
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 24, width: 712, height: 210))
        scroll.hasVerticalScroller = true
        text.isVerticallyResizable = true
        text.textContainer?.containerSize = NSSize(width: 690, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        window.contentView?.addSubview(scroll)
        text.sizeToFit(); text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
    } else { window.contentView?.addSubview(text) }
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
    app.activate(ignoringOtherApps: true)
    let effect = TextPolishEffect()
    var choice = PolishFinalChoice()
    let fallback = CommandLine.arguments.contains("--fallback")
    let raw = "今天讨论文字区域覆盖的效果，希望高亮只覆盖这次新增的文字，不覆盖前面的原稿。继续补充较长文字，检查自动换行后的坐标，最后统一替换。"
    let polished = long ? preview+"最后补充一句润色后的结论。" : growing ? "第一行：文字从少量扩展成更完整的内容。\n第二行：输入框需要在结果写入后向上增高。\n第三行：新增的底线从左侧展开，并跟随新的文字区域。\n第四行：等待整体对齐后，再播放结束效果。" : "今天讨论文字区域的覆盖效果：高亮仅覆盖本轮新增内容，保留原稿；自动换行后仍能准确定位，最后统一替换为整理后的文字。"
    let mode = long ? "long" : growing ? "grow" : CommandLine.arguments.contains("--cancel") ? "cancel" : CommandLine.arguments.contains("--slow") ? "slow" : fallback ? "fallback" : "fast"
    var phaseTimer: Timer?
    var captured = Set<PolishEffectLifecycle.Phase>()
    func finishFixture() {
        phaseTimer?.invalidate(); effect.cancel(); window.orderOut(nil)
        previous?.activate(options: []); app.stop(nil)
        // A CLI-owned AppKit run loop can remain inside nextEvent after stop()
        // when the visual path was skipped and no window event wakes it.
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            app.postEvent(wake, atStart: true)
        }
    }
    phaseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        let phase = effect.phase
        guard [.sweeping, .holding, .releasing].contains(phase), !captured.contains(phase) else { return }
        captured.insert(phase)
        print("VISUAL_PHASE=\(phase)")
        DispatchQueue.main.asyncAfter(deadline: .now()+0.04) {
            guard window.isVisible, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let r = window.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
            capture.arguments = ["-x", "-R\(Int(r.minX)),\(Int(top-r.maxY)),\(Int(r.width)),\(Int(r.height))", "/tmp/imic-sweep-\(mode)-\(phase).png"]
            try? capture.run()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (long ? 2.0 : 0.5)) {
        let pid = ProcessInfo.processInfo.processIdentifier
        print("VISUAL_FOCUS ready=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        let target = InputTarget.capture(pid: pid)
        effect.prepare(pid: pid, element: target.visualElement, text: preview,
                       allowed: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }, interrupted: {})
        if mode == "cancel" {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.25) { effect.cancel() }
        }
        let resultDelay = long ? 8.0 : (mode == "slow" || growing) ? 3.0 : mode == "fast" ? 0.03 : 1.2
        DispatchQueue.main.asyncAfter(deadline: .now()+resultDelay) {
            precondition(text.string == prefix+preview, "Intermediate ASR leaked to UI")
            let final = choice.settle(raw: raw, polished: fallback ? nil : polished)!
            var commits = 0
            effect.deliverAfterSweep {
                commits += 1
                text.string = prefix+final
                if long {
                    text.sizeToFit(); text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
                    print("VISUAL_LONG chars=\(final.count) documentHeight=\(Int(text.frame.height))")
                }
                if growing {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.08) {
                        text.setFrameSize(NSSize(width: 712, height: 210))
                        print("VISUAL_GROW fieldHeight=70->210")
                    }
                }
                precondition(commits == 1)
                precondition(choice.settle(raw: raw, polished: "迟到结果") == nil)
                effect.finishDelivery(succeeded: true, finalText: final,
                                      verified: !CommandLine.arguments.contains("--unverified"))
                print("VISUAL_COMMIT source=\(fallback ? "original" : "polished") sweep=\(effect.didShowSweep) commits=\(commits)")
                DispatchQueue.main.asyncAfter(deadline: .now()+0.9) { finishFixture() }
            }
            if mode == "cancel" {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.8) {
                    precondition(commits == 0, "Cancelled animation committed stale text")
                    precondition(text.string == prefix+preview)
                    print("VISUAL_CANCEL commits=0 textUnchanged=true")
                    finishFixture()
                }
            }
        }
    }
    app.run()
} else {
    let suite = XCTestSuite(forTestCaseClass: PolishEffectTests.self)
    suite.run()
    guard let result = suite.testRun, result.executionCount > 0 else { fatalError("未发现扫光测试") }
    exit(result.totalFailureCount == 0 ? 0 : 1)
}
