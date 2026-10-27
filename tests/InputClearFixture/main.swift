import AppKit

// An owned, disposable field for cross-process AX/keyboard integration checks.
final class FixtureTextView: NSTextView {
    var ignoreValue = false
    override func setAccessibilityValue(_ value: Any?) {
        if !ignoreValue { super.setAccessibilityValue(value) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let commands = NSMenu(title: "Edit")
commands.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
edit.submenu = commands
menu.addItem(edit)
app.mainMenu = menu
let mode = CommandLine.arguments.dropFirst().first ?? "direct"
let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 520, height: 240),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "iMic 清空回归测试 · 临时输入框"
let field = FixtureTextView(frame: NSRect(x: 20, y: 20, width: 480, height: 200))
field.font = .systemFont(ofSize: 18)
field.string = "这是回归测试的临时内容 👨‍👩‍👧‍👦，与用户文档无关。"
field.ignoreValue = mode == "ignored-value"
field.isEditable = mode != "readonly"
field.isSelectable = true
window.contentView?.addSubview(field)
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)
app.activate(ignoringOtherApps: true)
app.run()
