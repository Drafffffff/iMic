import XCTest
import UIKit

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

    private func barLuminance(in app:XCUIApplication)->Double{
        let bar=app.buttons["HOLD TO SPEAK"].frame
        let screenshot=app.screenshot().image.cgImage!
        let scale=CGFloat(screenshot.width)/app.frame.width
        let region=CGRect(x:bar.midX-8,y:bar.minY+8,width:16,height:5)
            .applying(CGAffineTransform(scaleX:scale,y:scale))
        let crop=screenshot.cropping(to:region.integral)!
        var pixel=[UInt8](repeating:0,count:4)
        pixel.withUnsafeMutableBytes{bytes in
            let context=CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(crop,in:CGRect(x:0,y:0,width:1,height:1))
        }
        return Double(Int(pixel[0])+Int(pixel[1])+Int(pixel[2]))/3
    }

    func testIdleScreenRestoresOnFirstRecordingHold(){
        let app=launch()
        let awake=barLuminance(in:app)
        XCTAssertGreaterThan(awake,30)
        // Exercise the production 60s deadline and 2s fade, without a shortened DEBUG path.
        Thread.sleep(forTimeInterval:63)
        let asleep=barLuminance(in:app)
        XCTAssertLessThan(asleep,awake*0.7,"The app itself must visibly enter sleep")
        record(app,"App-local sleep shade")
        app.buttons["HOLD TO SPEAK"].press(forDuration:0.8)
        XCTAssertTrue(app.staticTexts["录音太短，再说一次"].firstMatch.waitForExistence(timeout:8),
                      "The first wake-up hold must also reach the recording control")
        XCTAssertGreaterThan(barLuminance(in:app),awake*0.85,"The first hold must restore visible app brightness")
        record(app,"First hold restores app brightness")
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout:8))
        app.buttons["关闭"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:8))
        app.activate()
        XCTAssertTrue(app.buttons["HOLD TO SPEAK"].waitForExistence(timeout:8))
        XCTAssertGreaterThan(barLuminance(in:app),awake*0.85,"Returning to the app must start awake")
    }
}
