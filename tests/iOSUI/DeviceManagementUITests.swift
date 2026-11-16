import XCTest

final class DeviceManagementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(recording: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview=devices-manage" + (recording ? "-recording" : ""), "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Connect to a computer"].waitForExistence(timeout:20))
        return app
    }
    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let button = app.buttons[id]
        for _ in 0..<4 {
            if button.isHittable { return button }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(button.isHittable, id)
        return button
    }
    private func cancelDialog(_ app: XCUIApplication) {
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.20)).tap() }
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testOfflineDeviceCanBeForgottenOrCanceledWithoutChangingCurrentMac() {
        let app = launch()
        let forget = button(app,"devices.forget.preview-office")
        XCTAssertGreaterThanOrEqual(forget.frame.width,44)
        XCTAssertGreaterThanOrEqual(forget.frame.height,44)
        XCTAssertEqual(forget.label,"Forget Office iMac, paired Mac")
        forget.tap()
        XCTAssertTrue(app.buttons["Forget Mac"].waitForExistence(timeout:5))
        shot(app,"Forget offline device confirmation")
        cancelDialog(app)
        XCTAssertTrue(app.buttons["devices.forget.preview-office"].exists)
        button(app,"devices.forget.preview-office").tap()
        app.buttons["Forget Mac"].tap()
        XCTAssertFalse(app.buttons["devices.forget.preview-office"].waitForExistence(timeout:1))
        XCTAssertTrue(app.buttons["devices.select.preview-mac"].label.contains("Current target"))
        shot(app,"Offline device removed, current Mac retained")
    }
    func testNearbyForgottenMacRemainsDiscoverableButRequiresPairing() {
        let app = launch()
        button(app,"devices.forget.preview-studio").tap()
        app.buttons["Forget Mac"].tap()
        XCTAssertFalse(app.buttons["devices.forget.preview-studio"].waitForExistence(timeout:1))
        XCTAssertTrue(app.buttons["devices.select.preview-studio"].label.contains("Pairing required"))
        XCTAssertTrue(app.buttons["devices.select.preview-mac"].label.contains("Current target"))
        shot(app,"Nearby device now requires explicit pairing")
    }
    func testForgettingCurrentMacLeavesSelectionEmpty() {
        let app = launch()
        button(app,"devices.forget.preview-mac").tap()
        app.buttons["Forget Mac"].tap()
        XCTAssertTrue(app.staticTexts["No Mac selected"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["devices.forget.preview-mac"].exists)
        XCTAssertTrue(app.buttons["devices.forget.preview-studio"].exists)
        shot(app,"Current device forgotten without switching to another Mac")
    }
    func testActiveVoiceRequiresExplicitCancelAndForget() {
        let app = launch(recording:true)
        button(app,"devices.forget.preview-mac").tap()
        XCTAssertTrue(app.buttons["Cancel session and forget"].waitForExistence(timeout:5))
        shot(app,"Active voice deletion protection")
        cancelDialog(app)
        XCTAssertTrue(app.buttons["devices.forget.preview-mac"].exists)
        button(app,"devices.forget.preview-mac").tap()
        app.buttons["Cancel session and forget"].tap()
        XCTAssertTrue(app.staticTexts["No Mac selected"].waitForExistence(timeout:5))
        shot(app,"Voice canceled before current pairing deletion")
    }
    func testCurrentUnpairedTargetCanBeExplicitlyPairedAgain() {
        let app=XCUIApplication()
        app.launchArguments=["--ui-preview=devices-manage-repair","-AppleLanguages","(en)"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Connect to a computer"].waitForExistence(timeout:20))
        let target=button(app,"devices.select.preview-mac")
        XCTAssertTrue(target.label.contains("Pairing required"))
        target.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout:5))
        shot(app,"Current unpaired target opens explicit pairing")
    }

    func testChineseOfflineDeletionIsLocalizedAndRequiresConfirmation() {
        let app=XCUIApplication()
        app.launchArguments=["--ui-preview=devices-manage","-AppleLanguages","(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.navigationBars["连接电脑"].waitForExistence(timeout:20))
        let forget=button(app,"devices.forget.preview-office")
        XCTAssertEqual(forget.label,"删除已配对设备 Office iMac")
        shot(app,"Chinese device management with deletion actions")
        forget.tap()
        XCTAssertTrue(app.buttons["删除配对设备"].waitForExistence(timeout:5))
        shot(app,"Chinese offline device deletion confirmation")
        app.buttons["删除配对设备"].tap()
        XCTAssertFalse(app.buttons["devices.forget.preview-office"].waitForExistence(timeout:1))
    }

}
