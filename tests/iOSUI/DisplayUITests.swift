import XCTest

final class DisplayUITests:XCTestCase{
    override func setUp(){continueAfterFailure=false}

    private func launch(_ mode:String="idle")->XCUIApplication{
        let app=XCUIApplication()
        app.launchArguments=["--ui-preview=\(mode)"]
        app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout:15))
        return app
    }

    private func record(_ app:XCUIApplication,_ name:String){
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
    }

    func testNativeSettingsAndDisplayModes(){
        let app=launch()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout:8))
        let crt=app.buttons["荧光 CRT"]
        for _ in 0..<4{
            if crt.isHittable && app.scrollViews.firstMatch.frame.insetBy(dx:0,dy:20).contains(crt.frame){break}
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(crt.isHittable)
        record(app,"Display controls before tap")
        for title in ["清晰","荧光","荧光 CRT"]{
            let button=app.buttons[title]
            button.tap()
            let confirmed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","已选择"),object:button)
            XCTAssertEqual(XCTWaiter.wait(for:[confirmed],timeout:4),.completed,"Display selection must remain confirmed locally")
        }
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout:8))
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Unified CRT / native controls";image.lifetime = .keepAlways;add(image)
    }

    func testRecordingTouchPassesThroughMetalAndResultRemainsUsable(){
        let app=launch()
        let hold=app.buttons["HOLD TO SPEAK"]
        XCTAssertTrue(hold.waitForExistence(timeout:8))
        hold.press(forDuration:0.8)
        // Preview deliberately has no microphone samples. The discard notice proves
        // that the native press/release crossed the Metal visual layer.
        XCTAssertTrue(app.staticTexts["录音太短，再说一次"].firstMatch.waitForExistence(timeout:8))
        app.terminate()
        let resultApp=launch("result")
        let result=resultApp.buttons["查看识别结果"]
        XCTAssertTrue(result.waitForExistence(timeout:8));XCTAssertTrue(result.isHittable)
        record(resultApp,"Result entry")
        result.tap()
        XCTAssertTrue(resultApp.buttons["关闭结果"].waitForExistence(timeout:8))
        resultApp.buttons["关闭结果"].tap()
        XCTAssertTrue(resultApp.buttons["设置"].waitForExistence(timeout:8))
    }

    func testDeviceNavigationReturnsToLiveDisplay(){
        let app=launch()
        let device=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@","连接电脑，")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout:8));device.tap()
        XCTAssertTrue(app.navigationBars["连接电脑"].waitForExistence(timeout:8))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout:8))
    }

    func testUpwardDragToTopClearsCurrentInput(){
        let app=launch("result")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","已填入 Craft")).firstMatch.waitForExistence(timeout:8))
        let string=app.otherElements["弦控制"]
        XCTAssertTrue(string.waitForExistence(timeout:8))
        let start=string.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        let top=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:app.frame.midX,dy:72))
        start.press(forDuration:0.1,thenDragTo:top,withVelocity:XCUIGestureVelocity(rawValue:280),thenHoldForDuration:0.3)
        record(app,"After upward clear gesture")
        XCTAssertTrue(app.staticTexts["按住底部横条开始说话"].waitForExistence(timeout:8),
                      "Entering the top drop zone must clear the preview result and return to idle")
        XCTAssertFalse(app.buttons["查看识别结果"].isHittable)
    }

    func testIdleScreenFirstTouchStillOpensSettings(){
        let app=launch()
        // Exercise the production 60s deadline and 2s fade, without a shortened DEBUG path.
        Thread.sleep(forTimeInterval:63)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout:8),"The first wake-up touch must also reach the original button")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:8))
    }
}
