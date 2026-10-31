import XCTest

/// Drives real gestures for landing-page demo recordings. Not part of the regular suite:
/// every test is skipped unless IMIC_DEMO_SCENE is set (scripts/site-demo.sh does that and
/// records the simulator screen while it runs). The app runs in preview mode with
/// `--demo-script`, so nothing connects to a Mac, records audio or sends anything.
final class DemoCaptureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scene: String { ProcessInfo.processInfo.environment["IMIC_DEMO_SCENE"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(scene.isEmpty, "Demo capture runs only from scripts/site-demo.sh")
        app = XCUIApplication()
        app.launchArguments = ["--ui-preview=idle", "--demo-script=\(scene)"]
        app.launch()
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout: 10))
        pause(1.2)   // Let the idle glow settle and the recorder catch up.
    }

    func testScene() throws {
        switch scene {
        case "hero":
            hold(2.6); pause(3.3)   // polishing, then the result is read before it fires
            fire(); pause(1.6)
        case "hold":
            hold(2.6); pause(2.6)
        case "string":
            hold(2.2); pause(1.0)
            swipe(-130); pause(0.25); swipe(90); pause(0.35)
            pullUpDelete(1.0); pause(0.4)
            clearToTop(); pause(0.9)
            hold(0.9); pause(1.2)
            fire(); pause(1.3)
        case "live":
            hold(2.8); pause(2.4)
        case "polish":
            hold(2.8); pause(3.6)
        case "sound":
            hold(1.4); pause(1.1)
            pullUpDelete(0.4); pause(0.3)
            clearToTop(); pause(0.9)
            hold(0.9); pause(1.1)
            fire(); pause(1.2)
        default:
            XCTFail("Unknown demo scene \(scene)")
        }
    }

    // MARK: - Gestures (points in a 402×874 iPhone 17 Pro screen)

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    private var stringCenter: CGPoint { CGPoint(x: 201, y: 470) }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func hold(_ seconds: TimeInterval) {
        let bar = app.buttons["HOLD TO SPEAK"].exists ? app.buttons["HOLD TO SPEAK"] : nil
        let target = bar?.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)) ?? point(170, 774)
        target.press(forDuration: seconds)
    }

    /// Pull the string down and let go: the loaded text fires and Return is sent.
    private func fire() {
        let start = point(stringCenter.x - 30, stringCenter.y - 10)
        start.press(forDuration: 0.08, thenDragTo: point(stringCenter.x - 30, stringCenter.y + 190),
                    withVelocity: 900, thenHoldForDuration: 0.12)
    }

    /// Pull up and hold: characters delete repeatedly, faster the longer it is held.
    private func pullUpDelete(_ seconds: TimeInterval) {
        let start = point(stringCenter.x + 20, stringCenter.y + 10)
        start.press(forDuration: 0.08, thenDragTo: point(stringCenter.x + 20, stringCenter.y - 120),
                    withVelocity: 500, thenHoldForDuration: seconds)
    }

    private func swipe(_ dx: CGFloat) {
        let start = point(stringCenter.x - dx / 2, stringCenter.y)
        start.press(forDuration: 0.06, thenDragTo: point(stringCenter.x + dx / 2, stringCenter.y + 4),
                    withVelocity: 260, thenHoldForDuration: 0.1)
    }

    /// Pull all the way to the top to clear the current input.
    private func clearToTop() {
        let start = point(stringCenter.x, stringCenter.y + 10)
        start.press(forDuration: 0.08, thenDragTo: point(stringCenter.x, 56),
                    withVelocity: 1100, thenHoldForDuration: 0.25)
    }
}
