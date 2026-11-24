import AppKit

// Real windows in a real NSApplication: the Dock icon follows open VoxChord windows.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}
// Pump the event loop the way NSApplication.run does, including the per-pass window update.
func settle() {
    let end = Date().addingTimeInterval(0.4)
    while Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

func makeWindow(_ style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                          styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

let main = makeWindow()
let history = makeWindow()
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                    styleMask: [.titled], backing: .buffered, defer: false)
let borderless = makeWindow([.borderless])

check(DockPresence.wanted([main, history]) == .accessory, "no open window -> menu bar only")
panel.orderFront(nil); borderless.orderFront(nil)
check(DockPresence.wanted([main, panel, borderless]) == .accessory, "panels and borderless overlays do not count")
panel.orderOut(nil); borderless.orderOut(nil)

DockPresence.shared = DockPresence(app: app)
check(app.activationPolicy() == .accessory, "starts without Dock icon")

DockPresence.willShowWindow()
main.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
settle()
check(app.activationPolicy() == .regular, "opening the main window shows the Dock icon")

history.makeKeyAndOrderFront(nil); settle()
main.close(); settle()
check(app.activationPolicy() == .regular, "another window still open keeps the Dock icon")

history.miniaturize(nil); settle()
check(history.isMiniaturized, "history window minimized")
check(app.activationPolicy() == .regular, "a minimized window keeps the Dock icon")
history.deminiaturize(nil); settle()

history.close(); settle()
check(app.activationPolicy() == .accessory, "closing the last window hides the Dock icon")

main.makeKeyAndOrderFront(nil); settle()
check(app.activationPolicy() == .regular, "a window shown without the hint still brings the Dock icon")
main.orderOut(nil); DockPresence.shared?.update(); settle()
check(app.activationPolicy() == .accessory, "hiding the window from the menu bar hides the Dock icon")

print(failures == 0 ? "dock presence: all passed" : "dock presence: \(failures) failed")
exit(failures == 0 ? 0 : 1)
