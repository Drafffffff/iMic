import XCTest

/// These tests start the shipping onboarding path, without --ui-preview or demo scripts.
final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["--debug-reset-onboarding", "--debug-onboarding-audit", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.start"].waitForExistence(timeout: 20))
        app.buttons["onboarding.start"].tap()
        prompt("Hold the bar and speak", app)
        return app
    }
    private func prompt(_ text: String, _ app: XCUIApplication) {
        let target = app.staticTexts["onboarding.prompt"]
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 10), .completed, target.debugDescription)
    }
    private func drag(_ app: XCUIApplication, dx: CGFloat = 0, dy: CGFloat, hold: TimeInterval = 0.1) {
        let string = app.otherElements["home.string"]
        XCTAssertTrue(string.waitForExistence(timeout: 5))
        let center = string.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.08, thenDragTo: center.withOffset(CGVector(dx: dx, dy: dy)),
                     withVelocity: 650, thenHoldForDuration: hold)
    }
    private func core(_ app: XCUIApplication) {
        // Short presses must not advance the lesson.
        app.buttons["home.hold"].press(forDuration: 0.12)
        prompt("Hold the bar and speak", app)
        app.buttons["home.hold"].press(forDuration: 1.0)
        prompt("Pull the string to send", app)
        drag(app, dy: 180)
        XCTAssertTrue(app.buttons["onboarding.more"].waitForExistence(timeout: 8))
    }
    private func isolation(_ app: XCUIApplication) {
        app.buttons["onboarding.auditCheck"].tap()
        let audit = app.staticTexts["onboarding.audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        print("PRACTICE AUDIT: \(audit.label)")
        XCTAssertTrue(audit.label.contains("link=0 send=0 mic=undetermined speech=undetermined practice=true"), audit.label)
    }
    func testCoreAndAllOptionalGesturesAreOffline() {
        let app = launch()
        core(app)
        isolation(app)
        app.buttons["onboarding.more"].tap()
        prompt("Pull up to delete", app)
        drag(app, dy: -80, hold: 0.3)
        prompt("Slide sideways to move the cursor", app)
        drag(app, dx: 90, dy: 0)
        prompt("Pull to the top to clear", app)
        let center = app.otherElements["home.string"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 65)))
        prompt("Hold, then slide up to cancel", app)
        isolation(app)
        let bar = app.buttons["home.hold"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bar.press(forDuration: 0.6, thenDragTo: bar.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertTrue(app.buttons["onboarding.connectLater"].waitForExistence(timeout: 10))
        app.buttons["onboarding.connectLater"].tap()
        XCTAssertFalse(app.staticTexts["onboarding.prompt"].exists)
        XCTAssertTrue(app.buttons["home.hold"].waitForExistence(timeout: 5))
        app.buttons["onboarding.auditCheck"].tap()
        print("PRACTICE CLEANUP: \(app.staticTexts["onboarding.audit"].label)")
        XCTAssertTrue(app.staticTexts["onboarding.audit"].label.contains("practice=false phase=idle text=0"))
        XCTAssertTrue(app.staticTexts["onboarding.audit"].label.contains("deferred=true idle=true"))
        XCTAssertEqual(app.buttons["home.hold"].label, "LINK TO MAC")
    }
    func testSkipRestoreAndConnectLater() {
        let app = launch()
        app.buttons["onboarding.skip"].tap()
        prompt("Pull the string to send", app)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        prompt("Pull the string to send", app)
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.buttons["onboarding.connectLater"].waitForExistence(timeout: 8))
        app.buttons["onboarding.connectLater"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home.hold"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.start"].exists)
        XCTAssertEqual(app.buttons["home.hold"].label, "LINK TO MAC")
    }
    func testOptionalSkipAndReplayFromSettings() {
        let app = launch()
        core(app)
        app.buttons["onboarding.more"].tap()
        for text in ["Pull up to delete", "Slide sideways to move the cursor", "Pull to the top to clear", "Hold, then slide up to cancel"] {
            prompt(text, app); app.buttons["onboarding.skip"].tap()
        }
        XCTAssertTrue(app.buttons["onboarding.connectLater"].waitForExistence(timeout: 10))
        app.buttons["onboarding.connectLater"].tap()
        app.buttons["Settings"].tap()
        let tutorial = app.buttons["Practice gestures again"]
        for _ in 0..<9 {
            if tutorial.exists && app.scrollViews.firstMatch.frame.insetBy(dx: 0, dy: 30).contains(tutorial.frame) { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(tutorial.isHittable); tutorial.tap()
        prompt("Hold the bar and speak", app)
        isolation(app)
        app.buttons["onboarding.skip"].tap()
        prompt("Pull the string to send", app)
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 5))
        app.buttons["onboarding.later"].tap()
        XCTAssertFalse(app.buttons["onboarding.connectLater"].exists)
        XCTAssertTrue(app.buttons["home.hold"].exists)
    }
}
