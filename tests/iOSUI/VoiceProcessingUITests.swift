import XCTest

/// Narrow coverage for this change only; never starts ASR or a network link.
final class VoiceProcessingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSettingsAndTemporaryMicrophoneComparison() {
        for language in ["en", "zh-Hans"] { check(language: language) }
    }

    private func check(language: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview=settings", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        let setting = app.switches["voice-processing-setting"]
        reveal(setting, in: app)
        XCTAssertEqual(setting.value as? String, "1", "New key defaults ON; previous language restores ON")
        attach(app, name: "vpio-settings-\(language)")
        flip(setting)
        XCTAssertEqual(setting.value as? String, "0")
        let entry = app.buttons["open-mic-test"]
        reveal(entry, in: app, up: false)
        entry.tap()
        let toggle = app.buttons["mic-test-vpio-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        allowMicrophone()
        reveal(toggle, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(toggle.value as? String, "off", "Self-test initially uses saved raw path")
        toggle.tap()
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND value == %@", "on"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["mic-test-level-state"].exists)
        attach(app, name: "vpio-mic-test-\(language)")
        let copy = app.buttons["copy-mic-diagnostics"]
        reveal(copy, in: app)
        copy.tap()
        XCTAssertEqual(copy.label, language == "en" ? "Copied" : "已复制")
        let close = app.buttons["close-mic-test"]
        reveal(close, in: app, up: false)
        close.tap()
        reveal(setting, in: app)
        XCTAssertEqual(setting.value as? String, "0", "Temporary VPIO ON never writes saved OFF")
        reveal(entry, in: app, up: false)
        entry.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "off", "New self-test restores saved setting")
        reveal(close, in: app, up: false)
        close.tap()
        reveal(setting, in: app)
        flip(setting)
        XCTAssertEqual(setting.value as? String, "1")
        app.terminate()
        app.launch()
        reveal(setting, in: app)
        XCTAssertEqual(setting.value as? String, "1", "Preference survives process restart")
        app.terminate()
    }

    private func flip(_ toggle: XCUIElement) {
        let expected = toggle.value as? String == "1" ? "0" : "1"
        // SwiftUI exposes the full label row as Switch; hit its actual control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        for _ in 0..<10 {
            if element.isHittable { return }
            let micScroll = app.scrollViews["microphone-test-scroll"]
            let scroll = micScroll.exists ? micScroll : app.scrollViews.firstMatch
            if up { scroll.swipeUp() }
            else { scroll.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func allowMicrophone() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "允许", "OK", "好"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap(); return }
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
