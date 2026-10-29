import AppKit
import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func wait(until condition: () -> Bool, timeout: TimeInterval = 3, line: Int = #line) {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end {
        if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    check(condition(), "Timed out waiting for a settings action at line \(line)")
}
func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
func fileFingerprint() -> Data? { try? Data(contentsOf: CredentialFile.defaultURL) }

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
application.activate(ignoringOtherApps: true)
let before = fileFingerprint()
let standardBefore = UserDefaults.standard.object(forKey: "polishProvider") as? String
let app = AppDelegate()
app.buildUI()
let settings = app.settingsCoordinator!
let tabs = settings.window.contentViewController as! NSTabViewController
check(tabs.tabStyle == .toolbar && tabs.tabViewItems.count == 5, "Five native toolbar tabs")
settings.select(.bailian)
settings.window.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let pane = tabs.tabViewItems[1].viewController!.view
let key = allViews(pane).compactMap { $0 as? SettingsField }.first { $0.id == "bailian.key" }!
check(!allViews(key).compactMap { $0 as? NSTextField }.filter(\.isEditable).contains { $0 is NSSecureTextField }, "External key starts read-only")
let override = allViews(pane).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "overrideBailianKey" }!
override.performClick(nil)
check(allViews(key).compactMap { $0 as? NSSecureTextField }.first!.isEditable, "Explicit override allows editing")
let initialBackend = app.key.stringValue
key.value = "sk-valid-preview-new-key"
check(key.dirty && app.key.stringValue == initialBackend, "A draft must not alter running credentials")
var done = false
key.save { check($0, "Valid preview key saves"); done = true }
check(!key.saveButton.isEnabled && key.feedback.stringValue == "验证中…", "Validation is visibly pending")
wait(until: { done })
check(!key.dirty && app.key.stringValue == "sk-valid-preview-new-key", "Only a verified save adopts the draft")
key.value = "sk-bad-preview-key"
done = false
key.save { check(!$0, "Rejected key must not save"); done = true }
wait(until: { done })
check(key.feedback.stringValue.contains("百炼拒绝"), "Rejection is actionable inline")
check(app.key.stringValue == "sk-valid-preview-new-key", "Rejected draft leaves running credential intact")
settings.window.performClose(nil)
check(settings.window.attachedSheet != nil, "Dirty drafts require a close sheet")
print("Checking close / cancel")
allViews(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "取消" }!.performClick(nil)
wait(until: { settings.window.attachedSheet == nil })
check(settings.window.isVisible && key.dirty, "Cancel retains the draft")
settings.window.performClose(nil)
print("Checking close / discard")
allViews(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "放弃" }!.performClick(nil)
wait(until: { !settings.window.isVisible && !key.dirty })
check(!settings.window.isVisible && !key.dirty, "Discard closes and clears only drafts")
app.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: .deepseek)!)
app.polishProviderPicker.sendAction(app.polishProviderPicker.action!, to: app.polishProviderPicker.target)
check(DeepSeekConfiguration.provider == .deepseek, "Provider switches immediately without a key")
settings.select(.advanced)
let advanced = tabs.tabViewItems[4].viewController!.view
check(allViews(advanced).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("此来源缺少有效 Key") }, "Missing key warning stays visible")
app.applyPolishPreferences(LinkPolishPreferences(enabled: false, options: PolishOptions(output: .japanese, mode: .terminal, tone: .rant)), confirmingSave: true)
check(app.deepseekCheck.state == .off && app.polishFields?.isHidden == true, "Phone preference entry updates the Mac switch")
check(app.polishModeButtons.selectedSegment == PolishMode.allCases.firstIndex(of: .terminal), "Phone mode reaches the same segmented control")
check(!app.polishToneButtons.isEnabled && !app.polishOutputPicker.isEnabled, "Command mode keeps its constraints")
settings.select(.iphone)
let second = SettingsWindowCoordinator(app: app)
check((second.window.contentViewController as! NSTabViewController).selectedTabViewItemIndex == 2, "Last selected tab persists")
check(fileFingerprint() == before, "Previews and unchanged external credentials must not touch credentials.json")
check(UserDefaults.standard.object(forKey: "polishProvider") as? String == standardBefore, "Preview actions must not change real preferences")
print("Mac settings: five toolbar panes, external key override, verified save, rejected draft, close sheet, immediate provider, phone sync and preview isolation passed")
