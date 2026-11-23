import XCTest

/// Uses only the explicitly selected, owned simulator. No permissions or live connection.
final class EnglishUIReviewTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testScrollableEnglishAndChineseGuidance() {
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-preview=settings", "-AppleLanguages", "(" + language + ")"]
            app.launch()
            XCTAssertTrue(app.buttons[language == "en" ? "Close" : "关闭"].firstMatch.waitForExistence(timeout: 20))
            capture(app, "scroll-settings-" + language + "-top")
            for index in 1...5 {
                app.scrollViews.firstMatch.swipeUp()
                capture(app, "scroll-settings-" + language + "-" + String(index))
            }
            app.terminate()
        }
    }

    /// No tutorial: a first run with no Mac shows the website address and the download sheet.
    func testFirstRunPointsToWebsite() {
        for language in ["en", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-preview=first-run", "-AppleLanguages", "(" + language + ")"]
            app.launch()
            let entry = app.buttons["home.getMac"]
            XCTAssertTrue(entry.waitForExistence(timeout: 20))
            XCTAssertTrue(entry.isHittable)
            capture(app, "first-run-" + language)
            entry.tap()
            XCTAssertTrue(app.staticTexts["download.address"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["download.address"].label, "drafffffff.github.io/iMic")
            capture(app, "first-run-download-" + language)
            app.terminate()
        }
    }
}
