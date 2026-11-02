import XCTest
import UIKit

/// Geometry and rendered-color regressions, exercised on both task-owned screen sizes.
final class OnboardingVisualUITests: XCTestCase {
    func testEveryHomeLessonKeepsOrangeBarAndHUDPanelClear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for step in ["welcome", "hold", "release", "send", "more", "delete", "cursor", "clear", "cancel", "ready", "complete"] {
            app.launchArguments = ["--ui-preview=onboarding-" + step, "-AppleLanguages", "(en)"]
            app.launch()
            let bar = app.buttons["home.hold"]
            XCTAssertTrue(bar.waitForExistence(timeout: 20), step)
            XCTAssertFalse(app.buttons["onboarding.start"].exists, step)
            XCTAssertTrue(bar.isHittable, step)
            XCTAssertTrue(app.frame.contains(bar.frame), step)
            // Account only for CGFloat round-off (e.g. 43.99999999999994pt).
            let hud = app.buttons[step == "welcome" ? "onboarding.existing" : "onboarding.skip"]
            XCTAssertGreaterThanOrEqual(hud.frame.height + 0.001, 44, step)
            if step == "welcome" { XCTAssertEqual(bar.label, "HOLD TO START") }
            // Allow the compositor to finish its first raster; check actual pixels, not a color flag.
            let orange = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.orangeFraction(app, bar: bar.frame) > 0.20
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [orange], timeout: 10), .completed, step)
            if step == "more" {
                let panel = app.otherElements["onboarding.morePanel"]
                XCTAssertTrue(panel.exists)
                XCTAssertFalse(panel.frame.intersects(bar.frame))
                XCTAssertFalse(panel.frame.intersects(app.otherElements["home.string"].frame))
                for id in ["onboarding.more", "onboarding.try.cursor", "onboarding.try.clear", "onboarding.try.cancel", "onboarding.later"] {
                    XCTAssertTrue(app.buttons[id].isHittable, id)
                    XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height + 0.001, 44, id)
                    XCTAssertTrue(panel.frame.contains(app.buttons[id].frame), id)
                }
            }
            app.terminate()
        }
    }
    private func orangeFraction(_ app: XCUIApplication, bar: CGRect) -> Double {
        guard let screen = app.screenshot().image.cgImage else { return 0 }
        let scale = CGFloat(screen.width) / app.frame.width
        let rect = CGRect(x: bar.minX * scale, y: bar.minY * scale, width: bar.width * scale, height: bar.height * scale).insetBy(dx: 6 * scale, dy: 6 * scale)
        guard let crop = screen.cropping(to: rect) else { return 0 }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let fraction: Double = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = bytes.bindMemory(to: UInt8.self)
            var orange = 0, total = 0
            for index in stride(from: 0, to: width * height * 4, by: 16) {
                let r = Int(data[index]), g = Int(data[index + 1]), b = Int(data[index + 2])
                total += 1
                if r > 100 && g > 30 && g < 200 && b < 80 && r * 10 > g * 13 { orange += 1 }
            }
            return Double(orange) / Double(max(1, total))
        }
        return fraction
    }
}
