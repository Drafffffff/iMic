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

check(PolishCredentials.valid(String(repeating: "a", count: 4096), for: .custom), "4096-byte custom token is valid")
check(!PolishCredentials.valid(String(repeating: "a", count: 4097), for: .custom), "Oversized custom token is rejected")
let tempCredDir = FileManager.default.temporaryDirectory.appendingPathComponent("iMic-cred-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tempCredDir) }
try! FileManager.default.createDirectory(at: tempCredDir, withIntermediateDirectories: true)
let corruptCredURL = tempCredDir.appendingPathComponent("credentials.json")
let corruptBytes = Data("{not-valid-json".utf8)
try! corruptBytes.write(to: corruptCredURL)
check(!PolishCredentials.save("sk-valid-test-credential-1234", for: .bailian, file: CredentialFile(url: corruptCredURL)), "Corrupt credential file refuses silent overwrite")
check((try? Data(contentsOf: corruptCredURL)) == corruptBytes, "Corrupt credential file contents preserved")
let oversizedBytes = Data(repeating: 0x20, count: 64_001)
try! oversizedBytes.write(to: corruptCredURL)
check(!PolishCredentials.save("sk-valid-test-credential-1234", for: .bailian, file: CredentialFile(url: corruptCredURL)), "Oversized credential file refuses silent overwrite")
check((try? Data(contentsOf: corruptCredURL)) == oversizedBytes, "Oversized credential file contents preserved")
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
check(!key.saveButton.isEnabled && key.feedback.stringValue == L10n.text("Detecting region…"), "Validation is visibly pending")
wait(until: { done })
check(!key.dirty && app.key.stringValue == "sk-valid-preview-new-key", "Only a verified save adopts the draft")
key.value = "sk-bad-preview-key"
done = false
key.save { check(!$0, "Rejected key must not save"); done = true }
wait(until: { done })
check(key.feedback.stringValue.contains(BailianIssue.invalidKey.message), "Rejection is actionable inline")
check(app.key.stringValue == "sk-valid-preview-new-key", "Rejected draft leaves running credential intact")
settings.window.performClose(nil)
check(settings.window.attachedSheet != nil, "Dirty drafts require a close sheet")
print("Checking close / cancel")
allViews(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("Cancel") }!.performClick(nil)
wait(until: { settings.window.attachedSheet == nil })
check(settings.window.isVisible && key.dirty, "Cancel retains the draft")
settings.window.performClose(nil)
print("Checking close / discard")
allViews(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("Discard") }!.performClick(nil)
wait(until: { !settings.window.isVisible && !key.dirty })
check(!settings.window.isVisible && !key.dirty, "Discard closes and clears only drafts")
app.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: .deepseek)!)
app.polishProviderPicker.sendAction(app.polishProviderPicker.action!, to: app.polishProviderPicker.target)
check(DeepSeekConfiguration.provider == .deepseek, "Provider switches immediately without a key")
settings.select(.advanced)
let advanced = tabs.tabViewItems[4].viewController!.view
check(allViews(advanced).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(L10n.text("This provider has no valid Key. Polish will keep the original text.")) }, "Missing key warning stays visible")
let customKeyField = allViews(advanced).compactMap { $0 as? SettingsField }.first { $0.id == "custom.key" }!
let customModelField = allViews(advanced).compactMap { $0 as? SettingsField }.first { $0.id == "custom.model" }!
let customEndpointField = allViews(advanced).compactMap { $0 as? SettingsField }.first { $0.id == "custom.endpoint" }!
customKeyField.value = "custom-preview-token"
customModelField.value = "local-polish-model-v1"
customEndpointField.value = "http://127.0.0.1:1234/v1/chat/completions"
check(customKeyField.dirty && customModelField.dirty && customEndpointField.dirty, "All three custom provider drafts start dirty")
var staleSaveFinished = false
customKeyField.save { check(!$0, "Changing a sibling draft during async validation aborts save"); staleSaveFinished = true }
customModelField.value = "local-polish-model"
wait(until: { staleSaveFinished })
check(customKeyField.dirty && customModelField.dirty && customEndpointField.dirty, "Aborted save keeps all sibling drafts dirty")
var customSaved = false
customKeyField.save { check($0, "First-time custom provider save merges sibling drafts"); customSaved = true }
wait(until: { customSaved })
check(!customKeyField.dirty && !customModelField.dirty && !customEndpointField.dirty, "Saving one custom field marks all merged sibling drafts saved")
check(DeepSeekConfiguration.modelName(for: .custom) == "local-polish-model", "Custom model draft persisted")
check(DeepSeekConfiguration.endpoint(for: .custom) == "http://127.0.0.1:1234/v1/chat/completions", "Custom endpoint draft persisted")
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
let settingsIndex = app.statusMenu.items.firstIndex { $0.title == L10n.text("Settings…") }!
let websiteItem = app.statusMenu.items[settingsIndex + 1]
check(websiteItem.title == L10n.text("VoxChord website and help…") && websiteItem.action == #selector(AppDelegate.openWebsite), "Website help follows settings in menu")
let websiteButton = allViews(advanced).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("VoxChord website ↗") }
check(websiteButton?.action == #selector(AppDelegate.openWebsite), "Advanced help shares the menu action")
check(SetupLinks.website.absoluteString == "https://drafffffff.github.io/iMic/" + (L10n.isChinese ? "" : "en/"), "Shared website destination")
app.openWebsite() // Preview must return before opening the browser.
check(!app.statusMenu.items.contains { $0.title == L10n.text("Copy pairing code") || $0.title == "设置向导…" }, "Low frequency operations leave the top-level menu")
app.showCloudFailure(.key, provider: .bailian, recognition: true)
check(app.issueLabel.stringValue.contains(BailianIssue.invalidKey.message) && app.menuStatusItem.title.contains(BailianIssue.invalidKey.message), "ASR failures show reason in main and menu")
app.polishFallback = true
app.lastInsertSucceeded = false
app.refreshCloudFailure()
check(app.issueLabel.stringValue.contains(L10n.text("Polish failed. Original text kept for copying.")), "Failed delivery never claims text was inserted")
app.lastInsertSucceeded = true
app.refreshCloudFailure()
check(app.issueLabel.stringValue.contains(L10n.text("Polish failed. Original text typed.")), "Polish fallback after input is explicit")
app.showCloudFailure(.network, provider: .bailian, recognition: true)
app.performIssueAction()
check(app.connectionRecovered && app.issueLabel.stringValue.contains(L10n.text("Connection check passed. Record again on your iPhone.")) && app.menuIssueAction.isHidden, "Retry checks connectivity and asks for a fresh recording")
app.refreshUI()
check(app.issueLabel.stringValue.contains(L10n.text("Connection check passed. Record again on your iPhone.")), "Recovery message survives a UI refresh")
app.clearCloudFailure()
check(app.issueRow.isHidden && app.menuIssueAction.isHidden, "A new session clears stale failures")
settings.window.makeKeyAndOrderFront(nil)
let keyEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: 0, windowNumber: settings.window.windowNumber, context: nil,
    characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!
check(settings.window.performKeyEquivalent(with: keyEvent) && tabs.selectedTabViewItemIndex == 2, "Command-3 selects iPhone using the real window keyboard handler")
let second = SettingsWindowCoordinator(app: app)
check((second.window.contentViewController as! NSTabViewController).selectedTabViewItemIndex == 2, "Last selected tab persists")
// Exercise NSEvent -> main menu -> field editor, with production discovery and mocked HTTP.
final class KeyModelsProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(syntheticKey)", "Discovery preserves the synthetic Bearer header")
        check(BailianAddress.hosts.contains(request.url!.host!), "Mock sees only allowed discovery hosts")
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let status = request.url!.host == BailianAddress.hosts[0] ? 200 : 401
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"deepseek-v4.1-flash"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let syntheticKey = "sk-ws-AAAA.BBBB.CCCC." + String(repeating: "Ab09+/", count: 15) + "=="
let mockConfig = URLSessionConfiguration.ephemeral
mockConfig.protocolClasses = [KeyModelsProtocol.self]
let mockSession = URLSession(configuration: mockConfig)
let pasteboard = NSPasteboard.general
// Preserve clipboard contents in memory only; captures never include clipboard text.
let clipboard = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
    let copy = NSPasteboardItem()
    for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
    return copy
} ?? []
func command(_ character: String, in window: NSWindow, shift: Bool = false) {
    let codes: [String: UInt16] = ["a": 0, "v": 9, "c": 8, "x": 7, "z": 6]
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: shift ? [.command, .shift] : .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: shift ? character.uppercased() : character,
        charactersIgnoringModifiers: shift ? character.uppercased() : character,
        isARepeat: false, keyCode: codes[character]!)!
    application.sendEvent(event)
}
func paste(_ text: String, into field: NSTextField) {
    let window = field.window!
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    check(window.makeFirstResponder(field), "Input accepts focus")
    check(field.currentEditor() != nil, "Native field editor is active")
    command("a", in: window)
    check((field.currentEditor() as! NSTextView).selectedRange().length == field.stringValue.utf16.count, "Cmd+A selects all")
    pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    command("v", in: window)
    check(field.stringValue == text, "Cmd+V pastes through the main menu")
}
func checkSingleLine(_ field: NSTextField) {
    check(field.maximumNumberOfLines == 1 && field.cell?.wraps == false
          && field.cell?.isScrollable == true && field.cell?.usesSingleLineMode == true,
          "Long key uses a scrolling single-line cell")
    guard let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager,
          let container = editor.textContainer else { return }
    layout.ensureLayout(for: container)
    var lines = 0
    layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
    check(lines == 1, "Long secure mask renders as exactly one line in the field editor")
    check(editor.insertionPointColor.alphaComponent > 0, "Dark appearance has a visible caret")
}
let captureDirectory = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--capture-key-fields=") }
    .map { URL(fileURLWithPath: String($0.dropFirst("--capture-key-fields=".count))).appendingPathComponent(L10n.language) }
func captureKeyField(_ window: NSWindow, _ name: String) {
    guard let directory = captureDirectory else { return }
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    window.contentView!.layoutSubtreeIfNeeded()
    let view = window.contentView!.superview!
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
let edit = application.mainMenu!.items.compactMap(\.submenu).first { $0.title == L10n.text("Edit") }!
check(Set(["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]).isSubset(of: Set(edit.items.compactMap { $0.action?.description })), "All standard editing actions are installed")
app.previewSetup = app.setupSnapshot()
app.previewSetup?.key = nil
let wizard = SetupWizard(host: app, validationSession: mockSession)
wizard.reopen(at: .key)
let wizardContent = wizard.window!.contentView!
let wizardKey = allViews(wizardContent).compactMap { $0 as? NSSecureTextField }.first!
paste(syntheticKey, into: wizardKey)
checkSingleLine(wizardKey)
captureKeyField(wizard.window!, "setup-long-key")
wait(until: { app.setupSnapshot().key?.key == syntheticKey })
check(KeyModelsProtocol.count == 4, "Wizard Cmd+V automatically runs real region discovery against mocked HTTP")
check(app.endpoint.stringValue == BailianAddress.asr(BailianAddress.hosts[0]), "Wizard applies Beijing")
check(wizardKey.stringValue == syntheticKey, "Cleanup preserves the dotted key")
check(allViews(wizardContent).compactMap { $0 as? NSButton }.contains { $0.title == L10n.text("Next") && $0.isEnabled }, "Automatic verification enables Next")
captureKeyField(wizard.window!, "setup-success")
paste("sk-synthetic;invalid", into: wizardKey)
wait(until: { allViews(wizardContent).compactMap { $0 as? NSTextField }.contains { $0.stringValue == ShellCredentials.formatMessage } })
check(KeyModelsProtocol.count == 4, "Invalid format makes no HTTP request")
captureKeyField(wizard.window!, "setup-format-error")
paste("export DASHSCOPE_API_KEY='\(syntheticKey)'", into: wizardKey)
wait(until: { wizardKey.stringValue == syntheticKey && KeyModelsProtocol.count == 8 })
check(app.setupSnapshot().key?.key == syntheticKey, "Cmd+V uses automatic cleanup and validation")
wizard.close()

let keySettings = SettingsWindowCoordinator(app: app, validationSession: mockSession)
keySettings.select(.bailian); keySettings.window.makeKeyAndOrderFront(nil)
let keyTabs = keySettings.window.contentViewController as! NSTabViewController
let keyPane = keyTabs.tabViewItems[1].viewController!.view
let keyRow = allViews(keyPane).compactMap { $0 as? SettingsField }.first { $0.id == "bailian.key" }!
allViews(keyPane).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "overrideBailianKey" }!.performClick(nil)
let settingsKey = allViews(keyRow).compactMap { $0 as? NSSecureTextField }.first!
paste(syntheticKey, into: settingsKey)
checkSingleLine(settingsKey)
check(settingsKey.frame.height == 28, "Secure field keeps the standard settings input height")
captureKeyField(keySettings.window, "settings-long-key")
wait(until: { !keyRow.dirty && keyRow.feedback.stringValue.contains(L10n.text("Detected: %@.", BailianAddress.title("cn-beijing"))) })
check(KeyModelsProtocol.count == 12 && keyRow.value == syntheticKey, "Settings Cmd+V automatically verifies and saves via mocked HTTP")
check(keyRow.feedback.stringValue.contains(L10n.text("The model list does not include the speech model. Access will be confirmed on first recognition.")), "Missing ASR entry remains an accurate first-recognition notice")
captureKeyField(keySettings.window, "settings-success")
paste("sk-synthetic;invalid", into: settingsKey)
wait(until: { keyRow.feedback.stringValue == ShellCredentials.formatMessage })
check(KeyModelsProtocol.count == 12, "Settings rejects invalid format before HTTP")
captureKeyField(keySettings.window, "settings-format-error")
paste("export DASHSCOPE_API_KEY='\(syntheticKey)'", into: settingsKey)
wait(until: { !keyRow.dirty && KeyModelsProtocol.count == 16 })
check(settingsKey.stringValue == syntheticKey, "Settings cleans pasted assignment without altering key content")
keySettings.window.orderOut(nil)

// Standard fields share the same menu, including Base URL and custom service addresses.
keySettings.select(.advanced)
let addresses = allViews(keyTabs.tabViewItems[4].viewController!.view).compactMap { $0 as? SettingsField }
for row in addresses where row.id.hasSuffix(".endpoint") && row.id != "bailian.endpoint" {
    let field = allViews(row).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    let original = field.stringValue
    paste("https://synthetic.example/v1/chat/completions", into: field)
    command("a", in: keySettings.window); command("c", in: keySettings.window)
    check(pasteboard.string(forType: .string) == field.stringValue, "Cmd+C copies an ordinary input")
    command("x", in: keySettings.window)
    check(field.stringValue.isEmpty, "Cmd+X cuts an ordinary input")
    command("z", in: keySettings.window)
    check(!field.stringValue.isEmpty, "Cmd+Z undoes the cut")
    command("z", in: keySettings.window, shift: true)
    check(field.stringValue.isEmpty, "Cmd+Shift+Z redoes the cut")
    row.value = original; row.cancel()
    break
}
keySettings.select(.bailian)
keySettings.window.makeKeyAndOrderFront(nil)
allViews(keyPane).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "bailianAdvancedToggle" }!.performClick(nil)
captureKeyField(keySettings.window, "settings-service-address")
keySettings.window.orderOut(nil)
let addressWizard = SetupWizard(host: app)
addressWizard.reopen(at: .key)
allViews(addressWizard.window!.contentView!).compactMap { $0 as? NSButton }.first {
    $0.title == L10n.text("Advanced options · Set service address manually")
}!.performClick(nil)
captureKeyField(addressWizard.window!, "setup-service-address")
addressWizard.close()
mockSession.invalidateAndCancel()
pasteboard.clearContents(); pasteboard.writeObjects(clipboard)
print("Key fields: Cmd+V/A via native events, mocked discovery, cleanup, format rejection, single-line masks and ordinary C/X/Z/redo passed")

#if DEBUG
if let output = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-onboarding=") }) {
    let directory = URL(fileURLWithPath: String(output.dropFirst("--capture-onboarding=".count)))
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let capture = SetupWizard(host: app); capture.reopen(at: .key)
    for state in ["initial", "checking", "models", "success", "invalid", "plan", "permission", "ip", "billing", "network", "unsupported"] {
        capture.previewKeyState(state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let content = capture.window!.contentView!
        content.layoutSubtreeIfNeeded()
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("setup-key-\(state).png"))
    }
    capture.close()
    print("Captured 11 native onboarding states (DEBUG, synthetic credentials only)")
}
#endif
check(fileFingerprint() == before, "Previews and unchanged external credentials must not touch credentials.json")
check(UserDefaults.standard.object(forKey: "polishProvider") as? String == standardBefore, "Preview actions must not change real preferences")
print("Mac settings: five toolbar panes, external key override, verified save, rejected draft, close sheet, immediate provider, phone/menu sync, silent launch/reopen, waiting/pairing, failure actions and preview isolation passed")

settings.select(.general)
let general = tabs.tabViewItems[0].viewController!.view
let generalButtons = allViews(general).compactMap { $0 as? NSButton }
check(generalButtons.contains { $0.title == L10n.text("Check for updates automatically") }, "General has automatic update checks")
check(generalButtons.contains { $0.title == L10n.text("Download and install updates automatically") && $0.state == .off }, "Automatic installation defaults off")
check(allViews(general).compactMap { $0 as? NSTextField }.contains { $0.stringValue == MacUpdater.version }, "General shows marketing and build versions")
check(app.statusMenu.items.contains { $0.title == L10n.text("Check for updates…") && $0.action == #selector(AppDelegate.checkForUpdates) }, "Menu shares updater action")
app.currentSession = nil; app.inserting = false; app.clearingInput = false
check(!app.updateIsIdle, "The native wizard above was closed unfinished; updates must remain deferred")
SetupProgress.clear() // Finish the separate wizard fixture before checking other idle states.
check(app.updateIsIdle, "Idle permits update UI")
app.currentSession = 42
check(!app.updateIsIdle, "Recording / recognition / polish session defers update UI")
app.currentSession = nil; app.inserting = true
check(!app.updateIsIdle, "Typing defers update UI")
app.inserting = false; app.clearingInput = true
check(!app.updateIsIdle, "Clearing defers update UI")
app.clearingInput = false
SetupProgress.save(.key)
check(!app.updateIsIdle, "Unfinished setup defers updates even when its window is closed")
SetupProgress.clear()
check(app.updateIsIdle, "Finishing setup resumes updates")
MacPreferences.defaults.set(SetupWizard.version, forKey: SetupWizard.completedKey)
app.showSetup(at: .key)
check(app.setupWizard?.window?.isVisible == true && !app.updateIsIdle, "Visible reopened wizard still defers updates while open")
app.setupWizard?.close()
check(SetupProgress.saved() == nil && app.updateIsIdle, "Closing a reopened wizard after completion clears inProgressStep and does not block updates")
SetupProgress.save(.permissions)
check(app.updateIsIdle && SetupProgress.saved() == nil, "Stale inProgressStep after completed setup does not block updates")
MacPreferences.defaults.removeObject(forKey: SetupWizard.completedKey)

// Quit / termination draft confirmation callback and pair code rotation in Settings.
settings.select(.iphone)
settings.window.makeKeyAndOrderFront(nil)
let iphonePane = tabs.tabViewItems[2].viewController!.view
allViews(iphonePane).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("Pair a new iPhone") }!.performClick(nil)
let pairCodeField = allViews(iphonePane).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "settingsPairCode" }!
app.store.overrideCode("111222")
settings.refreshPairCode()
let beforePairLabel = pairCodeField.stringValue
app.rotatePairCode()
check(pairCodeField.stringValue != beforePairLabel && pairCodeField.stringValue.contains(PairingCode.formatted(app.store.currentCode())), "Regenerate immediately updates the pair code in Settings")
settings.select(.bailian)
key.value = "sk-unsaved-quit-draft-key"
check(key.dirty && settings.window.isVisible, "Draft prepared for termination check")
var closeAllowed = false
var closeCancelled = false
check(!settings.confirmClose(onAllow: { closeAllowed = true }, onCancel: { closeCancelled = true }), "Dirty settings window defers close/quit")
check(settings.window.attachedSheet != nil, "Quit confirmation presents draft sheet")
allViews(settings.window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == L10n.text("Cancel") }!.performClick(nil)
wait(until: { settings.window.attachedSheet == nil && closeCancelled })
check(!closeAllowed && closeCancelled && key.dirty, "Cancelling close sheet invokes onCancel and preserves draft")
key.reset()
var synchronousCloseCallback = false
check(settings.confirmClose(onAllow: { synchronousCloseCallback = true }), "Clean settings approve closing synchronously")
check(!synchronousCloseCallback, "Synchronous approval must not send a terminateLater reply")
check(app.applicationShouldTerminate(NSApp) == .terminateNow, "Clean settings do not defer application termination")
settings.window.orderOut(nil)
print("Mac updater settings, menu and recording / typing / clearing / setup gates passed")

#if DEBUG
if let output = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-ui=") }) {
    let directory = URL(fileURLWithPath: String(output.dropFirst("--capture-ui=".count)))
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func captureView(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    for pane in SettingsPane.allCases {
        settings.select(pane); settings.window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        captureView(settings.window.contentView!.superview!, "settings-" + pane.rawValue)
    }
    settings.window.orderOut(nil)
    app.show(); captureView(app.window.contentView!.superview!, "main")
    let wizard = SetupWizard(host: app)
    wizard.reopen(at: .key); wizard.previewKeyState("invalid")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    captureView(wizard.window!.contentView!.superview!, "setup-key-error")
    wizard.reopen(at: .permissions)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    captureView(wizard.window!.contentView!.superview!, "setup-permissions")
    wizard.close()
    print("Captured main, all five settings panes and both setup steps")
}
#endif
