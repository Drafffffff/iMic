import XCTest

/// Also run against an optimized Release simulator build. No DEBUG/demo/preview switches.
final class ShippingPracticeUITests: XCTestCase {
    func testShippingJourney() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        // Run on a fresh installation in this task's dedicated simulator.
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["home.hold"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["home.hold"].label, "HOLD TO START")
        XCTAssertFalse(app.buttons["onboarding.start"].exists)
        Thread.sleep(forTimeInterval: 1)
        app.buttons["home.hold"].press(forDuration: 2.2)
        let prompt = app.staticTexts["onboarding.prompt"]
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pull the string to send"), object: prompt)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 12), .completed)
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        let string = app.otherElements["home.string"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        string.press(forDuration: 0.08, thenDragTo: string.withOffset(CGVector(dx: 0, dy: 180)), withVelocity: 650, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        app.buttons["onboarding.later"].tap()
        XCTAssertTrue(app.buttons["onboarding.connectLater"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        app.buttons["onboarding.connectLater"].tap()
        XCTAssertTrue(app.buttons["home.hold"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onboarding.prompt"].exists)
        XCTAssertEqual(app.buttons["home.hold"].label, "LINK TO MAC")
    }
}
