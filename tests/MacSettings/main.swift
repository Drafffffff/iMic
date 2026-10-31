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
// Setup wizard launch policy: a relaunch in the middle of the wizard must come back to it.
func decide(key: Bool, completed: Int, progress: Bool, allowed: Bool) -> SetupLaunchPolicy.Decision {
    SetupLaunchPolicy.decide(keyPresent: key, completedVersion: completed, currentVersion: 1,
                             inProgress: progress, inputAllowed: allowed)
}
check(decide(key: false, completed: 0, progress: false, allowed: false) == .show, "New user starts in the wizard")
check(decide(key: false, completed: 1, progress: false, allowed: true) == .show, "A lost key reopens the wizard")
check(decide(key: true, completed: 0, progress: true, allowed: true) == .show,
      "Relaunch mid-wizard with a shell key and permissions granted must resume the wizard")
check(decide(key: true, completed: 0, progress: true, allowed: false) == .show, "Relaunch mid-wizard resumes")
check(decide(key: true, completed: 1, progress: true, allowed: true) == .skip, "A finished wizard stays closed")
check(decide(key: true, completed: 0, progress: false, allowed: true) == .skipAndMarkComplete,
      "Installs from before the wizard are not interrupted")
check(decide(key: true, completed: 0, progress: false, allowed: false) == .show, "Missing permission shows the wizard")
check(SetupStep.allCases.first == .key && SetupStep.allCases.last == .permissions,
      "Key comes first; permissions, which may force a relaunch, come last")
let progressDefaults = UserDefaults(suiteName: "iMic.setup-progress.\(UUID().uuidString)")!
check(SetupProgress.saved(progressDefaults) == nil, "No progress before the wizard opens")
SetupProgress.save(.permissions, progressDefaults)
check(SetupProgress.saved(progressDefaults) == .permissions, "Progress survives as the saved step")
SetupProgress.clear(progressDefaults)
check(SetupProgress.saved(progressDefaults) == nil, "Finishing clears progress")

let before = fileFingerprint()
let standardBefore = UserDefaults.standard.object(forKey: "polishProvider") as? String
let app = AppDelegate()
app.buildUI()
check(!app.window.isVisible, "Building the UI must not show a window")
MacPreferences.defaults.set(false, forKey: "showMainWindowOnLaunch")
app.presentLaunchWindows(needsSetup: false)
check(!app.window.isVisible, "Completed setup launches silently by default")
MacPreferences.defaults.set(true, forKey: "showMainWindowOnLaunch")
app.presentLaunchWindows(needsSetup: false)
check(app.window.isVisible, "Startup visibility preference is honored")
app.window.orderOut(nil)
MacPreferences.defaults.set(false, forKey: "showMainWindowOnLaunch")
app.launched = true
_ = app.applicationShouldHandleReopen(application, hasVisibleWindows: false)
check(app.window.isVisible, "Finder reopen still shows the main window")
app.window.orderOut(nil)
app.refreshUI()
check(!app.pairPanel.isHidden && !app.firstPairSteps.isHidden, "Never paired shows code and three steps")
try! app.store.trust(deviceID: UUID().uuidString, name: "Preview Phone", token: Data(repeating: 1, count: 32))
app.refreshUI()
check(app.pairPanel.isHidden && !app.waitingPanel.isHidden && app.pairedNames.stringValue == "Preview Phone", "Paired waiting makes the device primary")
app.pairNewPhone()
check(app.window.isVisible && !app.pairPanel.isHidden, "New pairing opens main and reveals code")
app.hidePairCode()
check(app.pairPanel.isHidden, "Pair code collapses without losing paired devices")
app.window.orderOut(nil)
let settings = app.settingsCoordinator!
check(!settings.loginCheck.isEnabled, "Preview/build paths cannot register login items")
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
check(app.menuPolishItem.state == .off, "Phone toggle updates the menu")
app.toggleMenuPolish()
check(app.deepseekCheck.state == .on && app.menuPolishItem.state == .on, "Menu toggle reuses the settings/phone entry")
let menuMode = app.menuModeItems.first { $0.title == PolishMode.agent.title }!
app.selectMenuMode(menuMode)
check(DeepSeekConfiguration.options.mode == .agent && DeepSeekConfiguration.options.output == .japanese && DeepSeekConfiguration.options.tone == .rant, "Menu changes mode only, keeping tone and language")
check(menuMode.state == .on && app.polishModeButtons.selectedSegment == 0, "Menu and settings checks agree")
let settingsIndex = app.statusMenu.items.firstIndex { $0.title == "设置…" }!
let websiteItem = app.statusMenu.items[settingsIndex + 1]
check(websiteItem.title == "iMic 官网与帮助…" && websiteItem.action == #selector(AppDelegate.openWebsite), "Website help follows settings in menu")
let websiteButton = allViews(advanced).compactMap { $0 as? NSButton }.first { $0.title == "iMic 官网 ↗" }
check(websiteButton?.action == #selector(AppDelegate.openWebsite), "Advanced help shares the menu action")
check(SetupLinks.website.absoluteString == "https://drafffffff.github.io/iMic/", "Shared website destination")
app.openWebsite() // Preview must return before opening the browser.
check(!app.statusMenu.items.contains { $0.title == "复制配对码" || $0.title == "设置向导…" }, "Low frequency operations leave the top-level menu")
app.showCloudFailure(.key, provider: .bailian, recognition: true)
check(app.issueLabel.stringValue.contains("百炼拒绝了 Key") && app.menuStatusItem.title.contains("百炼拒绝了 Key"), "ASR failures show reason in main and menu")
app.polishFallback = true
app.lastInsertSucceeded = false
app.refreshCloudFailure()
check(app.issueLabel.stringValue.contains("原文已保留"), "Failed delivery never claims text was inserted")
app.lastInsertSucceeded = true
app.refreshCloudFailure()
check(app.issueLabel.stringValue.contains("已输入原文"), "Polish fallback after input is explicit")
app.showCloudFailure(.network, provider: .bailian, recognition: true)
app.performIssueAction()
check(app.connectionRecovered && app.issueLabel.stringValue.contains("重新录音") && app.menuIssueAction.isHidden, "Retry checks connectivity and asks for a fresh recording")
app.refreshUI()
check(app.issueLabel.stringValue.contains("连接检查通过"), "Recovery message survives a UI refresh")
app.clearCloudFailure()
check(app.issueRow.isHidden && app.menuIssueAction.isHidden, "A new session clears stale failures")
settings.window.makeKeyAndOrderFront(nil)
let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: settings.window.windowNumber, context: nil,
    characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
check(settings.window.performKeyEquivalent(with: keyEvent) && tabs.selectedTabViewItemIndex == 2, "Command-3 selects iPhone using the real window keyboard handler")
let second = SettingsWindowCoordinator(app: app)
check((second.window.contentViewController as! NSTabViewController).selectedTabViewItemIndex == 2, "Last selected tab persists")
check(fileFingerprint() == before, "Previews and unchanged external credentials must not touch credentials.json")
check(UserDefaults.standard.object(forKey: "polishProvider") as? String == standardBefore, "Preview actions must not change real preferences")
print("Mac settings: five toolbar panes, external key override, verified save, rejected draft, close sheet, immediate provider, phone/menu sync, silent launch/reopen, waiting/pairing, failure actions and preview isolation passed")
