import XCTest

/// Opt-in capture against a headless Mac and system TTS. Uses the real encrypted
/// audio/recognition path and the unchanged native hold/cancel gestures.
final class RecordingCollapseUITests: XCTestCase {
    func testRecordingRelease() throws {
        let mode=ProcessInfo.processInfo.environment["IMIC_COLLAPSE_CAPTURE"] ?? ""
        try XCTSkipUnless(["send","cancel"].contains(mode),"Run from scripts/capture-recording-collapse.sh")
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--debug-host=127.0.0.1","--debug-port=47856","--debug-pair-code=864209",
            "--debug-tts=今天我们来检查录音时的界面变化。按住说话时，界面慢慢向接收线圈收缩，边缘出现细微的光丝，按钮和计时数字保持清晰。现在继续说一段足够长的话，确认输入电平能够轻轻带动空间呼吸，长时间录音也不会让文字变得难以阅读。最后松开按钮，观察界面平稳恢复。"]
        app.launch()
        let bar=app.buttons["home.hold"]
        let listening=NSPredicate(format:"label == %@","RELEASE TO SEND")
        expectation(for:listening,evaluatedWith:bar)
        waitForExpectations(timeout:30)
        // Leave one second for the capture process to observe the visible recording.
        Thread.sleep(forTimeInterval:1)
        let start=bar.coordinate(withNormalizedOffset:CGVector(dx:0.42,dy:0.5))
        if mode == "cancel" {
            start.press(forDuration:11,thenDragTo:start.withOffset(CGVector(dx:0,dy:-100)),
                        withVelocity:400,thenHoldForDuration:0.3)
        } else {
            start.press(forDuration:11)
        }
        expectation(for:NSPredicate(format:"label != %@ AND label != %@","RELEASE TO SEND","RELEASE TO CANCEL"),evaluatedWith:bar)
        waitForExpectations(timeout:10)
        Thread.sleep(forTimeInterval:2)
        let attachment=XCTAttachment(screenshot:app.screenshot())
        attachment.name="collapse-\(mode)-settled"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
