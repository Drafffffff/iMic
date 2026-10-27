import Foundation

@MainActor
@main
enum ScreenIdleChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func wait(_ duration: Double) async { try? await Task.sleep(for: .seconds(duration)) }

    static func main() async {
        var brightness = 0.8
        var writes: [Double] = []
        let controller = IdleScreenDimming(idleDelay: 0.18, fadeDuration: 0.08, restoreDuration: 0.04,
            read: { brightness }, write: { brightness = $0; writes.append($0) })
        controller.setActive(true)
        await wait(0.07)
        check(writes.isEmpty, "No early dimming")
        controller.noteActivity()
        await wait(0.13)
        check(writes.isEmpty, "Fresh interaction must renew the idle deadline")
        await wait(0.20)
        check(controller.state == .dimmed && abs(brightness - 0.2) < 0.001, "Fade must settle at one quarter brightness")
        check(zip(writes,writes.dropFirst()).allSatisfy { $0 >= $1 }, "Dimming must be monotonic")
        let settled = writes.count
        await wait(0.10)
        check(writes.count == settled, "Dimmed standby must produce zero brightness callbacks")
        brightness += 0.006 // Auto-brightness drift while dimmed, as observed on device.
        controller.brightnessChanged()
        controller.setTouching(true)
        await wait(0.09)
        check(abs(brightness - 0.8) < 0.001, "Auto-brightness drift must not stop the first touch restoring")
        await wait(0.28)
        check(controller.state == .blocked && brightness == 0.8, "Held gestures must not dim")
        controller.setTouching(false)
        controller.setBusy(true)
        await wait(0.32)
        check(brightness == 0.8, "Recording/recognition must not dim")
        controller.setBusy(false)
        await wait(0.32)
        check(abs(brightness - 0.2) < 0.001, "Completed work must begin a fresh idle period")
        controller.setActive(false)
        check(abs(brightness - 0.8) < 0.001, "Leaving app must immediately restore brightness")
        let inactiveWrites = writes.count
        await wait(0.25)
        check(writes.count == inactiveWrites, "Inactive app must have no delayed writes")
        controller.setActive(true)
        await wait(0.22) // Interrupt a partially completed fade.
        controller.setActive(false)
        check(abs(brightness - 0.8) < 0.001, "Backgrounding during fade must restore, too")
        await wait(0.12)
        check(brightness == 0.8, "A cancelled fade must never write again")
        controller.setActive(true)
        await wait(0.32)
        brightness = 0.55 // A manual brightness change takes ownership away from the app.
        controller.brightnessChanged()
        controller.setActive(false)
        check(brightness == 0.55, "Never restore over the user's new brightness preference")
        brightness = 0.01
        controller.setActive(true)
        await wait(0.32)
        check(brightness == 0.01, "Never increase an already dark screen")
        controller.setActive(false)
        print("Screen idle: renewed deadline, monotonic dimming, zero idle writes, touch/hold, busy work, foreground/background and manual brightness ownership passed")
    }
}
