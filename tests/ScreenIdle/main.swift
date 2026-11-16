import Foundation

@MainActor
@main
enum ScreenIdleChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func wait(_ duration: Double) async { try? await Task.sleep(for: .seconds(duration)) }
    static func settle(_ controller: IdleScreenDimming, at state: IdleScreenDimming.State) async {
        let deadline = Date().addingTimeInterval(1)
        while controller.state != state, Date() < deadline { await wait(0.02) }
        check(controller.state == state, "Transition must reach \(state)")
    }

    static func main() async {
        var shade: Double = 0
        var writes: [Double] = []
        let controller = IdleScreenDimming(idleDelay: 0.18, fadeDuration: 0.08, restoreDuration: 0.04,
            write: { shade = $0; writes.append($0) })
        controller.setActive(true)
        await wait(0.07)
        check(writes.isEmpty, "No early dimming")
        controller.noteActivity()
        await wait(0.13)
        check(writes.isEmpty, "Fresh interaction must renew the idle deadline")
        await settle(controller, at: .dimmed)
        check(shade == 0.75, "Sleep dims only the app's shade")
        check(zip(writes,writes.dropFirst()).allSatisfy { $0 <= $1 }, "Sleep fade must be monotonic")
        let settledWrites = writes.count
        await wait(0.10)
        check(writes.count == settledWrites, "Sleeping shade produces zero callbacks")

        controller.setTouching(true)
        check(shade == 0, "Touch-down must clear the shade synchronously before control interaction")
        for _ in 0..<5 { await wait(0.01); controller.setTouching(true) }
        await settle(controller, at: .blocked)
        check(shade == 0, "Repeated long-press/move events must finish restoring")
        await wait(0.28)
        check(shade == 0, "A held gesture must never dim")
        controller.setTouching(false)
        controller.setBusy(true)
        await wait(0.32)
        check(shade == 0, "Recording/recognition must stay awake")
        controller.setBusy(false)
        await settle(controller, at: .dimmed)
        controller.setActive(false)
        check(shade == 0, "Leaving for Control Center, lock screen or another app removes the shade immediately")
        let inactiveWrites = writes.count
        await wait(0.25)
        check(writes.count == inactiveWrites, "Inactive app has no delayed writes")

        // The controller has no system-brightness getter/setter or saved brightness.
        // Returning from a manual adjustment starts visibly awake, every time.
        for _ in 0..<3 {
            controller.setActive(true)
            check(shade == 0, "Foreground/manual-brightness return must start awake")
            await settle(controller, at: .dimmed)
            controller.noteActivity()
            await settle(controller, at: .armed)
            check(shade == 0, "Repeated sleep/wake cycles never accumulate darkness")
            controller.setActive(false)
        }

        controller.setActive(true)
        await wait(0.22) // Interrupt a partially completed fade.
        controller.setActive(false)
        check(shade == 0, "Backgrounding mid-fade immediately removes the app shade")
        await wait(0.12)
        check(shade == 0, "Cancelled fade cannot write a stale dark frame")
        controller.setActive(true)
        await settle(controller, at: .dimmed)
        controller.noteActivity()
        await wait(0.02) // Interrupt restoration itself.
        controller.setActive(false)
        check(shade == 0, "Losing focus during wake-up also clears the shade synchronously")
        await wait(0.12)
        check(shade == 0, "No late wake-up callbacks after detach")
        print("Screen idle: app-only shade, renewed deadline, zero sleep callbacks, first-touch/long-press wake, busy protection, repeated wake and lifecycle cancellation passed")
    }
}
