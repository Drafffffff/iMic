import XCTest

final class PolishUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openSettings(failure: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview=settings"] + (failure ? ["--debug-polish-save-failure"] : [])
        app.launch()
        // --ui-preview=settings already presents the production settings sheet.
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 20))
        return app
    }

    private func reveal(_ title: String, in app: XCUIApplication, up: Bool = true) -> XCUIElement {
        let button = app.buttons[title]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<9 {
            if button.exists && scroll.frame.insetBy(dx: 0, dy: 30).contains(button.frame) { return button }
            if up { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        XCTFail("找不到屏幕内的设置：\(title)")
        return button
    }

    private func select(_ title: String, in app: XCUIApplication, up: Bool = true) {
        let button = reveal(title, in: app, up: up)
        button.tap()
        let confirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND value == %@", "已选择"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 6), .completed)
        XCTAssertEqual(button.value as? String, "已选择")
    }

    func testModeToneLanguagePersistAndTerminalKeepsInactiveChoices() {
        let app = openSettings()
        XCTAssertFalse(app.staticTexts["润色强度"].exists)
        XCTAssertFalse(app.buttons["保持原语言"].exists)
        select("废话文学", in: app)
        select("萌系暴击", in: app)
        select("日文", in: app)
        select("终端命令", in: app, up: false)
        // SwiftUI may omit disabled offscreen grid cells from the AX tree.
        // Verify no enabled option is exposed; reselecting text mode below must
        // restore both concrete selections, rather than only showing defaults.
        for title in ["萌系暴击", "日文"] {
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@ AND enabled == true", title)).count, 0)
        }
        select("翻译腔", in: app, up: false)
        XCTAssertTrue(reveal("萌系暴击", in: app).isEnabled)
        XCTAssertEqual(app.buttons["萌系暴击"].value as? String, "已选择")
        XCTAssertEqual(reveal("日文", in: app).value as? String, "已选择")
        let summary = app.staticTexts["polish-summary"]
        XCTAssertTrue(summary.label.contains("翻译腔 · 萌系暴击 · 日文"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "模式、语气、语言已确认"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUnconfirmedSaveRestoresMacSelection() {
        let app = openSettings(failure: true)
        reveal("文言文", in: app).tap()
        XCTAssertTrue(app.staticTexts["更改未获确认，预览：Mac 未确认，本次选择未保存。"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["Agent 指令"].value as? String, "已选择")
        XCTAssertEqual(app.buttons["文言文"].value as? String, "未选择")
    }
}
