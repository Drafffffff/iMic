import AppKit
import ServiceManagement
import ApplicationServices
import CoreBluetooth
import CryptoKit

// The tab bar is owned by AppKit, with keyboard shortcuts handled by the window.
enum SettingsPane: String, CaseIterable {
    case general, bailian, iphone, permissions, advanced
    var title: String { ["通用", "百炼", "iPhone", "权限", "高级"][Self.allCases.firstIndex(of: self)!] }
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
    private let activeProvider = NSTextField(wrappingLabelWithString: "")
    private var accessStatus: NSTextField!
    private var screenStatus: NSTextField!
    private var bluetoothStatus: NSTextField!
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
        window.title = "iMic 设置"; window.isReleasedWhenClosed = false
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
        if pane == .general { refreshLoginState() }
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
    func show() { refreshCredentials(); refreshPermissions(); refreshLoginState(); resize() }

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
        app.automatic.title = "识别后自动输入到当前应用"
        app.automatic.target = app; app.automatic.action = #selector(AppDelegate.toggleAutoInput)
        app.automatic.contentTintColor = nil; app.automatic.setAccessibilityLabel(app.automatic.title)
        app.livePreviewCheck = app.checkbox("实时预览与逐字输入", #selector(AppDelegate.toggleLivePreview), key: "livePreview", defaultValue: true)
        let input = column([app.automatic, app.livePreviewCheck,
            note("部分编辑器使用键盘兼容模式，可能重复或误删。按键、点击或切换应用后停止本轮自动修订。")], spacing: 9)
        loginCheck = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin))
        loginCheck.setAccessibilityLabel(loginCheck.title)
        loginHint = note("")
        loginSettingsButton = action("打开登录项设置…", #selector(openLoginSettings))
        loginSettingsButton.isHidden = true
        let show = NSButton(checkboxWithTitle: "启动时显示主窗口", target: self, action: #selector(toggleShowMain(_:)))
        show.state = defaults.bool(forKey: "showMainWindowOnLaunch") ? .on : .off
        show.setAccessibilityLabel(show.title)
        app.saveFeedback.font = .systemFont(ofSize: 11); app.saveFeedback.textColor = .imicMuted
        return column([heading("INPUT"), input, app.divider(), heading("STARTUP"),
            loginCheck, loginHint, loginSettingsButton, show, app.divider(), app.linkButton("测试输入", #selector(AppDelegate.testInput)), app.saveFeedback])
    }
    private func bailian() -> NSStackView {
        let app = app!
        let key = field("bailian.key", "百炼 API Key", resolved(.bailian)?.key ?? "", secure: true)
        let override = action("改用 iMic 保存的 Key", #selector(overrideBailianKey))
        override.identifier = NSUserInterfaceItemIdentifier("overrideBailianKey")
        override.isHidden = resolved(.bailian)?.source.isExternal != true
        app.deepseekCheck = app.checkbox("启用 AI 润色与转换", #selector(AppDelegate.toggleDeepSeek), key: "deepseekEnabled", defaultValue: DeepSeekConfiguration.enabled)
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
        app.polishModeButtons.setAccessibilityLabel("转换模式")
        app.polishToneButtons.setAccessibilityLabel("表达语气")
        app.polishModeButtons.selectedSegment = PolishMode.allCases.firstIndex(of: options.mode) ?? 0
        app.polishToneButtons.selectedSegment = PolishTone.allCases.firstIndex(of: options.tone) ?? 0
        app.polishOutputPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        app.polishOutputPicker.addItems(withTitles: PolishOutput.languages.map(\.title))
        app.polishOutputPicker.selectItem(at: PolishOutput.languages.firstIndex(of: options.output) ?? 0)
        app.polishOutputPicker.target = app; app.polishOutputPicker.action = #selector(AppDelegate.changePolishOutput(_:))
        app.polishOutputPicker.setAccessibilityLabel("输出语言")
        app.polishModeHint = note(""); app.polishToneHint = note(""); app.polishOptionsHint = note("")
        app.updatePolishOptionControls(options)
        let choices = column([heading("MODE"), app.polishModeButtons, app.polishModeHint,
            heading("TONE"), app.polishToneButtons, app.polishToneHint,
            heading("LANGUAGE"), app.polishOutputPicker, app.polishOptionsHint], spacing: 7)
        app.polishFields = choices; choices.isHidden = !DeepSeekConfiguration.enabled
        activeProvider.font = .systemFont(ofSize: 11); activeProvider.textColor = .imicMuted
        return column([note("一个百炼 Key 同时用于语音识别和 AI 润色。"), key, override,
            app.linkButton("获取百炼 Key ↗", #selector(AppDelegate.openBailianConsole)), app.divider(),
            heading("AI POLISH"), activeProvider, app.deepseekCheck, choices], spacing: 12)
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
        let code = note("配对码：\(app.store.currentCode())")
        code.identifier = NSUserInterfaceItemIdentifier("settingsPairCode"); code.isHidden = true
        let pair = action("配对新 iPhone", #selector(showPairCode))
        let actions = app.row([app.linkButton("复制配对码", #selector(AppDelegate.copyPairCode)),
            app.linkButton("重新生成", #selector(AppDelegate.rotatePairCode)), app.linkButton("解除全部配对", #selector(AppDelegate.forgetAllDevices))], spacing: 14)
        app.snapReturnCheck = app.checkbox("下拉回弹发送回车", #selector(AppDelegate.toggleSnapReturn), key: "snapReturn", defaultValue: true)
        app.pullDeleteCheck = app.checkbox("上拉删除", #selector(AppDelegate.togglePullDelete), key: "pullDelete", defaultValue: true)
        app.swipeCursorCheck = app.checkbox("左右滑动移动光标", #selector(AppDelegate.toggleSwipeCursor), key: "swipeCursor", defaultValue: true)
        app.bleFallbackCheck = app.checkbox("局域网不可用时启用蓝牙兜底", #selector(AppDelegate.toggleBLEFallback), key: "bleFallback", defaultValue: true)
        return column([heading("PAIRED DEVICES"), devices, pair, code, actions, app.divider(), heading("STRING GESTURES"),
            app.snapReturnCheck, app.pullDeleteCheck, app.swipeCursorCheck, app.divider(), heading("CONNECTION"),
            app.bleFallbackCheck, note("蓝牙带宽较低，长录音可能需要补传。"), app.linkButton("打开蓝牙设置…", #selector(AppDelegate.openBluetoothSettings))], spacing: 10)
    }
    private func permissionRow(_ title: String, _ detail: String, _ selector: Selector) -> (NSView, NSTextField) {
        let status = note("○"); status.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let text = column([app!.label(title, size: 12, color: .imicIvory), note(detail)], spacing: 4)
        let button = action("打开设置…", selector); button.setAccessibilityLabel("打开\(title)设置")
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
        let access = permissionRow("辅助功能", "必需 · 把识别文字输入到当前应用。", #selector(openAccessibility))
        let screen = permissionRow("屏幕录制", "可选 · 扫光定位，仅在本机处理。", #selector(openScreenRecording))
        let bluetooth = permissionRow("蓝牙", "可选 · 局域网不可用时兜底连接。", #selector(openBluetoothPrivacy))
        accessStatus = access.1; screenStatus = screen.1; bluetoothStatus = bluetooth.1
        app.polishSweepCheck = app.checkbox("润色完成时扫光", #selector(AppDelegate.togglePolishSweep), key: "polishSweep", defaultValue: true)
        app.polishSweepHint = note("需要 macOS 14+ 与屏幕录制权限。仅本机定位文字，不保存截图；定位失败仍正常输入。")
        return column([heading("PERMISSIONS"), access.0, screen.0, bluetooth.0, app.divider(), heading("POLISH SWEEP"), app.polishSweepCheck, app.polishSweepHint], spacing: 18)
    }
    private func advanced() -> NSStackView {
        let app = app!
        app.polishProviderPicker.removeAllItems()
        app.polishProviderPicker.addItems(withTitles: PolishProvider.allCases.map(\.title))
        app.polishProviderPicker.selectItem(at: PolishProvider.allCases.firstIndex(of: DeepSeekConfiguration.provider) ?? 0)
        app.polishProviderPicker.target = self; app.polishProviderPicker.action = #selector(changeProvider)
        app.polishProviderPicker.setAccessibilityLabel("润色服务来源")
        providerWarning.font = .systemFont(ofSize: 11); providerWarning.textColor = .systemOrange
        providerWarning.preferredMaxLayoutWidth = 512
        profileSlot.orientation = .vertical; profileSlot.alignment = .leading; profileSlot.detachesHiddenViews = true
        for provider in PolishProvider.allCases {
            var views: [NSView] = []
            if provider != .bailian {
                views.append(field("\(provider.rawValue).key", "\(provider.title) Key", resolved(provider)?.key ?? "", secure: true))
                let override = action("改用 iMic 保存的 Key", #selector(overrideServiceKey(_:)))
                override.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
                override.isHidden = resolved(provider)?.source.isExternal != true
                views.append(override)
            }
            views.append(field("\(provider.rawValue).model", "模型", DeepSeekConfiguration.modelName(for: provider)))
            views.append(field("\(provider.rawValue).endpoint", "Chat Completions 地址", DeepSeekConfiguration.endpoint(for: provider)))
            if provider == .bailian { views.append(note("模型在百炼上运行；地址与 Key 的地域或业务空间须匹配。")) }
            let group = column(views, spacing: 10); profiles[provider] = group
            profileSlot.addArrangedSubview(group); app.fullWidth(group, in: profileSlot)
        }
        let fixed = app.label(ASRConfiguration.model, size: 11, color: .imicIvory, mono: true)
        fixed.isSelectable = true; fixed.setAccessibilityLabel("识别模型（只读）")
        return column([heading("POLISH SERVICE"), app.polishProviderPicker, providerWarning, profileSlot,
            app.divider(), heading("RECOGNITION"), fixed,
            field("asr.endpoint", "识别服务地址", app.endpoint.stringValue),
            note("只支持百炼推理地址，须与 Key 的地域或业务空间一致。"),
            app.divider(), app.linkButton("重新打开设置向导…", #selector(AppDelegate.showSetupAction))], spacing: 10)
    }

    private var previewKeys: [PolishProvider: ResolvedCredential] = [
        .bailian: ResolvedCredential(key: "sk-preview-bailian-credential", source: .app)
    ]
    private func resolved(_ provider: PolishProvider) -> ResolvedCredential? {
        preview ? previewKeys[provider] : PolishCredentials.resolve(for: provider)
    }
    func refreshCredentials() {
        for provider in PolishProvider.allCases {
            guard let row = fields["\(provider.rawValue).key"] else { continue }
            let credential = resolved(provider)
            if !row.dirty {
                if row.value != credential?.key ?? "" { row.markSaved(credential?.key ?? "") }
                row.setEditable(credential?.source.isExternal != true)
            }
            row.source.isHidden = false
            row.source.stringValue = credential.map { "来源：\($0.source.tag) · iMic 配置优先于环境变量和 shell 文件。" } ?? "尚未配置 Key。"
        }
        for row in fields.values where !row.dirty && row.feedback.stringValue.isEmpty {
            let prefix = "settings.validation.\(row.id)."
            if defaults.string(forKey: prefix + "digest") == VerifiedKeyMemory.digest(row.value),
               let date = defaults.object(forKey: prefix + "date") as? Date,
               let status = defaults.string(forKey: prefix + "status") {
                row.message("\(status) · \(date.formatted(date: .abbreviated, time: .shortened))", error: status != "已验证")
            }
        }
        refreshProvider()
    }
    private func refreshProvider() {
        let provider = DeepSeekConfiguration.provider
        for (source, group) in profiles { group.isHidden = source != provider }
        activeProvider.stringValue = provider == .bailian ? "" : "当前润色使用：\(provider.title) · 在「高级」中更改"
        activeProvider.isHidden = provider == .bailian
        let credential = resolved(provider)
        let prefix = "settings.validation.\(provider.rawValue).key."
        let rejected = credential.map {
            defaults.string(forKey: prefix + "digest") == VerifiedKeyMemory.digest($0.key)
                && defaults.string(forKey: prefix + "status") == "Key 被拒绝"
        } ?? false
        providerWarning.stringValue = credential == nil || rejected ? "此来源缺少有效 Key，润色将保留原文。" : ""
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
        fields["\(id).key"]?.message("保存后将优先使用 iMic 中的 Key。")
        sender.isHidden = true
    }
    @objc private func overrideBailianKey(_ sender: NSButton) {
        fields["bailian.key"]?.setEditable(true)
        fields["bailian.key"]?.message("保存后将优先使用 iMic 中的 Key。")
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
                row.message("请填写有效的 API Key。", error: true); completion(false); return
            }
            let saved = preview || PolishCredentials.save("", for: provider)
            if saved {
                if preview { previewKeys.removeValue(forKey: provider) }
                row.markSaved(resolved(provider)?.key ?? "")
                row.message("已移除 iMic 中保存的 Key。")
                configurationChanged()
            } else { row.message("无法写入 iMic 配置文件。", error: true) }
            completion(saved); return
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
            row.message((error as? PolishConfigurationError)?.rawValue ?? "请检查配置。", error: true)
            completion(false); return
        }
        row.saveButton.isEnabled = false
        row.message("验证中…")
        let finish: (Result<Void, SettingsValidation.Failure>) -> Void = { [weak self, weak row] result in
            guard let self, let row else { completion(false); return }
            guard row.generation == generation, row.value == value else { completion(false); return }
            row.task = nil; row.saveButton.isEnabled = true
            guard self.resolved(provider)?.key == credentialBefore,
                  self.app?.endpoint.stringValue == originalASR,
                  DeepSeekConfiguration.endpoint(for: provider) == providerEndpointBefore else {
                row.message("验证期间连接配置已更改，请重新验证。", error: true)
                completion(false); return
            }
            switch result {
            case .failure(let error):
                let message = error == .rejected && provider == .bailian ? "百炼拒绝了这个 Key，请检查 Key 与地域。" : error.message
                row.message(message, error: true)
                self.stamp(row, value: value, status: error == .rejected ? "Key 被拒绝" : "验证失败")
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
                    self.defaults.set(ASRConfiguration.model, forKey: "asrModel")
                    self.app?.endpoint.stringValue = value
                } else {
                    self.defaults.set(value, forKey: kind == "model" ? provider.modelKey : provider.endpointKey)
                }
                guard saved else { row.message("无法写入 iMic 配置文件。", error: true); completion(false); return }
                row.markSaved(value); row.hideKey()
                row.message("✓ 已保存 · \(Date().formatted(date: .omitted, time: .shortened))")
                self.stamp(row, value: value, status: "已验证")
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
    private func stamp(_ row: SettingsField, value: String, status: String) {
        let prefix = "settings.validation.\(row.id)."
        defaults.set(VerifiedKeyMemory.digest(value), forKey: prefix + "digest")
        defaults.set(Date(), forKey: prefix + "date")
        defaults.set(status, forKey: prefix + "status")
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
            field?.setAccessibilityLabel(allowed ? "已允许" : "尚未允许")
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
        label.stringValue = "配对码：\(PairingCode.formatted(app!.store.currentCode()))"; label.isHidden = false; resize()
    }
    func refreshPairCode() {
        (stacks[.iphone]?.arrangedSubviews.first(where: { $0.identifier?.rawValue == "settingsPairCode" }) as? NSTextField)?.stringValue = "配对码：\(PairingCode.formatted(app!.store.currentCode()))"
    }
    @objc private func toggleShowMain(_ sender: NSButton) { defaults.set(sender.state == .on, forKey: "showMainWindowOnLaunch") }
    func refreshLoginState() {
        guard loginCheck != nil else { return }
        loginSettingsButton.isHidden = true
        guard !preview, SetupLocation.classify(PermissionApplication.current) == .applications else {
            loginCheck.isEnabled = false; loginCheck.state = .off
            loginHint.stringValue = "请从「应用程序」里的 iMic 设置登录时启动。"
            return
        }
        loginCheck.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            loginCheck.state = .on; loginHint.stringValue = "登录 Mac 后在菜单栏启动。"
        case .requiresApproval:
            loginCheck.state = .on
            loginHint.stringValue = "需要在「系统设置 → 通用 → 登录项」中允许。"
            loginSettingsButton.isHidden = false
        case .notRegistered:
            loginCheck.state = .off; loginHint.stringValue = "关闭时不会在登录 Mac 后自动启动。"
        case .notFound:
            loginCheck.state = .off; loginCheck.isEnabled = false
            loginHint.stringValue = "系统未找到此应用的登录项，请从「应用程序」重新打开 iMic。"
        @unknown default:
            loginCheck.state = .off; loginCheck.isEnabled = false
            loginHint.stringValue = "无法读取系统登录项状态。"
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
            loginHint.stringValue = "登录项设置失败，请检查系统登录项与应用签名。"
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
        alert.messageText = dirty.count == 1 ? (dirty[0].id == "bailian.key" ? "百炼 Key 尚未保存。" : "\(dirty[0].title)尚未保存。") : "还有 \(dirty.count) 项配置尚未保存。"
        alert.informativeText = "保存前会先验证；验证失败时保留草稿。"
        for title in ["保存", "放弃", "取消"] { alert.addButton(withTitle: title) }
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
            let empty = label("尚未配对 iPhone", size: 12, color: .imicMuted)
            pairedList.addArrangedSubview(empty)
            fullWidth(empty, in: pairedList)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日"
        for device in devices {
            let name = label(device.name, size: 13, color: .imicIvory)
            let date = label("配对于 \(formatter.string(from: device.pairedAt))", size: 10, color: .imicMuted, mono: true)
            let text = column([name, date], spacing: 2)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let remove = linkButton("解除", #selector(forgetDevice(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(device.id)
            let row = row([text, spacer, remove], spacing: 10)
            pairedList.addArrangedSubview(row)
            fullWidth(row, in: pairedList)
        }
    }
}
