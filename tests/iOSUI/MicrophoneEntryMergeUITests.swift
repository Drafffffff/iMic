import XCTest

/// Merge regression: exercise both MIC TEST presentations without granting microphone access.
final class MicrophoneEntryMergeUITests: XCTestCase {
    func testHomeAndSettingsKeepMicrophoneSelfTest() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["--ui-preview=mic-test", "-AppleLanguages", "(en)"]
        app.launch()
        let copy = app.buttons["copy-mic-diagnostics"]
        XCTAssertTrue(copy.waitForExistence(timeout: 20))
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Don't Allow", "Don’t Allow", "不允许"])).firstMatch
        XCTAssertTrue(deny.exists); deny.tap()
        let restart = app.buttons["Start microphone test"]
        if restart.waitForExistence(timeout: 2) { restart.tap() }
        XCTAssertTrue(app.staticTexts["mic-test-message"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["mic-test-message"].label, "Microphone access is off")
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let entry = app.buttons["open-mic-test"]
        for _ in 0..<8 {
            if entry.exists && app.scrollViews.firstMatch.frame.insetBy(dx: 0, dy: 24).contains(entry.frame) { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["mic-test-message"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["mic-test-message"].label, "Microphone access is off")
        app.buttons["Close"].firstMatch.tap()
        // The first real-input coach must also yield to the existing error action.
        app.terminate()
        app.launchArguments = ["--ui-preview=error", "--ui-preview=onboarding-ready", "-AppleLanguages", "(en)"]
        app.launch()
        let recovery = app.buttons["Open microphone test"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertTrue(recovery.isHittable); recovery.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["mic-test-message"].waitForExistence(timeout: 8))
        app.buttons["Close"].firstMatch.tap()
    }
}
