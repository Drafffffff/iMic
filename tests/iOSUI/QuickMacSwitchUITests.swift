import XCTest

final class QuickMacSwitchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(recording: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview=\(recording ? "devices-multi-recording" : "devices-multi")"]
        app.launch()
        XCTAssertTrue(app.buttons["quick-mac-switch"].waitForExistence(timeout: 15))
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openMenu(_ app: XCUIApplication) {
        app.buttons["quick-mac-switch"].tap()
        XCTAssertTrue(app.buttons["管理设备…"].waitForExistence(timeout: 5))
    }

    private func option(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "quick-mac-\(id)").firstMatch
    }

    private func target(_ name: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: app.buttons["quick-mac-switch"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
    }

    func testTwoTapsSwitchPairedMacWithoutLeavingHome() {
        let app = launch()
        openMenu(app) // click 1
        let studio = option("preview-studio", in: app)
        XCTAssertTrue(studio.exists)
        shot(app, "01-主页快速切换菜单")
        studio.tap() // click 2; no navigation or back action
        target("Mac Studio", in: app)
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].isHittable)
        XCTAssertFalse(app.navigationBars["连接电脑"].exists)
        shot(app, "02-两次点击切到Mac-Studio")
    }

    func testManageDevicesOpensExistingDevicePage() {
        let app = launch()
        openMenu(app)
        app.buttons["管理设备…"].tap()
        XCTAssertTrue(app.navigationBars["连接电脑"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["LINK"].exists)
        shot(app, "03-管理设备页")
    }

    func testNewMacOpensEmbeddedPairingWithoutAutoPairing() {
        let app = launch()
        openMenu(app)
        option("preview-mini", in: app).tap()
        XCTAssertTrue(app.navigationBars["连接电脑"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.textFields["六位配对码"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.textFields["六位配对码"].value as? String == "")
        shot(app, "04-新Mac需要手动输入配对码")
    }

    func testDevicePageAutomaticallyReturnsAfterSelectingPairedMac() {
        let app = launch()
        openMenu(app)
        app.buttons["管理设备…"].tap()
        XCTAssertTrue(app.navigationBars["连接电脑"].waitForExistence(timeout: 6))
        shot(app, "05-设备页自动返回前")
        let studio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mac Studio，切换到这台 Mac")).firstMatch
        XCTAssertTrue(studio.exists)
        studio.tap()
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout: 6))
        target("Mac Studio", in: app)
        XCTAssertFalse(app.navigationBars["连接电脑"].exists)
        shot(app, "06-设备页自动返回后")
    }

    func testRecordingSwitchRequiresConfirmationAndCancelKeepsTarget() {
        let app = launch(recording: true)
        openMenu(app)
        option("preview-studio", in: app).tap()
        XCTAssertTrue(app.staticTexts["取消当前语音并切换 Mac？"].waitForExistence(timeout: 6))
        shot(app, "07-录音中切换必须确认")
        app.buttons["继续当前语音"].tap()
        target("MacBook Pro", in: app)
        XCTAssertFalse(app.buttons["quick-mac-switch"].label.contains("Mac Studio"))
        shot(app, "08-取消切换保留原目标")
    }

    func testOfflineMacSwitchStaysOnHomeAndDisplaysChosenTarget() {
        let app = launch()
        openMenu(app)
        option("preview-office", in: app).tap()
        target("Office iMac", in: app)
        XCTAssertFalse(app.navigationBars["连接电脑"].exists)
        shot(app, "09-手动选择离线Mac")
    }

    func testChoosingCurrentConnectedMacDoesNotAskToCancelRecording() {
        let app = launch(recording: true)
        openMenu(app)
        option("preview-mac", in: app).tap()
        target("MacBook Pro", in: app)
        XCTAssertFalse(app.staticTexts["取消当前语音并切换 Mac？"].exists)
        shot(app, "10-当前Mac不重复切换")
    }
}
