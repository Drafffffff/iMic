import AppKit
import ApplicationServices

enum CheckFailure: Error { case failed }

func check() throws {
let previous = NSWorkspace.shared.frontmostApplication
let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
fixture.arguments = [mode]
try fixture.run()
defer {
    fixture.terminate()
    fixture.waitUntilExit()
    previous?.activate(options: [.activateIgnoringOtherApps])
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func focusedValue() -> String? {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(fixture.processIdentifier),
        kAXFocusedUIElementAttribute as CFString, &focused) == .success,
        let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}
let readyDeadline = Date().addingTimeInterval(8)
while Date() < readyDeadline {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
       focusedValue()?.isEmpty == false { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
      let original = focusedValue(), !original.isEmpty else {
    fputs("Fixture is not accessible; no input was sent.\n", stderr)
    throw CheckFailure.failed
}
var result: Bool?
InputTarget.clearFocusedText(pid: fixture.processIdentifier) { result = $0 }
let deadline = Date().addingTimeInterval(4)
while result == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
let actual = focusedValue()
let passed = mode == "readonly" ? (result == false && actual == original) : (result == true && actual == "")
guard passed else {
    fputs("Clear integration failed: mode=\(mode), applied=\(String(describing: result)), empty=\(actual?.isEmpty == true)\n", stderr)
    throw CheckFailure.failed
}
print("Clear integration passed: \(mode)")

}
do { try check() } catch { exit(1) }
