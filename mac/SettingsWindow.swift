import AppKit
import ServiceManagement
import ApplicationServices
import CoreBluetooth
import CryptoKit

// The tab bar is owned by AppKit, with keyboard shortcuts handled by the window.
enum SettingsPane: String, CaseIterable {
    case general, bailian, iphone, permissions, advanced
    var title: String { [L10n.text("General"), L10n.text("Model Studio"), "iPhone", L10n.text("Permissions"), L10n.text("Advanced")][Self.allCases.firstIndex(of: self)!] }
    var symbol: String { ["gearshape", "key", "iphone", "lock.shield", "slider.horizontal.3"][Self.allCases.firstIndex(of: self)!] }
}

private final class SettingsTabs: NSTabViewController {
    var changed: (() -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        changed?()
    }
}
private final class SettingsPanel: NSWindow {
    var selectPane: ((Int) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let number = Int(event.charactersIgnoringModifiers ?? ""), (1...5).contains(number) {
            selectPane?(number - 1); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    let window: NSWindow
    private let tabs = SettingsTabs()
    private var stacks: [SettingsPane: NSStackView] = [:]
    private var fields: [String: SettingsField] = [:]
    private var profiles: [PolishProvider: NSStackView] = [:]
    private let profileSlot = NSStackView()
    private let providerWarning = NSTextField(wrappingLabelWithString: "")
    private let detectedService = NSTextField(wrappingLabelWithString: "")
    private let activeProvider = NSTextField(wrappingLabelWithString: "")
    private var accessStatus: NSTextField!
    private var screenStatus: NSTextField!
    private var bluetoothStatus: NSTextField!
    private var updateChecks: NSButton?
    private var updateInstalls: NSButton?
    var loginCheck: NSButton!
    var loginHint: NSTextField!
    var loginSettingsButton: NSButton!
    private var observers: [NSObjectProtocol] = []
    private var defaults: UserDefaults { MacPreferences.defaults }
    private var preview: Bool { app?.preview != nil }

    init(app: AppDelegate) {
        self.app = app
        window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        if app.preview == "settings-external-key" {
            previewKeys[.bailian] = ResolvedCredential(key: "sk-preview-external-credential", source: .environment("DASHSCOPE_API_KEY"))
        } else if app.preview == "settings-empty" { previewKeys.removeAll() }
        window.title = L10n.text("iMic Settings"); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = .imicInk
        window.delegate = self
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let stack = makeContent(pane)
            stacks[pane] = stack
            let controller = NSViewController()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true; scroll.borderType = .noBorder
            let document = FlippedInkView()
            document.translatesAutoresizingMaskIntoConstraints = false
            stack.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack); scroll.documentView = document
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
            ])
            controller.view = scroll
            let item = NSTabViewItem(viewController: controller)
            item.identifier = pane.rawValue; item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        tabs.changed = { [weak self] in self?.selectionChanged() }
        (window as? SettingsPanel)?.selectPane = { [weak self] in self?.tabs.selectedTabViewItemIndex = $0 }
        let first: SettingsPane = resolved(.bailian) == nil ? .bailian : .general
        select(SettingsPane(rawValue: defaults.string(forKey: "settings.selectedPane") ?? "") ?? first)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in self?.refreshPermissions(); self?.refreshLoginState() })
        refreshCredentials(); refreshPermissions(); refreshLoginState()
        window.center()
    }
    deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }

    func select(_ pane: SettingsPane) {
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane)!
        selectionChanged()
    }
    func selectionChanged() {
        guard SettingsPane.allCases.indices.contains(tabs.selectedTabViewItemIndex) else { return }
        let pane = SettingsPane.allCases[tabs.selectedTabViewItemIndex]
        defaults.set(pane.rawValue, forKey: "settings.selectedPane")
        if pane == .permissions { refreshPermissions() }
        if pane == .general { refreshLoginState(); refreshUpdates() }
        window.recalculateKeyViewLoop()
        resize()
    }
    func resize() {
        guard SettingsPane.allCases.indices.contains(tabs.selectedTabViewItemIndex),
              let stack = stacks[SettingsPane.allCases[tabs.selectedTabViewItemIndex]] else { return }
        stack.layoutSubtreeIfNeeded()
        let maximum = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(maximum - 130, max(260, stack.fittingSize.height + 44))
        tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.preferredContentSize = NSSize(width: 560, height: height)
        let frameSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height)).size
        let top = window.frame.maxY
        var frame = NSRect(x: window.frame.minX, y: top - frameSize.height, width: frameSize.width, height: frameSize.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
    func show() { refreshCredentials(); refreshPermissions(); refreshLoginState(); refreshUpdates(); resize() }

    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = app!.column(views, spacing: spacing); stack.detachesHiddenViews = true
        for view in views { app!.fullWidth(view, in: stack) }
        return stack
    }
    private func note(_ text: String) -> NSTextField {
        let label = app!.label(text, size: 11)
        label.preferredMaxLayoutWidth = 512
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func heading(_ text: String) -> NSView { app!.label(text, size: 10, color: .imicMuted, mono: true, weight: .semibold) }
    private func action(_ title: String, _ selector: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: selector)
        b.bezelStyle = .rounded; b.controlSize = .small; b.setAccessibilityLabel(title); return b
    }
    private func field(_ id: String, _ title: String, _ value: String, secure: Bool = false) -> SettingsField {
        let row = SettingsField(id: id, title: title, value: value, secure: secure)
        fields[id] = row
        row.onSave = { [weak self] field, completion in self?.save(field, completion: completion) }
        return row
    }
    private func makeContent(_ pane: SettingsPane) -> NSStackView {
        switch pane {
        case .general: return general()
        case .bailian: return bailian()
        case .iphone: return iphone()
        case .permissions: return permissions()
        case .advanced: return advanced()
        }
    }
    private func general() -> NSStackView {
        let app = app!
        app.automatic.title = L10n.text("Type into the active app after recognition")
        app.automatic.target = app; app.automatic.action = #selector(AppDelegate.toggleAutoInput)
        app.automatic.contentTintColor = nil; app.automatic.setAccessibilityLabel(app.automatic.title)
        app.livePreviewCheck = app.checkbox(L10n.text("Live preview and incremental typing"), #selector(AppDelegate.toggleLivePreview), key: "livePreview", defaultValue: true)
        let input = column([app.automatic, app.livePreviewCheck,
            note(L10n.text("Some editors use keyboard compatibility mode, which may duplicate or delete text by mistake. Keypresses, clicks, or app switches stop automatic revisions for this session."))], spacing: 9)
        loginCheck = NSButton(checkboxWithTitle: L10n.text("Launch at login"), target: self, action: #selector(toggleLogin))
        loginCheck.setAccessibilityLabel(loginCheck.title)
        loginHint = note("")
        loginSettingsButton = action(L10n.text("Open Login Items Settings…"), #selector(openLoginSettings))
        loginSettingsButton.isHidden = true
        let show = NSButton(checkboxWithTitle: L10n.text("Show main window at launch"), target: self, action: #selector(toggleShowMain(_:)))
        show.state = defaults.bool(forKey: "showMainWindowOnLaunch") ? .on : .off
        show.setAccessibilityLabel(show.title)
        let checks = NSButton(checkboxWithTitle: L10n.text("Check for updates automatically"), target: self, action: #selector(toggleUpdateChecks(_:)))
        updateChecks = checks
        checks.state = app.macUpdater.automaticallyChecks ? .on : .off
        checks.isEnabled = MacUpdater.configured || preview
        checks.setAccessibilityLabel(checks.title)
        let installs = NSButton(checkboxWithTitle: L10n.text("Download and install updates automatically"), target: self, action: #selector(toggleUpdateInstalls(_:)))
        updateInstalls = installs
        installs.state = app.macUpdater.automaticallyInstalls ? .on : .off
        installs.isEnabled = MacUpdater.configured || preview
        installs.setAccessibilityLabel(installs.title)
        let updates = column([heading("UPDATES"), note(MacUpdater.version), checks, installs,
            note(MacUpdater.configured ? L10n.text("Checks daily. Prompts and restarts wait until recording, typing, and setup finish.") : L10n.text("This development build has no update public key. Automatic checks are off.")),
            app.linkButton(L10n.text("Check for updates…"), #selector(AppDelegate.checkForUpdates))], spacing: 9)
        app.saveFeedback.font = .systemFont(ofSize: 11); app.saveFeedback.textColor = .imicMuted
        return column([heading("INPUT"), input, app.divider(), heading("STARTUP"),
            loginCheck, loginHint, loginSettingsButton, show, app.divider(), updates, app.divider(), app.linkButton(L10n.text("Test typing"), #selector(AppDelegate.testInput)), app.saveFeedback])
    }
    private func refreshUpdates() {
        updateChecks?.state = app?.macUpdater.automaticallyChecks == true ? .on : .off
        updateInstalls?.state = app?.macUpdater.automaticallyInstalls == true ? .on : .off
    }
    @objc private func toggleUpdateChecks(_ sender: NSButton) {
        guard !preview else { return }
        app?.macUpdater.setAutomaticChecks(sender.state == .on)
    }
    @objc private func toggleUpdateInstalls(_ sender: NSButton) {
        guard !preview else { return }
        app?.macUpdater.setAutomaticInstalls(sender.state == .on)
    }
    private func bailian() -> NSStackView {
        let app = app!
        let key = field("bailian.key", L10n.text("Model Studio API Key"), resolved(.bailian)?.key ?? "", secure: true)
        key.onEdit = { [weak self, weak key] in
            guard let self, let key, !key.value.isEmpty else { return }
            let work = DispatchWorkItem { [weak self, weak key] in
                guard let self, let key else { return }
                self.save(key) { _ in }
            }
            key.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        let override = action(L10n.text("Use the Key saved in iMic"), #selector(overrideBailianKey))
        override.identifier = NSUserInterfaceItemIdentifier("overrideBailianKey")
        override.isHidden = resolved(.bailian)?.source.isExternal != true
        app.deepseekCheck = app.checkbox(L10n.text("Enable AI polish and conversion"), #selector(AppDelegate.toggleDeepSeek), key: "deepseekEnabled", defaultValue: DeepSeekConfiguration.enabled)
        let options = DeepSeekConfiguration.options
        app.polishModeButtons = NSSegmentedControl(labels: PolishMode.allCases.map(\.title), trackingMode: .selectOne,
            target: app, action: #selector(AppDelegate.changePolishOptions(_:)))
        app.polishToneButtons = NSSegmentedControl(labels: PolishTone.allCases.map(\.title), trackingMode: .selectOne,
            target: app, action: #selector(AppDelegate.changePolishOptions(_:)))
        for control in [app.polishModeButtons!, app.polishToneButtons!] {
            control.segmentStyle = .rounded; control.segmentDistribution = .fillEqually
            control.selectedSegmentBezelColor = .imicOrange; control.font = .systemFont(ofSize: 11)
            control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        app.polishModeButtons.setAccessibilityLabel(L10n.text("Conversion mode"))
        app.polishToneButtons.setAccessibilityLabel(L10n.text("Tone"))
        app.polishModeButtons.selectedSegment = PolishMode.allCases.firstIndex(of: options.mode) ?? 0
        app.polishToneButtons.selectedSegment = PolishTone.allCases.firstIndex(of: options.tone) ?? 0
        app.polishOutputPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        app.polishOutputPicker.addItems(withTitles: PolishOutput.languages.map(\.title))
        app.polishOutputPicker.selectItem(at: PolishOutput.languages.firstIndex(of: options.output) ?? 0)
        app.polishOutputPicker.target = app; app.polishOutputPicker.action = #selector(AppDelegate.changePolishOutput(_:))
        app.polishOutputPicker.setAccessibilityLabel(L10n.text("Output language"))
        app.polishModeHint = note(""); app.polishToneHint = note(""); app.polishOptionsHint = note("")
        app.updatePolishOptionControls(options)
        let choices = column([heading("MODE"), app.polishModeButtons, app.polishModeHint,
            heading("TONE"), app.polishToneButtons, app.polishToneHint,
            heading("LANGUAGE"), app.polishOutputPicker, app.polishOptionsHint], spacing: 7)
        app.polishFields = choices; choices.isHidden = !DeepSeekConfiguration.enabled
        activeProvider.font = .systemFont(ofSize: 11); activeProvider.textColor = .imicMuted
        let base = field("bailian.base", L10n.text("Set service address manually (Base URL, optional)"), "")
        let advanced = NSStackView(views: [base])
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.isHidden = true
        base.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        let toggle = action(L10n.text("Advanced options · Set service address manually"), #selector(toggleBailianAdvanced(_:)))
        toggle.identifier = NSUserInterfaceItemIdentifier("bailianAdvancedToggle")
        toggle.target = self
        bailianAdvanced = advanced
        return column([note(L10n.text("Paste your Key to detect its region and verify it. One Model Studio Key handles recognition and polish.")), note(L10n.text("For overseas accounts, use Alibaba Cloud’s international site and create a Key in Singapore.")), key, override, toggle, advanced,
            app.linkButton(L10n.text("Get a Model Studio Key ↗"), #selector(AppDelegate.openBailianConsole)), app.divider(),
            heading("AI POLISH"), activeProvider, app.deepseekCheck, choices], spacing: 12)
    }
    private var bailianAdvanced: NSStackView?
    @objc private func toggleBailianAdvanced(_ sender: NSButton) {
        bailianAdvanced?.isHidden.toggle(); resize()
    }
    private func iphone() -> NSStackView {
        let app = app!
        app.pairedList = app.column([], spacing: 12); app.rebuildPairedList()
        let devices = NSScrollView(frame: NSRect(x: 0, y: 0, width: 512, height: 92))
        devices.drawsBackground = false; devices.hasVerticalScroller = true; devices.autohidesScrollers = true
        let document = FlippedInkView(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(app.pairedList); app.pairedList.translatesAutoresizingMaskIntoConstraints = false
        devices.documentView = document
        NSLayoutConstraint.activate([
            devices.heightAnchor.constraint(equalToConstant: max(26, min(150, CGFloat(app.store.devices.count) * 45))), document.widthAnchor.constraint(equalTo: devices.contentView.widthAnchor),
            app.pairedList.leadingAnchor.constraint(equalTo: document.leadingAnchor), app.pairedList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            app.pairedList.topAnchor.constraint(equalTo: document.topAnchor), app.pairedList.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        let code = note(L10n.text("Pairing code: %@", L10n.argument(app.store.currentCode())))
        code.identifier = NSUserInterfaceItemIdentifier("settingsPairCode"); code.isHidden = true
        let pair = action(L10n.text("Pair a new iPhone"), #selector(showPairCode))
        let actions = app.row([app.linkButton(L10n.text("Copy pairing code"), #selector(AppDelegate.copyPairCode)),
            app.linkButton(L10n.text("Regenerate"), #selector(AppDelegate.rotatePairCode)), app.linkButton(L10n.text("Forget all pairings"), #selector(AppDelegate.forgetAllDevices))], spacing: 14)
        app.snapReturnCheck = app.checkbox(L10n.text("Pull down and release for Return"), #selector(AppDelegate.toggleSnapReturn), key: "snapReturn", defaultValue: true)
        app.pullDeleteCheck = app.checkbox(L10n.text("Pull up to delete"), #selector(AppDelegate.togglePullDelete), key: "pullDelete", defaultValue: true)
        app.swipeCursorCheck = app.checkbox(L10n.text("Slide left or right to move the cursor##3a8df390"), #selector(AppDelegate.toggleSwipeCursor), key: "swipeCursor", defaultValue: true)
        app.bleFallbackCheck = app.checkbox(L10n.text("Use Bluetooth when the local network is unavailable"), #selector(AppDelegate.toggleBLEFallback), key: "bleFallback", defaultValue: true)
        return column([heading("PAIRED DEVICES"), devices, pair, code, actions, app.divider(), heading("STRING GESTURES"),
            app.snapReturnCheck, app.pullDeleteCheck, app.swipeCursorCheck, app.divider(), heading("CONNECTION"),
            app.bleFallbackCheck, note(L10n.text("Bluetooth has lower bandwidth. Long recordings may keep uploading.")), app.linkButton(L10n.text("Open Bluetooth Settings…"), #selector(AppDelegate.openBluetoothSettings))], spacing: 10)
    }
    private func permissionRow(_ title: String, _ detail: String, _ selector: Selector) -> (NSView, NSTextField) {
        let status = note("○"); status.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let text = column([app!.label(title, size: 12, color: .imicIvory), note(detail)], spacing: 4)
        let button = action(L10n.text("Open Settings…"), selector); button.setAccessibilityLabel(L10n.text("Open %@ Settings", L10n.argument(title)))
        let row = app!.row([status, text, button], spacing: 10)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.widthAnchor.constraint(equalTo: row.widthAnchor,
            constant: -(38 + button.fittingSize.width)).isActive = true
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        return (row, status)
    }
    private func permissions() -> NSStackView {
        let app = app!
        let access = permissionRow(L10n.text("Accessibility"), L10n.text("Required · Type recognized text into the active app."), #selector(openAccessibility))
        let screen = permissionRow(L10n.text("Screen Recording"), L10n.text("Optional · Locate the polish highlight. Processed only on this Mac."), #selector(openScreenRecording))
        let bluetooth = permissionRow(L10n.text("Bluetooth"), L10n.text("Optional · Connect when the local network is unavailable."), #selector(openBluetoothPrivacy))
        accessStatus = access.1; screenStatus = screen.1; bluetoothStatus = bluetooth.1
        app.polishSweepCheck = app.checkbox(L10n.text("Highlight text after polish"), #selector(AppDelegate.togglePolishSweep), key: "polishSweep", defaultValue: true)
        app.polishSweepHint = note(L10n.text("Requires macOS 14+ and Screen Recording permission. Locates text on this Mac without saving screenshots. Typing still works if location fails."))
        return column([heading("PERMISSIONS"), access.0, screen.0, bluetooth.0, app.divider(), heading("POLISH SWEEP"), app.polishSweepCheck, app.polishSweepHint], spacing: 18)
    }
    private func advanced() -> NSStackView {
        let app = app!
        app.polishProviderPicker.removeAllItems()
        app.polishProviderPicker.addItems(withTitles: PolishProvider.allCases.map(\.title))
        app.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: DeepSeekConfiguration.provider) ?? 0)
        app.polishProviderPicker.target = self; app.polishProviderPicker.action = #selector(changeProvider)
        app.polishProviderPicker.setAccessibilityLabel(L10n.text("Polish service provider"))
        providerWarning.font = .systemFont(ofSize: 11); providerWarning.textColor = .systemOrange
        providerWarning.preferredMaxLayoutWidth = 512
        profileSlot.orientation = .vertical; profileSlot.alignment = .leading; profileSlot.detachesHiddenViews = true
        for provider in PolishProvider.allCases {
            var views: [NSView] = []
            if provider != .bailian {
                views.append(field("\(provider.rawValue).key", "\(provider.title) Key", resolved(provider)?.key ?? "", secure: true))
                let override = action(L10n.text("Use the Key saved in iMic"), #selector(overrideServiceKey(_:)))
                override.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
                override.isHidden = resolved(provider)?.source.isExternal != true
                views.append(override)
            }
            views.append(field("\(provider.rawValue).model", L10n.text("Model"), DeepSeekConfiguration.modelName(for: provider)))
            views.append(field("\(provider.rawValue).endpoint", L10n.text("Chat Completions address"), DeepSeekConfiguration.endpoint(for: provider)))
            if provider == .bailian { views.append(note(L10n.text("The model runs on Model Studio. The address must match the Key's region or workspace."))) }
            let group = column(views, spacing: 10); profiles[provider] = group
            profileSlot.addArrangedSubview(group); app.fullWidth(group, in: profileSlot)
        }
        let fixed = app.label(ASRConfiguration.model, size: 11, color: .imicIvory, mono: true)
        fixed.isSelectable = true; fixed.setAccessibilityLabel(L10n.text("Recognition model (read-only)"))
        detectedService.font = .systemFont(ofSize: 11); detectedService.textColor = .imicMuted
        return column([detectedService, heading("POLISH SERVICE"), app.polishProviderPicker, providerWarning, profileSlot,
            app.divider(), heading("RECOGNITION"), fixed,
            field("asr.endpoint", L10n.text("Recognition service address"), app.endpoint.stringValue),
            note(L10n.text("Only Model Studio inference addresses are supported. Must match the Key's region or workspace.")),
            app.divider(), app.linkButton(L10n.text("Reopen setup…"), #selector(AppDelegate.showSetupAction)),
            app.linkButton(L10n.text("iMic website ↗"), #selector(AppDelegate.openWebsite))], spacing: 10)
    }

    private var previewKeys: [PolishProvider: ResolvedCredential] = [
        .bailian: ResolvedCredential(key: "sk-preview-bailian-credential", source: .app)
    ]
    private func resolved(_ provider: PolishProvider) -> ResolvedCredential? {
        preview ? previewKeys[provider] : PolishCredentials.resolve(for: provider)
    }
    func refreshCredentials() {
        let region = defaults.string(forKey: "bailian.detectedRegion")
        detectedService.stringValue = region.map { L10n.text("Detected: %@ · %@", L10n.argument(BailianAddress.title($0)), L10n.argument(app?.endpoint.stringValue ?? "")) } ?? L10n.text("Current service address: %@ · Region is detected when saving a Key.", L10n.argument(app?.endpoint.stringValue ?? ""))
        for id in ["asr.endpoint", "bailian.endpoint"] {
            if let row = fields[id], !row.dirty {
                row.markSaved(id == "asr.endpoint" ? app!.endpoint.stringValue : DeepSeekConfiguration.endpoint(for: .bailian))
            }
        }
        for provider in PolishProvider.allCases {
            guard let row = fields["\(provider.rawValue).key"] else { continue }
            let credential = resolved(provider)
            if !row.dirty {
                if row.value != credential?.key ?? "" { row.markSaved(credential?.key ?? "") }
                row.setEditable(credential?.source.isExternal != true)
            }
            row.source.isHidden = false
            row.source.stringValue = credential.map { L10n.text("Source: %@ · iMic configuration takes priority over environment variables and shell files.", L10n.argument($0.source.tag)) } ?? L10n.text("No Key configured yet.")
        }
        for row in fields.values where !row.dirty && row.feedback.stringValue.isEmpty {
            let prefix = "settings.validation.\(row.id)."
            if defaults.string(forKey: prefix + "digest") == VerifiedKeyMemory.digest(row.value),
               let date = defaults.object(forKey: prefix + "date") as? Date,
               let status = defaults.string(forKey: prefix + "status") {
                let verified = status == "verified" || ["en", "zh-Hans"].contains { language in
                    status.hasPrefix(L10n.localized("Verified", bundle: .main, language: language))
                }
                let rejected = status == "rejected" || ["en", "zh-Hans"].contains { language in
                    status == L10n.localized("Key rejected", bundle: .main, language: language)
                }
                let title = verified ? L10n.text("Verified") : (rejected ? L10n.text("Key rejected") : L10n.text("Verification failed"))
                row.message("\(title) · \(date.formatted(.dateTime.locale(L10n.locale).year().month(.abbreviated).day().hour().minute()))", error: !verified)
            }
        }
        refreshProvider()
    }
    private func refreshProvider() {
        let provider = DeepSeekConfiguration.provider
        for (source, group) in profiles { group.isHidden = source != provider }
        activeProvider.stringValue = provider == .bailian ? "" : L10n.text("Polish provider: %@ · Change in Advanced", L10n.argument(provider.title))
        activeProvider.isHidden = provider == .bailian
        let credential = resolved(provider)
        let prefix = "settings.validation.\(provider.rawValue).key."
        let rejected = credential.map {
            defaults.string(forKey: prefix + "digest") == VerifiedKeyMemory.digest($0.key)
                && defaults.string(forKey: prefix + "status") == L10n.text("Key rejected")
        } ?? false
        providerWarning.stringValue = credential == nil || rejected ? L10n.text("This provider has no valid Key. Polish will keep the original text.") : ""
        providerWarning.isHidden = providerWarning.stringValue.isEmpty
        app?.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: provider) ?? 0)
    }
    @objc private func changeProvider() {
        guard let app, PolishProvider.allCases.indices.contains(app.polishProviderPicker.indexOfSelectedItem) else { return }
        let provider = PolishProvider.allCases[app.polishProviderPicker.indexOfSelectedItem]
        defaults.set(provider.rawValue, forKey: "polishProvider")
        refreshProvider(); resize()
    }
    @objc private func overrideServiceKey(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        fields["\(id).key"]?.setEditable(true)
        fields["\(id).key"]?.message(L10n.text("After saving, the Key in iMic takes priority."))
        sender.isHidden = true
    }
    @objc private func overrideBailianKey(_ sender: NSButton) {
        fields["bailian.key"]?.setEditable(true)
        fields["bailian.key"]?.message(L10n.text("After saving, the Key in iMic takes priority."))
        sender.isHidden = true
    }

    private func save(_ row: SettingsField, completion: @escaping (Bool) -> Void) {
        row.cancel()
        let value = row.value, generation = row.generation
        let originalASR = app!.endpoint.stringValue
        let components = row.id.split(separator: ".").map(String.init)
        let provider = PolishProvider(rawValue: components[0]) ?? .bailian
        let kind = components.last!
        // Explicit deletion preserves the previous app-file → environment → shell fallback.
        if kind == "key", value.isEmpty {
            guard row.dirty, resolved(provider)?.source == .app else {
                row.message(L10n.text("Enter a valid API Key."), error: true); completion(false); return
            }
            let saved = preview || PolishCredentials.save("", for: provider)
            if saved {
                if preview { previewKeys.removeValue(forKey: provider) }
                row.markSaved(resolved(provider)?.key ?? "")
                row.message(L10n.text("Removed the Key saved in iMic."))
                configurationChanged()
            } else { row.message(L10n.text("Cannot write to the iMic configuration file."), error: true) }
            completion(saved); return
        }
        if row.id == "bailian.key" || row.id == "bailian.base" {
            saveBailian(row, completion: completion); return
        }
        let credentialBefore = resolved(provider)?.key
        let providerEndpointBefore = DeepSeekConfiguration.endpoint(for: provider)
        var bailianCheck: (String, String)?
        let request: URLRequest
        do {
            if row.id == "bailian.key" || row.id == "asr.endpoint" {
                let address = row.id == "asr.endpoint" ? value : (fields["asr.endpoint"]?.value ?? app!.endpoint.stringValue)
                guard SettingsValidation.asrURL(address) != nil else { throw PolishConfigurationError.bailianHost }
                let key = row.id == "bailian.key" ? value : resolved(.bailian)?.key ?? ""
                guard let check = BailianKeyCheck.request(key: key, asrEndpoint: address) else { throw PolishConfigurationError.key }
                request = check
                bailianCheck = (key, address)
            } else {
                let key = kind == "key" ? value : resolved(provider)?.key ?? ""
                let model = kind == "model" ? value : DeepSeekConfiguration.modelName(for: provider)
                let endpoint = kind == "endpoint" ? value : DeepSeekConfiguration.endpoint(for: provider)
                request = try SettingsValidation.request(provider: provider, key: key, model: model, endpoint: endpoint)
            }
        } catch {
            row.message((error as? PolishConfigurationError)?.rawValue ?? L10n.text("Check your configuration."), error: true)
            completion(false); return
        }
        row.saveButton.isEnabled = false
        row.message(L10n.text("Verifying…"))
        let finish: (Result<Void, SettingsValidation.Failure>) -> Void = { [weak self, weak row] result in
            guard let self, let row else { completion(false); return }
            guard row.generation == generation, row.value == value else { completion(false); return }
            row.task = nil; row.saveButton.isEnabled = true
            guard self.resolved(provider)?.key == credentialBefore,
                  self.app?.endpoint.stringValue == originalASR,
                  DeepSeekConfiguration.endpoint(for: provider) == providerEndpointBefore else {
                row.message(L10n.text("Connection settings changed during verification. Please verify again."), error: true)
                completion(false); return
            }
            switch result {
            case .failure(let error):
                let message = error.message
                row.message(message, error: true)
                self.stamp(row, value: value, status: error == .rejected ? L10n.text("Key rejected") : L10n.text("Verification failed"))
                self.refreshProvider()
                completion(false)
            case .success:
                var saved = true
                if kind == "key" {
                    let previous = self.resolved(provider)
                    // An unchanged external credential is never copied into the application file.
                    if value != previous?.key {
                        if self.preview { self.previewKeys[provider] = ResolvedCredential(key: value, source: .app) }
                        else { saved = PolishCredentials.save(value, for: provider) }
                    }
                } else if row.id == "asr.endpoint" {
                    self.defaults.set(value, forKey: "asrEndpoint")
                    self.defaults.removeObject(forKey: "bailian.detectedRegion")
                    self.defaults.set(ASRConfiguration.model, forKey: "asrModel")
                    self.app?.endpoint.stringValue = value
                    if let host = URL(string: value)?.host {
                        self.defaults.set(BailianAddress.polish(host), forKey: PolishProvider.bailian.endpointKey)
                    }
                } else {
                    self.defaults.set(value, forKey: kind == "model" ? provider.modelKey : provider.endpointKey)
                }
                guard saved else { row.message(L10n.text("Cannot write to the iMic configuration file."), error: true); completion(false); return }
                row.markSaved(value); row.hideKey()
                row.message(L10n.text("✓ Saved · %@", L10n.argument(L10n.time(Date()))))
                self.stamp(row, value: value, status: L10n.text("Verified"))
                if row.id == "bailian.key", !self.preview { VerifiedKeyMemory.remember(value) }
                self.configurationChanged(); completion(true)
            }
        }
        if preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                finish(value.contains("bad") ? .failure(.rejected) : .success(()))
            }
        } else {
            if let (key, address) = bailianCheck {
                row.task = SettingsValidation.runBailian(key: key, endpoint: address, completion: finish)
            } else { row.task = SettingsValidation.run(request, completion: finish) }
        }
    }
    private func saveBailian(_ row: SettingsField, completion: @escaping (Bool) -> Void) {
        let value = row.value, generation = row.generation
        let credential = resolved(.bailian)
        let originalEndpoint = app!.endpoint.stringValue
        let key = row.id == "bailian.key" ? value : fields["bailian.key"]?.value ?? credential?.key ?? ""
        let base = bailianAdvanced?.isHidden == false ? fields["bailian.base"]?.value ?? "" : ""
        let keyDraft = fields["bailian.key"]?.value
        let baseDraft = fields["bailian.base"]?.value
        let wasAdvanced = bailianAdvanced?.isHidden
        row.saveButton.isEnabled = false; row.message(L10n.text("Detecting region…")); resize()
        let finish: (Result<BailianDiscovery.Selection, BailianIssue>) -> Void = { [weak self, weak row] result in
            guard let self, let row, row.generation == generation, row.value == value else { completion(false); return }
            row.discovery = nil; row.saveButton.isEnabled = true
            guard self.resolved(.bailian) == credential, self.app?.endpoint.stringValue == originalEndpoint,
                  self.fields["bailian.key"]?.value == keyDraft, self.fields["bailian.base"]?.value == baseDraft,
                  self.bailianAdvanced?.isHidden == wasAdvanced else {
                row.message(L10n.text("Connection settings changed during verification. Please verify again."), error: true); completion(false); return
            }
            switch result {
            case .failure(let issue):
                row.message(issue.message, error: true)
                self.stamp(row, value: value, status: L10n.text("Verification failed"))
                self.resize(); completion(false)
            case .success(let selection):
                if key != credential?.key {
                    if self.preview { self.previewKeys[.bailian] = ResolvedCredential(key: key, source: .app) }
                    else if !PolishCredentials.save(key, for: .bailian) {
                        row.message(L10n.text("Cannot write to the iMic configuration file."), error: true); completion(false); return
                    }
                }
                selection.apply(self.defaults)
                self.app?.endpoint.stringValue = BailianAddress.asr(selection.host)
                row.markSaved(value); row.hideKey(); row.message(selection.message)
                if row.id == "bailian.base" { self.fields["bailian.key"]?.markSaved(key) }
                self.stamp(row, value: value, status: L10n.text("Verified · %@", L10n.argument(selection.region)))
                self.configurationChanged(); completion(true)
            }
        }
        if preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                finish(key.contains("bad") ? .failure(.invalidKey) : .success(.init(host: BailianAddress.hosts[0], asrListed: false, polishListed: true)))
            }
        } else {
            row.discovery = BailianDiscovery.start(key: key, baseURL: base, progress: { [weak self, weak row] text in
                guard let row, row.generation == generation else { return }
                row.message(text); self?.resize()
            }, completion: finish)
        }
    }
    private func stamp(_ row: SettingsField, value: String, status: String) {
        let prefix = "settings.validation.\(row.id)."
        defaults.set(VerifiedKeyMemory.digest(value), forKey: prefix + "digest")
        defaults.set(Date(), forKey: prefix + "date")
        let code = status.hasPrefix(L10n.text("Verified")) ? "verified" : (status == L10n.text("Key rejected") ? "rejected" : "failed")
        defaults.set(code, forKey: prefix + "status")
    }
    private func configurationChanged() {
        guard let app else { return }
        app.key.stringValue = resolved(.bailian)?.key ?? ""
        app.deepseekCheck.state = DeepSeekConfiguration.enabled ? .on : .off
        app.polishFields?.isHidden = !DeepSeekConfiguration.enabled
        app.sendCurrentFeatureSettings()
        refreshCredentials(); app.refreshUI(); resize()
    }

    func showServiceError(_ message: String) {
        providerWarning.stringValue = message
        providerWarning.isHidden = false
    }

    func refreshPermissions() {
        guard accessStatus != nil else { return }
        app?.refreshInputPermission(); app?.refreshStatusMenu()
        let access = preview || app?.inputAllowed() == true
        let capture = !preview && CGPreflightScreenCaptureAccess()
        let ble = !preview && CBManager.authorization == .allowedAlways
        for (field, allowed) in [(accessStatus, access), (screenStatus, capture), (bluetoothStatus, ble)] {
            field?.stringValue = allowed ? "●" : "○"
            field?.textColor = allowed ? .imicOrange : .imicMuted
            field?.setAccessibilityLabel(allowed ? L10n.text("Allowed") : L10n.text("Not allowed yet"))
        }
    }
    @objc private func openAccessibility() { open(SetupLinks.accessibility) }
    @objc private func openScreenRecording() { open(SetupLinks.screenCapture) }
    @objc private func openBluetoothPrivacy() {
        open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
    }
    private func open(_ url: URL) { if !preview { NSWorkspace.shared.open(url) } }
    @objc private func showPairCode() {
        guard let stack = stacks[.iphone], let label = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "settingsPairCode" }) as? NSTextField else { return }
        label.stringValue = L10n.text("Pairing code: %@", PairingCode.formatted(app!.store.currentCode())); label.isHidden = false; resize()
    }
    func refreshPairCode() {
        (stacks[.iphone]?.arrangedSubviews.first(where: { $0.identifier?.rawValue == "settingsPairCode" }) as? NSTextField)?.stringValue = L10n.text("Pairing code: %@", PairingCode.formatted(app!.store.currentCode()))
    }
    @objc private func toggleShowMain(_ sender: NSButton) { defaults.set(sender.state == .on, forKey: "showMainWindowOnLaunch") }
    func refreshLoginState() {
        guard loginCheck != nil else { return }
        loginSettingsButton.isHidden = true
        guard !preview, SetupLocation.classify(PermissionApplication.current) == .applications else {
            loginCheck.isEnabled = false; loginCheck.state = .off
            loginHint.stringValue = L10n.text("Set up launch at login from the iMic app in Applications.")
            return
        }
        loginCheck.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            loginCheck.state = .on; loginHint.stringValue = L10n.text("Starts in the menu bar when you log in to your Mac.")
        case .requiresApproval:
            loginCheck.state = .on
            loginHint.stringValue = L10n.text("Allow iMic in System Settings → General → Login Items.")
            loginSettingsButton.isHidden = false
        case .notRegistered:
            loginCheck.state = .off; loginHint.stringValue = L10n.text("Will not start automatically when you log in to your Mac.")
        case .notFound:
            loginCheck.state = .off; loginCheck.isEnabled = false
            loginHint.stringValue = L10n.text("macOS could not find this app's login item. Reopen iMic from Applications.")
        @unknown default:
            loginCheck.state = .off; loginCheck.isEnabled = false
            loginHint.stringValue = L10n.text("Cannot read the login item status.")
        }
    }
    @objc private func toggleLogin() {
        guard !preview, SetupLocation.classify(PermissionApplication.current) == .applications else { refreshLoginState(); return }
        let enable = loginCheck.state == .on
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginHint.stringValue = L10n.text("Could not change the login item. Check System Settings and the app signature.")
            loginSettingsButton.isHidden = false
            IMicLog.write("mac.settings", "login_item_failed code=\((error as NSError).code)")
        }
        resize()
    }
    @objc private func openLoginSettings() {
        guard !preview else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let dirty = fields.values.filter(\.dirty).sorted {
            let firstKey = $0.id.hasSuffix(".key"), secondKey = $1.id.hasSuffix(".key")
            return firstKey == secondKey ? $0.id < $1.id : firstKey
        }
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? (dirty[0].id == "bailian.key" ? L10n.text("Your Model Studio Key has not been saved.") : L10n.text("%@ has not been saved.", L10n.argument(dirty[0].title))) : L10n.text("%@ settings have not been saved.", L10n.argument(dirty.count))
        alert.informativeText = L10n.text("Settings are verified before saving. Drafts are kept if verification fails.")
        for title in [L10n.text("Save"), L10n.text("Discard"), L10n.text("Cancel")] { alert.addButton(withTitle: title) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveSequentially(dirty, index: 0) { saved in
                    if saved { self.window.close() }
                }
            case .alertSecondButtonReturn:
                for row in dirty { row.reset() }
                self.window.close()
            default: break
            }
        }
        return false
    }
    private func saveSequentially(_ rows: [SettingsField], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < rows.count else { completion(true); return }
        let row = rows[index]
        if let provider = PolishProvider(rawValue: row.id.split(separator: ".").first.map(String.init) ?? ""), provider != .bailian {
            select(.advanced)
            app?.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: provider)!)
            // Saving a draft must not change the active provider implicitly.
            for (source, view) in profiles { view.isHidden = source != provider }
        } else { select(row.id == "bailian.key" ? .bailian : .advanced) }
        row.save { [weak self] success in
            if success { self?.saveSequentially(rows, index: index + 1, completion: completion) }
            else { completion(false) }
        }
    }
    func windowWillClose(_ notification: Notification) {
        for row in fields.values { row.cancel(); row.hideKey() }
    }
}

extension AppDelegate {
    func buildSettings() {
        let coordinator = SettingsWindowCoordinator(app: self)
        settingsCoordinator = coordinator; settingsWindow = coordinator.window
    }
    func sendCurrentFeatureSettings() { sendFeatureSettings() }
}

extension AppDelegate {
    func constrainWrappingLabels(in view: NSView, width: CGFloat) {
        for child in view.subviews {
            if let field = child as? NSTextField, !field.isEditable, field.maximumNumberOfLines != 1 {
                field.preferredMaxLayoutWidth = width
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            constrainWrappingLabels(in: child, width: width)
        }
    }

    func rebuildPairedList() {
        guard pairedList != nil else { return }
        for view in pairedList.arrangedSubviews {
            pairedList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let devices = store.devices
        if devices.isEmpty {
            let empty = label(L10n.text("No iPhone paired yet"), size: 12, color: .imicMuted)
            pairedList.addArrangedSubview(empty)
            fullWidth(empty, in: pairedList)
            return
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        for device in devices {
            let name = label(device.name, size: 13, color: .imicIvory)
            let date = label(L10n.text("Paired on %@", L10n.argument(formatter.string(from: device.pairedAt))), size: 10, color: .imicMuted, mono: true)
            let text = column([name, date], spacing: 2)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let remove = linkButton(L10n.text("Forget##ccdebb93"), #selector(forgetDevice(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(device.id)
            let row = row([text, spacer, remove], spacing: 10)
            pairedList.addArrangedSubview(row)
            fullWidth(row, in: pairedList)
        }
    }
}
