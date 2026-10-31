import AppKit
import CryptoKit

/// Where the running bundle lives. Accessibility approval is bound to this path.
enum SetupLocation: Equatable {
    case applications
    /// Gatekeeper runs quarantined apps from a random read-only copy; approval would not survive a relaunch.
    case translocated
    case elsewhere

    static func classify(_ url: URL?) -> SetupLocation {
        guard let path = url?.standardizedFileURL.path else { return .elsewhere }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return .translocated }
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if path.hasPrefix("/Applications/") || path.hasPrefix(user + "/") { return .applications }
        return .elsewhere
    }
}

struct SetupSnapshot {
    var key: ResolvedCredential?
    var permission: InputPermissionState
    var screenCapture: Bool
    var location: SetupLocation
    var applicationURL: URL?
    var asrEndpoint: String
}

protocol SetupWizardHost: AnyObject {
    var setupPreview: Bool { get }
    func setupSnapshot() -> SetupSnapshot
    /// Stores a pasted key in iMic's own file and starts using it.
    func setupSaveKey(_ key: String) -> Bool
    /// Uses a key found in the environment or shell files without copying it.
    func setupUseKey(_ credential: ResolvedCredential)
    func setupApplyService(_ selection: BailianDiscovery.Selection)
    func setupRequestAccessibility()
    func setupRequestScreenCapture()
    func setupFinished(polishEnabled: Bool)
}

/// The key comes first: it never needs a relaunch. Permissions come last because granting
/// Screen Recording can make macOS ask to quit and reopen iMic.
enum SetupStep: Int, CaseIterable {
    case key, permissions
    var tag: String { self == .key ? "01 API KEY" : "02 PERMISSIONS" }

    /// Where a fresh opening starts when no step was saved.
    static func first(for snapshot: SetupSnapshot) -> SetupStep {
        snapshot.key != nil && !snapshot.permission.allowed ? .permissions : .key
    }

    static func complete(_ step: SetupStep, _ snapshot: SetupSnapshot) -> Bool {
        step == .permissions ? snapshot.permission.allowed : snapshot.key != nil
    }
}

/// The wizard's position survives a relaunch until the user presses 完成.
enum SetupProgress {
    static let stepKey = "setup.inProgressStep"
    static func saved(_ defaults: UserDefaults = MacPreferences.defaults) -> SetupStep? {
        (defaults.object(forKey: stepKey) as? Int).flatMap(SetupStep.init(rawValue:))
    }
    static func save(_ step: SetupStep, _ defaults: UserDefaults = MacPreferences.defaults) {
        defaults.set(step.rawValue, forKey: stepKey)
    }
    static func clear(_ defaults: UserDefaults = MacPreferences.defaults) {
        defaults.removeObject(forKey: stepKey)
    }
}

enum SetupLaunchPolicy {
    enum Decision: Equatable { case show, skip, skipAndMarkComplete }

    /// A wizard that was started but not finished always comes back, even when a key from
    /// the shell and an earlier permission grant would otherwise look like a finished setup.
    /// Only installs that never opened this wizard are treated as already set up.
    static func decide(keyPresent: Bool, completedVersion: Int, currentVersion: Int,
                       inProgress: Bool, inputAllowed: Bool) -> Decision {
        if !keyPresent { return .show }
        if completedVersion >= currentVersion { return .skip }
        if inProgress { return .show }
        return inputAllowed ? .skipAndMarkComplete : .show
    }
}

enum SetupLinks {
    static let website = URL(string: "https://drafffffff.github.io/iMic/")!
    static let bailianKeys = URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenCapture = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Remembers which key already passed the online check, without storing the key itself.
enum VerifiedKeyMemory {
    private static let defaultsKey = "setup.verifiedKeyDigest"
    static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func isVerified(_ key: String, defaults: UserDefaults = MacPreferences.defaults) -> Bool {
        defaults.string(forKey: defaultsKey) == digest(key)
    }
    static func remember(_ key: String, defaults: UserDefaults = MacPreferences.defaults) {
        defaults.set(digest(key), forKey: defaultsKey)
    }
}

/// Two steps only: paste a Bailian key, then grant permissions. Everything else lives in Settings.
final class SetupWizard: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let completedKey = "setup.completedVersion"
    static let version = 1

    private enum KeyState: Equatable { case idle, checking, valid, rejected, offline, format }

    private weak var host: SetupWizardHost?
    private(set) var step: SetupStep = .key
    private var snapshot: SetupSnapshot

    private var stepLabels: [NSTextField] = []
    private var stepBars: [NSView] = []
    private let body = NSView()
    private var current: NSView?
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)

    // Permissions
    private var accessibilityRow: PermissionRow?
    private var screenRow: PermissionRow?
    private var staleHelp: NSView?
    private var staleToggle: NSButton?
    private var requestedAt: Date?
    private var screenRequested = false
    private var lastAllowed = false

    // Key
    private let keyField = NSSecureTextField()
    private let keyMessage = NSTextField(wrappingLabelWithString: "")
    private var keyState = KeyState.idle
    private var keyTask: BailianDiscovery?
    private var keyGeneration = UUID()
    private var debounce: DispatchWorkItem?
    private var validationMessage = ""
    private var selection: BailianDiscovery.Selection?
    private let baseField = NSTextField()
    private let advanced = NSStackView()
    private let consoleHelp = NSButton(title: "打开百炼控制台 ↗", target: nil, action: nil)
    private var checkedKey = ""
    private let polishCheck = NSButton(checkboxWithTitle: "同时启用 AI 润色（推荐）", target: nil, action: nil)

    init(host: SetupWizardHost) {
        self.host = host
        snapshot = host.setupSnapshot()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "设置 iMic"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .imicInk
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        polishCheck.state = .on
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Public

    /// Called on every permission tick.
    func refresh() {
        guard let host = host, window?.isVisible == true else { return }
        snapshot = host.setupSnapshot()
        let allowed = snapshot.permission.allowed
        defer { lastAllowed = allowed }
        updateStepper()
        guard step == .permissions else { return }
        updatePermissions()
        if allowed && !lastAllowed {
            // Come back from System Settings on our own once approval lands; 完成 is now enabled.
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func reopen(at requested: SetupStep? = nil) {
        guard let host = host else { return }
        snapshot = host.setupSnapshot()
        lastAllowed = snapshot.permission.allowed
        show(requested ?? SetupProgress.saved() ?? SetupStep.first(for: snapshot))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func build() {
        guard let window = window else { return }
        let content = InkView()
        window.contentView = content

        let logo = NSImageView(image: MicBrand.logo(size: 20))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 20).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let stepper = NSStackView()
        stepper.orientation = .horizontal
        stepper.distribution = .fillEqually
        stepper.spacing = 8
        for _ in SetupStep.allCases {
            let label = NSTextField(labelWithString: "")
            let bar = NSView()
            bar.wantsLayer = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 2).isActive = true
            let cell = Self.column([label, bar], spacing: 6)
            bar.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            stepper.addArrangedSubview(cell)
            stepLabels.append(label)
            stepBars.append(bar)
        }
        let header = Self.row([logo, stepper], spacing: 16)

        body.translatesAutoresizingMaskIntoConstraints = false

        secondary.target = self
        secondary.action = #selector(secondaryAction)
        secondary.isBordered = false
        secondary.contentTintColor = .imicMuted
        secondary.font = .systemFont(ofSize: 12)
        primary.target = self
        primary.action = #selector(primaryAction)
        primary.bezelStyle = .rounded
        primary.bezelColor = .imicOrange
        primary.keyEquivalent = "\r"
        primary.controlSize = .large
        let footer = Self.row([secondary, NSView(), primary], spacing: 12)

        let stack = Self.column([header, body, footer], spacing: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        for view in [header, body, footer] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stepper.setContentHuggingPriority(.init(1), for: .horizontal)
        body.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func show(_ next: SetupStep) {
        if next != .key { keyTask?.cancel(); keyTask = nil; debounce?.cancel(); keyGeneration = UUID() }
        window?.setContentSize(NSSize(width: next == .key ? 640 : 480, height: next == .key ? 650 : 420))
        step = next
        SetupProgress.save(next)
        current?.removeFromSuperview()
        let view = next == .permissions ? buildPermissions() : buildKey()
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
        ])
        current = view
        updateStepper()
        if next == .permissions { updatePermissions() } else { updateKey() }
    }

    private func updateStepper() {
        for item in SetupStep.allCases {
            let active = item == step
            let done = SetupStep.complete(item, snapshot)
            let color: NSColor = active ? .imicOrange : done ? .imicIvory : .imicMuted
            stepLabels[item.rawValue].attributedStringValue = NSAttributedString(string: item.tag, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: active ? .bold : .medium),
                .foregroundColor: color, .kern: 1.4,
            ])
            stepBars[item.rawValue].layer?.backgroundColor = (active ? NSColor.imicOrange
                : done ? NSColor.imicIvory.withAlphaComponent(0.45) : NSColor.imicHairline).cgColor
        }
    }

    private func footer(primary title: String, enabled: Bool, secondary skip: String?) {
        primary.title = title
        primary.setAccessibilityLabel(title)
        primary.isEnabled = enabled
        secondary.title = skip ?? ""
        secondary.setAccessibilityLabel(skip ?? "")
        secondary.isHidden = skip == nil
    }

    @objc private func primaryAction() {
        switch step {
        case .key:
            if keyState == .valid && keyIsActive { show(.permissions) } else { verifyKey() }
        case .permissions: finish()
        }
    }

    @objc private func secondaryAction() {
        if step == .permissions { show(.key) }
    }

    private func finish() {
        host?.setupFinished(polishEnabled: polishCheck.state == .on)
        close()
    }

    // MARK: - 02 Permissions

    private func buildPermissions() -> NSView {
        var items: [NSView] = [Self.title("允许 iMic 输入文字")]
        if snapshot.location == .translocated {
            let note = Self.text("请先把 iMic 拖到「应用程序」文件夹，再从那里打开，否则授权在下次打开时会失效。")
            note.textColor = .imicIvory
            items += [note, Self.link("在 Finder 中显示 iMic", self, #selector(revealApp))]
            let view = Self.column(items, spacing: 16)
            note.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
            return view
        }
        let accessibility = PermissionRow(
            name: "辅助功能", detail: "把识别好的文字输入到当前应用",
            action: "去开启", target: self, selector: #selector(requestAccessibility))
        let screen = PermissionRow(
            name: "屏幕录制", detail: "可选 · 润色扫光。开启后系统可能要求重新打开 iMic，向导会回到这一步",
            action: "去开启", target: self, selector: #selector(requestScreenCapture))
        accessibilityRow = accessibility
        screenRow = screen

        let toggle = Self.link("已经打开开关，仍未生效？", self, #selector(toggleStale))
        let help = Self.text("在系统设置的列表里选中 iMic，点「−」删除，再回到这里点「去开启」。重新安装或更新后常会遇到。", size: 11)
        help.isHidden = true
        staleHelp = help
        staleToggle = toggle

        items += [accessibility, screen, toggle, help]
        let view = Self.column(items, spacing: 14)
        view.setCustomSpacing(22, after: items[0])
        view.detachesHiddenViews = true
        for item in [accessibility, screen, help] as [NSView] {
            item.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        return view
    }

    private func updatePermissions() {
        guard step == .permissions else { return }
        let allowed = snapshot.permission.allowed
        accessibilityRow?.update(granted: allowed)
        screenRow?.update(granted: snapshot.screenCapture)
        staleToggle?.isHidden = allowed || requestedAt == nil
        if allowed { staleHelp?.isHidden = true }
        if !allowed, let asked = requestedAt, Date().timeIntervalSince(asked) > 15 { staleHelp?.isHidden = false }
        // Accessibility stays optional: without it text is kept in the window for copying.
        footer(primary: allowed ? "完成" : "跳过并完成", enabled: true, secondary: "上一步")
    }

    @objc private func requestAccessibility() {
        guard host?.setupPreview == false else { return }
        // The first click shows the system prompt, which also adds iMic to the list.
        // Later clicks go straight to the list. Approval always stays with the user.
        if requestedAt == nil { host?.setupRequestAccessibility() }
        else { NSWorkspace.shared.open(SetupLinks.accessibility) }
        requestedAt = Date()
        updatePermissions()
    }

    @objc private func requestScreenCapture() {
        guard host?.setupPreview == false else { return }
        if screenRequested { NSWorkspace.shared.open(SetupLinks.screenCapture) }
        else { host?.setupRequestScreenCapture() }
        screenRequested = true
    }

    @objc private func revealApp() {
        guard host?.setupPreview == false, let url = snapshot.applicationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleStale() { staleHelp?.isHidden.toggle() }

    // MARK: - 01 Key

    private var enteredKey: String { ShellCredentials.clean(keyField.stringValue) }
    private var keyIsActive: Bool { !enteredKey.isEmpty && snapshot.key?.key == enteredKey }

    private func buildKey() -> NSView {
        let intro = Self.text("1. 打开百炼控制台，用阿里云账号登录；没有账号请先注册并完成实名认证。")
        let step2 = Self.text("2. 右上角选择「华北2（北京）」（新人免费额度仅此地域提供），创建 API Key，权限选「全部」。")
        let step3 = Self.text("3. 复制 Key，粘贴到下面。")
        let get = NSButton(title: "获取百炼 API Key ↗", target: self, action: #selector(openConsole))
        get.setAccessibilityLabel(get.title)
        get.bezelStyle = .rounded
        get.controlSize = .large

        keyField.placeholderString = "sk-…"
        keyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        keyField.bezelStyle = .roundedBezel
        keyField.delegate = self
        keyField.setAccessibilityLabel("百炼 API Key")
        keyField.heightAnchor.constraint(equalToConstant: 32).isActive = true
        keyField.setContentHuggingPriority(.init(1), for: .horizontal)
        keyField.stringValue = snapshot.key?.key ?? ""
        let paste = NSButton(title: "粘贴", target: self, action: #selector(pasteKey))
        paste.setAccessibilityLabel(paste.title)
        paste.bezelStyle = .rounded
        paste.controlSize = .large
        let field = Self.row([keyField, paste], spacing: 8)

        keyMessage.font = .systemFont(ofSize: 12)
        keyMessage.maximumNumberOfLines = 0
        consoleHelp.target = self; consoleHelp.action = #selector(openConsole)
        consoleHelp.bezelStyle = .rounded; consoleHelp.isHidden = true
        let toggle = Self.link("高级选项 · 手动填写服务地址", self, #selector(toggleAdvanced))
        baseField.placeholderString = "https://业务空间.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        baseField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        baseField.delegate = self; baseField.setAccessibilityLabel("百炼 Base URL")
        advanced.arrangedSubviews.forEach { advanced.removeArrangedSubview($0); $0.removeFromSuperview() }
        advanced.orientation = .vertical; advanced.alignment = .leading
        advanced.addArrangedSubview(Self.text("粘贴控制台提供的按量付费 Base URL；留空自动识别。", size: 11))
        advanced.addArrangedSubview(baseField)
        baseField.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        advanced.isHidden = true

        polishCheck.setAccessibilityLabel("同时启用 AI 润色（推荐）")
        let polishHint = Self.text("识别和润色按百炼用量计费，新用户在北京地域有免费额度。", size: 11)
        let polish = Self.column([polishCheck, polishHint], spacing: 6)
        polishHint.widthAnchor.constraint(equalTo: polish.widthAnchor).isActive = true
        let view = Self.column([Self.title("填入百炼 API Key"), intro, get, step2, step3, field, keyMessage, consoleHelp, toggle, advanced, polish], spacing: 14)
        view.setCustomSpacing(22, after: view.arrangedSubviews[0])
        view.setCustomSpacing(22, after: get)
        view.detachesHiddenViews = true
        for item in [intro, step2, step3, field, keyMessage, advanced, polish] as [NSView] {
            item.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }

        // A key found on this Mac is filled in and checked without asking.
        if snapshot.key != nil {
            if keyState != .checking { verifyKey() }
        } else {
            keyState = .idle
        }
        return view
    }

    private func updateKey() {
        guard step == .key else { return }
        let message: String
        var color = NSColor.imicMuted
        switch keyState {
        case .idle: message = ""
        case .checking: message = validationMessage
        case .valid:
            message = validationMessage
            color = .imicOrange
        case .rejected:
            message = validationMessage
            color = .systemRed
        case .offline:
            message = BailianIssue.network.message
            color = .systemRed
        case .format:
            message = "百炼 API Key 以 sk- 开头，请检查是否复制完整。"
            color = .systemRed
        }
        keyMessage.stringValue = message
        keyMessage.textColor = color
        let ready = keyState == .valid && keyIsActive
        polishCheck.isEnabled = ready && selection?.polishListed != false
        footer(primary: ready ? "下一步" : keyState == .checking ? "验证中…" : "验证",
               enabled: ready || (!enteredKey.isEmpty && keyState != .checking), secondary: nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard step == .key else { return }
        keyTask?.cancel(); keyTask = nil; debounce?.cancel(); keyGeneration = UUID()
        keyState = .idle
        consoleHelp.isHidden = true
        updateKey()
        guard !enteredKey.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.verifyKey() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    @objc private func toggleAdvanced() {
        advanced.isHidden.toggle()
        window?.setContentSize(NSSize(width: 640, height: advanced.isHidden ? 650 : 720))
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    @objc private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        keyField.stringValue = ShellCredentials.clean(text)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

    }

    @objc private func openConsole() {
        guard host?.setupPreview == false else { return }
        NSWorkspace.shared.open(SetupLinks.bailianKeys)
    }

    private func verifyKey() {
        let key = enteredKey
        guard !key.isEmpty else { return }
        guard ShellCredentials.valid(key) else {
            keyState = BailianAddress.isPlan(key) ? .rejected : .format
            validationMessage = BailianIssue.plan.message
            consoleHelp.isHidden = !BailianAddress.isPlan(key)
            updateKey(); return
        }
        keyTask?.cancel(); debounce?.cancel()
        keyField.stringValue = key
        keyGeneration = UUID(); let generation = keyGeneration
        keyState = .checking; validationMessage = "正在识别地域…"
        consoleHelp.isHidden = true
        updateKey()
        let finish: (Result<BailianDiscovery.Selection, BailianIssue>) -> Void = { [weak self] result in
            guard let self, self.keyGeneration == generation, self.enteredKey == key else { return }
            self.keyTask = nil
            switch result {
            case .success(let selection):
                guard self.adopt(key) else { return }
                self.host?.setupApplyService(selection)
                self.snapshot = self.host?.setupSnapshot() ?? self.snapshot
                self.selection = selection
                if !selection.polishListed { self.polishCheck.state = .off }
                self.validationMessage = selection.message
                self.checkedKey = key; self.keyState = .valid
            case .failure(let issue):
                self.keyState = .rejected; self.validationMessage = issue.message
                self.consoleHelp.isHidden = !issue.needsConsole
            }
            self.updateKey(); self.updateStepper()
        }
        if host?.setupPreview == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                finish(key.contains("bad") ? .failure(.invalidKey) : .success(.init(host: BailianAddress.hosts[0], asrListed: false, polishListed: true)))
            }
            return
        }
        keyTask = BailianDiscovery.start(key: key, baseURL: advanced.isHidden ? "" : baseField.stringValue,
            progress: { [weak self] message in
                guard let self, self.keyGeneration == generation else { return }
                self.validationMessage = message; self.updateKey()
            }, completion: finish)
    }

    /// A key already set on this Mac is used as-is; a pasted key is saved by iMic.
    private func adopt(_ key: String) -> Bool {
        guard let host else { return false }
        if let found = snapshot.key, found.key == key, found.source.isExternal {
            host.setupUseKey(found)
        } else if !host.setupSaveKey(key) {
            keyState = .idle
            updateKey()
            keyMessage.stringValue = "无法保存 Key，请检查磁盘权限。"
            keyMessage.textColor = .systemRed
            return false
        }
        snapshot = host.setupSnapshot()
        return true
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        keyTask?.cancel(); keyTask = nil; debounce?.cancel(); keyGeneration = UUID(); keyState = .idle
    }

    #if DEBUG
    /// Deterministic native-view captures; no network, real credentials or permissions.
    func previewKeyState(_ name: String) {
        guard host?.setupPreview == true else { return }
        keyTask?.cancel(); debounce?.cancel(); keyGeneration = UUID()
        keyField.stringValue = name == "initial" ? "" : "sk-preview-onboarding-key"
        consoleHelp.isHidden = true; selection = nil
        switch name {
        case "initial": keyState = .idle
        case "checking": keyState = .checking; validationMessage = "正在识别地域…"
        case "models": keyState = .checking; validationMessage = "正在确认模型权限…"
        case "success":
            let selected = BailianDiscovery.Selection(host: BailianAddress.hosts[1], asrListed: false, polishListed: true)
            snapshot.key = ResolvedCredential(key: keyField.stringValue, source: .app)
            selection = selected; keyState = .valid; validationMessage = selected.message
        default:
            let issues: [String: BailianIssue] = ["invalid": .invalidKey, "plan": .plan, "permission": .permission,
                "ip": .ip, "billing": .billing, "network": .network, "unsupported": .unsupported("中国香港")]
            let issue = issues[name] ?? .workspace
            keyState = .rejected; validationMessage = issue.message; consoleHelp.isHidden = !issue.needsConsole
        }
        polishCheck.state = .on
        updateKey(); window?.contentView?.layoutSubtreeIfNeeded()
    }
    #endif

    // MARK: - Style

    private static func title(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.textColor = .imicIvory
        return field
    }

    fileprivate static func text(_ text: String, size: CGFloat = 13) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .imicMuted
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func link(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .imicOrange
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private static func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    fileprivate static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }
}

/// One permission: name, one-line purpose, and either a button or an ON mark.
private final class PermissionRow: NSStackView {
    private let state = NSTextField(labelWithString: "")
    private let button: NSButton

    init(name: String, detail: String, action: String, target: AnyObject, selector: Selector) {
        button = NSButton(title: action, target: target, action: selector)
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .imicIvory
        let info = SetupWizard.text(detail, size: 12)
        let text = SetupWizard.column([title, info], spacing: 3)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        wantsLayer = true
        layer?.backgroundColor = NSColor.imicCard.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        for view in [text, NSView(), state, button] { addArrangedSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(granted: Bool) {
        state.attributedStringValue = NSAttributedString(string: "ON", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.imicOrange, .kern: 1.4,
        ])
        state.isHidden = !granted
        button.isHidden = granted
        layer?.borderColor = (granted ? NSColor.imicOrange.withAlphaComponent(0.45) : NSColor.imicHairline).cgColor
    }
}
