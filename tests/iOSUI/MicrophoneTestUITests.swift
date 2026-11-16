import XCTest

final class MicrophoneTestUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testEnglishSelfTest() { check(language: "en", copy: "Copy diagnostics", close: "Close") }
    func testChineseSelfTest() { check(language: "zh-Hans", copy: "复制诊断信息", close: "关闭") }

    private func check(language: String, copy: String, close: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview=mic-test", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["copy-mic-diagnostics"].waitForExistence(timeout: 20))
        // Use the normal system permission UI on our disposable simulator only.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "允许", "OK", "好"] {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 1) { allow.tap(); break }
        }
        let restart = app.buttons[language == "en" ? "Start microphone test" : "开始麦克风自检"]
        if restart.waitForExistence(timeout: 2) {
            for _ in 0..<6 {
                if restart.isHittable { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            if restart.isHittable { restart.tap() }
            for _ in 0..<6 {
                if app.buttons[close].firstMatch.isHittable { break }
                app.scrollViews.firstMatch.swipeDown()
            }
        }
        // Native input may be unavailable in Simulator; either live levels or a
        // bounded failure is valid. Never assert that simulator silence is a bug.
        sleep(4)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "mic-test-\(language)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let rebuild = app.buttons["rebuild-audio-route"]
        for _ in 0..<6 {
            if rebuild.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(rebuild.exists)
        if rebuild.isEnabled {
            rebuild.tap()
            let spent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: rebuild)
            XCTAssertEqual(XCTWaiter.wait(for: [spent], timeout: 8), .completed)
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: rebuild)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
            // A second deliberate click is a new manual test; it still shows
            // one recovery, rather than quietly granting an automatic retry.
            rebuild.tap()
            let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND value == %@", "1"), object: rebuild)
            XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 8), .completed)
        }
        app.scrollViews.firstMatch.swipeUp()
        sleep(1)
        let recoveryShot = XCTAttachment(screenshot: app.screenshot())
        recoveryShot.name = "mic-route-recovery-\(language)"
        recoveryShot.lifetime = .keepAlways
        add(recoveryShot)
        let copyButton = app.buttons["copy-mic-diagnostics"]
        for _ in 0..<5 {
            if copyButton.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(copyButton.isHittable)
        copyButton.tap()
        XCTAssertTrue(app.buttons["copy-mic-diagnostics"].label == (language == "en" ? "Copied" : "已复制"))
        for _ in 0..<6 {
            if app.buttons[close].firstMatch.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
        }
        app.buttons[close].firstMatch.tap()
        XCTAssertTrue(app.buttons[language == "en" ? "Settings" : "设置"].waitForExistence(timeout: 8))
        // Also exercise the real Settings entry instead of just the DEBUG shortcut.
        app.buttons[language == "en" ? "Settings" : "设置"].tap()
        let entry = app.buttons["open-mic-test"]
        for _ in 0..<8 {
            if entry.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.buttons["copy-mic-diagnostics"].waitForExistence(timeout: 8))
        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "mic-test-settings-\(language)"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)
        for _ in 0..<6 {
            if app.buttons[close].firstMatch.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
        }
        app.buttons[close].firstMatch.tap()
    }
}
