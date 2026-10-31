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
            for state in ["onboarding-welcome", "onboarding-mac-download", "settings"] {
                let app = XCUIApplication()
                app.launchArguments = ["--ui-preview=" + state, "-AppleLanguages", "(" + language + ")"]
                app.launch()
                let marker = state == "settings" ? app.buttons[language == "en" ? "Close" : "关闭"].firstMatch : app.staticTexts["onboarding.title"]
                XCTAssertTrue(marker.waitForExistence(timeout: 20))
                capture(app, "scroll-" + state + "-" + language + "-top")
                for index in 1...(state == "settings" ? 5 : 1) {
                    app.scrollViews.firstMatch.swipeUp()
                    capture(app, "scroll-" + state + "-" + language + "-" + String(index))
                }
                if state == "onboarding-welcome" {
                    XCTAssertTrue(app.buttons[language == "en" ? "Get started" : "开始"].isHittable)
                }
                if state == "onboarding-mac-download" {
                    XCTAssertTrue(app.buttons[language == "en" ? "It's installed on my Mac. Continue" : "Mac 上装好了，继续"].isHittable)
                }
                app.terminate()
            }
        }
    }
}
