import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 20))
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func tap(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title].firstMatch
        for _ in 0..<4 {
            if button.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let target = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<3 {
            if target.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(target.isHittable)
        return target
    }
    func testOfflinePracticeRecognizesAllGesturesWithoutPermissionsOrTransport() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["--debug-reset-onboarding", "--debug-onboarding-audit"]
        app.launch()
        XCTAssertTrue(app.buttons["开始"].waitForExistence(timeout: 20))
        shot(app, "01 Welcome fresh install")
        tap("开始", in: app)
        tap("先看看怎么用", in: app)
        let hold = element("practice.hold", in: app)
        hold.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["practice.passed"].waitForExistence(timeout: 5))
        shot(app, "Practice 1 hold completed")
        tap("下一张", in: app)
        let cancel = element("practice.hold", in: app)
        let start = cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(app.staticTexts["practice.passed"].waitForExistence(timeout: 5))
        shot(app, "Practice 2 cancel completed")
        tap("下一张", in: app)
        var string = element("practice.string", in: app)
        var center = string.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.15, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 90)))
        XCTAssertTrue(app.staticTexts["practice.passed"].waitForExistence(timeout: 5))
        shot(app, "Practice 3 snap return completed")
        tap("下一张", in: app)
        string = element("practice.string", in: app)
        center = string.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.15, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -70)))
        center.press(forDuration: 0.15, thenDragTo: center.withOffset(CGVector(dx: 80, dy: 0)))
        XCTAssertTrue(app.staticTexts["practice.passed"].waitForExistence(timeout: 5))
        shot(app, "Practice 4 delete and cursor completed")
        tap("下一张", in: app)
        string = element("practice.string", in: app)
        center = string.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 70))
        center.press(forDuration: 0.15, thenDragTo: top)
        XCTAssertTrue(app.staticTexts["practice.passed"].waitForExistence(timeout: 5))
        shot(app, "Practice 5 clear completed")
        tap("下一张", in: app)
        shot(app, "Practice complete")
        tap("完成练习", in: app)
        XCTAssertTrue(app.buttons["已经装好了"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["已经装好了"].waitForExistence(timeout: 5))
        tap("检查练习隔离", in: app)
        let audit = app.staticTexts["onboarding.audit"]
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        XCTAssertEqual(audit.label, "link=0 send=0 mic=undetermined speech=undetermined tutorial=1")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        shot(app, "Returned to Mac without network audio or permission")
    }
    func testDownloadSharingAndClipboard() {
        let app = launch(["--ui-preview=onboarding-mac", "--debug-onboarding-audit"])
        tap("还没有，发送到我的 Mac", in: app)
        XCTAssertTrue(app.buttons["共享链接"].exists)
        tap("共享链接", in: app)
        shot(app, "System share sheet")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        else { app.swipeDown() }
        tap("复制链接", in: app)
        XCTAssertTrue(app.staticTexts["download.copied"].waitForExistence(timeout: 5))
        tap("检查练习隔离", in: app)
        XCTAssertTrue(app.staticTexts["https://drafffffff.github.io/iMic/?from=ios#download"].exists)
        shot(app, "Download and copied URL")
    }
    func testRestoresMacStepAfterRelaunch() {
        let app = launch(["--debug-reset-onboarding"])
        tap("开始", in: app)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["已经装好了"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["开始"].exists)
        shot(app, "Restored Mac step")
    }
    func testDeniedNetworkExplainsSettings() {
        let app = launch(["--ui-preview=onboarding-link-denied"])
        XCTAssertTrue(app.staticTexts["LOCAL NETWORK OFF"].exists)
        XCTAssertTrue(app.buttons["打开设置"].exists)
        shot(app, "Local network denied")
    }
    func testTimeoutKeepsTroubleshootingVisible() {
        let app = launch(["--ui-preview=onboarding-search-timeout"])
        XCTAssertTrue(app.staticTexts["2. iPhone 和 Mac 是否在同一个 Wi-Fi？"].exists)
        shot(app, "Timeout troubleshooting")
    }
    func testExistingPairedPreviewSkipsOnboarding() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview=idle"]; app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["onboarding.title"].exists)
        shot(app, "Existing paired home")
    }
}
