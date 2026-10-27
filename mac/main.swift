import AppKit
import ApplicationServices

private let launchArguments = CommandLine.arguments
private let headlessMode = launchArguments.contains("--headless")
private let previewMode = launchArguments.first { $0.hasPrefix("--ui-preview=") }
    .map { String($0.dropFirst("--ui-preview=".count)) }
private let pairCodeArgument = launchArguments.first { $0.hasPrefix("--pair-code=") }
    .map { String($0.dropFirst("--pair-code=".count)) }
private let disableInput = headlessMode || launchArguments.contains("--no-input")
private let portArgument = launchArguments.first { $0.hasPrefix("--port=") }
    .flatMap { UInt16($0.dropFirst("--port=".count)) }

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PairingStore()
    lazy var link = LinkServer(store: store, port: portArgument)

    var statusItem: NSStatusItem!
    var window: NSWindow!
    var settingsWindow: NSWindow!
    var permissionGuide: InputPermissionGuide?
    var statusMenu: NSMenu!

    let stateLabel = NSTextField(labelWithString: "NO LINK")
    let pairPanel = NSStackView()
    var pairSteps: NSStackView!
    let pairCodeLabel = NSTextField(labelWithString: "000 000")
    let pairHint = NSTextField(labelWithString: "")
    var pairPanelVisible = true
    let stageTitle = NSTextField(labelWithString: "")
    let stageHint = NSTextField(labelWithString: "")
    let transcript = NSTextView()
    let resultScroll = NSScrollView()
    let emptyMark = NSImageView()
    let meter = AudioActivityView()
    let elapsedLabel = NSTextField(labelWithString: "0.0 s")
    let spinner = NSProgressIndicator()
    let activityHint = NSTextField(labelWithString: "")
    let resultMeta = NSTextField(labelWithString: "")
    var lastLatencyMS = 0.0
    var activityRow: NSStackView!
    var stageStack: NSStackView!
    var controlsRow: NSStackView!
    var permissionRow: NSStackView!
    let automatic = NSButton(checkboxWithTitle: "自动输入", target: nil, action: nil)
    var copyButton: NSButton!
    let key = NSSecureTextField()
    var keyHint: NSTextField!
    let model = NSTextField(string: ASRConfiguration.current().model)
    let endpoint = NSTextField(string: ASRConfiguration.current().endpoint)
    let permissionState = NSTextField(labelWithString: "")
    let settingsPermissionLabel = NSTextField(labelWithString: "")
    var permissionButton: NSButton!
    var settingsPermissionButton: NSButton!
    var testInputButton: NSButton!
    let saveFeedback = NSTextField(labelWithString: "")
    var advanced: NSStackView!
    var advancedButton: NSButton!
    var pairedList: NSStackView!
    var cueView: NSView!
    var snapReturnCheck: NSButton!
    var pullDeleteCheck: NSButton!
    var swipeCursorCheck: NSButton!
    var deepseekCheck: NSButton!
    let deepseekKey = NSSecureTextField()
    let deepseekModel = NSTextField(string: DeepSeekConfiguration.modelName)
    var deepseekHint: NSTextField!
    let polishProviderPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let polishEndpoint = NSTextField()
    var polishAdvanced: NSStackView!
    var polishAdvancedButton: NSButton!
    var polishAddressHint: NSTextField!
    var editingPolishProvider = DeepSeekConfiguration.provider
    var polishDrafts: [PolishProvider: (model: String, endpoint: String, key: String)] = [:]
    var polishStrengthButtons: NSSegmentedControl!
    var polishScenarioButtons: NSSegmentedControl!
    var polishOptionsHint: NSTextField!
    var polishOutputPicker: NSPopUpButton!
    var livePreviewCheck: NSButton!
    var polishSweepCheck: NSButton!
    var polishSweepHint: NSTextField!
    let polishEffect = TextPolishEffect()
    var polishFinalChoice = PolishFinalChoice()
    var polishDeadlineWork: DispatchWorkItem?
    var polishTask: URLSessionDataTask?
    var bleFallbackCheck: NSButton!
    var pendingPreview = ""
    var previewWork: DispatchWorkItem?
    var lastPreviewApplied = Date.distantPast
    var recognitionFinalReceived = false
    var asrPreviewActive = false
    var phonePreviewActive = false
    var confirmedTranscript = ""
    var committedInputText = ""
    var liveInputBlocked = false
    var inputTarget: InputTarget?
    var inputWork: DispatchWorkItem?
    var inputMismatchSince: Date?

    // Session state.
    var gestureLease = LinkGestureLease()
    var clearingInput = false
    var currentSession: Int?
    var frames = 0
    var samples = 0
    var broken = false
    var waitingForSeq: Int?
    var pendingEndMessage: LinkMessage?
    var lastAudioNeedAt = Date.distantPast
    var audioNeedCount = 0
    var receivedPackets = 0
    var lastLoggedFrame = -1
    var startAt = Date()
    var lastPacketAt = Date()
    var stopAt: Date?
    var asr: BailianASR?
    var gate = ShortClipGate()
    var targetPID: pid_t?
    var targetAppName: String?
    var transcriptText = ""
    var lastInsertSucceeded = false
    var inserting = false
    var connectedName: String?
    var pairingRequested = false
    var watchdog: Timer?
    var statusResetWork: DispatchWorkItem?
    var launched = false
    var pendingReopen = false
    var pendingPermissionGuide = false
    var lastStatusBarKey: String?

    var bleBridge: BLEBridge?
    var preview: String? { previewMode }
    var headless: Bool { headlessMode }

    @objc func reopenFromAnotherInstance(_ notification: Notification) {
        let permission = notification.userInfo?["showPermissions"] as? Bool ?? false
        guard launched else {
            pendingReopen = true
            pendingPermissionGuide = pendingPermissionGuide || permission
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.show()
            if permission { self.permissions() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if launched { show() } else { pendingReopen = true }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launched else { return }
        launched = true
        if let code = pairCodeArgument { store.overrideCode(code) }
        store.onChange = { [weak self] in self?.refreshUI() }
        key.stringValue = MicCredentials.load()

        if headless {
            NSApp.setActivationPolicy(.prohibited)
            startHeadless()
            return
        }

        if preview == nil { TextPolishEffect.prewarm() }

        NSApp.setActivationPolicy(.accessory)
        buildUI()
        automatic.state = UserDefaults.standard.object(forKey: "automaticInput") as? Bool ?? true ? .on : .off
        refreshInputPermission()
        refreshUI()
        updateStatusBar()

        if let preview = preview {
            showPreview(preview)
            return
        }
        if pendingReopen { show(); pendingReopen = false }
        if pendingPermissionGuide { permissions(); pendingPermissionGuide = false }
        ASRConfiguration.migrateDefaults()

        installLinkHandlers()
        link.start()
        show()

        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watchdog?.invalidate()
        asr?.cancel()
        link.stop()
    }

    // MARK: - Link

    private func installLinkHandlers() {
        polishEffect.onVisualFinished = { [weak self] in self?.sendGestureState() }
        link.onState = { [weak self] state in
            guard let self = self else { return }
            IMicLog.write("mac.link", "state=\(String(describing: state))")
            switch state {
            case .starting:
                self.setStatus("正在启动链路…")
            case .advertising:
                if self.connectedName != nil { self.connectedName = nil }
                self.startBLEBridge()
                self.setStatus(self.key.stringValue.isEmpty ? "先配置百炼 API Key" : "等待 iPhone 连接")
            case .connected(let name):
                self.connectedName = name
                self.pairingRequested = false
                self.setStatus("已连接 \(name)")
                self.sendFeatureSettings()
            case .failed(let message):
                self.connectedName = nil
                self.setStatus("链路启动失败 · \(message)")
            }
            self.refreshUI()
            self.updateStatusBar()
        }
        link.onPairRequest = { [weak self] in
            guard let self = self else { return }
            IMicLog.write("mac.link", "pair requested")
            self.pairingRequested = true
            self.show()
            self.cuePairing()
            self.setStatus("在 iPhone 输入配对码")
            self.refreshUI()
            self.updateStatusBar()
        }
        link.onDisconnect = { [weak self] in
            guard let self = self else { return }
            IMicLog.write("mac.link", "disconnected")
            self.connectedName = nil
            self.abortSession(notifyPhone: false, message: "iPhone 已断开")
            self.setStatus("iPhone 已断开")
            self.refreshUI()
            self.updateStatusBar()
        }
        link.onMessage = { [weak self] message in
            self?.handle(message)
        }
        link.onPolishPreferences = { [weak self] preferences, features in
            var preferences = preferences
            // 旧版手机不认识输出模式，保存时会带回默认值；保留 Mac 当前的翻译 / 命令设置。
            if features & IMicLink.polishOutputFeature == 0 {
                preferences.options.output = DeepSeekConfiguration.options.output
            }
            self?.applyPolishPreferences(preferences, confirmingSave: true)
        }
        link.onAudio = { [weak self] packet in
            self?.handle(packet)
        }
    }

    private func startHeadless() {
        installLinkHandlers()
        link.onState = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .advertising:
                self.startBLEBridge()
                self.emit("LISTENING")
            case .connected(let name):
                self.connectedName = name
                self.emit("CONNECTED \(name)")
                self.sendFeatureSettings()
            case .failed(let message):
                self.emit("LINK_FAILED \(message)")
            case .starting:
                break
            }
        }
        link.onPairRequest = { [weak self] in self?.emit("PAIR_REQUEST") }
        link.onDisconnect = { [weak self] in
            self?.abortSession(notifyPhone: false, message: "disconnected")
            self?.emit("DISCONNECTED")
        }
        automatic.state = .off
        emit("PAIR_CODE=\(store.currentCode())")
        emit("MAC_ID=\(store.macID)")
        link.start()
        emit("HEADLESS_READY")
    }

    private func startBLEBridge() {
        guard bleFallbackEnabled, bleBridge == nil, let port = link.localPort else { return }
        let bridge = BLEBridge(port: port, macID: store.macID)
        bridge.start()
        bleBridge = bridge
        IMicLog.write("mac.ble", "bridge started port=\(port)")
    }

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private func handle(_ message: LinkMessage) {
        IMicLog.write("mac.session", "message=\(message.t) session=\(message.session ?? -1) frames=\(message.frames ?? -1) samples=\(message.samples ?? -1) chars=\(message.text?.count ?? 0)")
        switch message.t {
        case "audio.start":
            startSession(message.session ?? 0)
        case "audio.end":
            endSession(message)
        case "audio.cancel":
            if let session = message.session, currentSession == session {
                abortSession(notifyPhone: false, message: "本次输入已取消")
                setStatus("本次输入已取消", transient: true)
                refreshUI()
            }
        case "input":
            handleInput(message)
        case "preview":
            if livePreviewEnabled {
                let text = message.text ?? ""
                if !text.isEmpty, !phonePreviewActive {
                    phonePreviewActive = true
                    cancelPreview()
                    IMicLog.write("mac.preview", "source=phone until session ends")
                }
                handlePreview(text)
            }
        default:
            break
        }
    }

    private var snapReturnEnabled: Bool {
        UserDefaults.standard.object(forKey: "snapReturn") as? Bool ?? true
    }
    private var pullDeleteEnabled: Bool {
        UserDefaults.standard.object(forKey: "pullDelete") as? Bool ?? true
    }
    private var swipeCursorEnabled: Bool {
        UserDefaults.standard.object(forKey: "swipeCursor") as? Bool ?? true
    }
    private var livePreviewEnabled: Bool {
        UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true
    }
    private var bleFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: "bleFallback") as? Bool ?? true
    }
    private var featureMask: Int {
        (livePreviewEnabled ? 0b0001 : 0)
            | (snapReturnEnabled ? 0b0010 : 0)
            | (pullDeleteEnabled ? 0b0100 : 0)
            | (swipeCursorEnabled ? 0b1000 : 0)
            | IMicLink.polishPreferencesFeature
            | IMicLink.gestureControlFeature
            | IMicLink.polishOutputFeature
    }

    private var polishPreferences: LinkPolishPreferences {
        LinkPolishPreferences(enabled: DeepSeekConfiguration.enabled, options: DeepSeekConfiguration.options)
    }

    private func sendFeatureSettings() {
        guard link.isConnected else { return }
        IMicLog.write("mac.settings", "send features=\(featureMask)")
        link.send(.settings(features: featureMask, polish: polishPreferences))
        sendGestureState()
    }

    private func applyPolishPreferences(_ preferences: LinkPolishPreferences, confirmingSave: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.enabled, forKey: "deepseekEnabled")
        defaults.set(preferences.options.strength.rawValue, forKey: "deepseekStrength")
        defaults.set(preferences.options.scenario.rawValue, forKey: "deepseekScenario")
        defaults.set(preferences.options.output.rawValue, forKey: "polishOutput")
        let saved = polishPreferences
        deepseekCheck?.state = saved.enabled ? .on : .off
        if let index = PolishStrength.allCases.firstIndex(of: saved.options.strength) {
            polishStrengthButtons?.selectedSegment = index
        }
        if let index = PolishScenario.allCases.firstIndex(of: saved.options.scenario) {
            polishScenarioButtons?.selectedSegment = index
        }
        if let index = PolishOutput.allCases.firstIndex(of: saved.options.output) {
            polishOutputPicker?.selectItem(at: index)
        }
        updatePolishOptionControls(saved.options)
        IMicLog.write("mac.settings", "polish source=\(confirmingSave ? "phone" : "mac") enabled=\(saved.enabled) strength=\(saved.options.strength.rawValue) scenario=\(saved.options.scenario.rawValue) output=\(saved.options.output.rawValue)")
        if confirmingSave {
            link.send(.polishSaved(features: featureMask, polish: saved))
        } else {
            sendFeatureSettings()
        }
    }

    private func sendGestureState() {
        gestureLease.update(ready: currentSession == nil && !inserting && !clearingInput && !polishEffect.blocksGestures)
        if link.isConnected { link.send(.inputState(revision: gestureLease.revision, ready: gestureLease.ready)) }
    }

    private func clearInput(_ message: LinkMessage) {
        guard let revision = message.seq else { return }
        guard pullDeleteEnabled, gestureLease.permits(revision), currentSession == nil, !inserting,
              !clearingInput, !polishEffect.blocksGestures, inputAllowed(), !disableInput,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            link.send(.inputResult(revision: revision, applied: false, message: "Mac 忙碌或当前输入框不可用"))
            return
        }
        clearingInput = true
        sendGestureState() // Revoke the old lease before touching the field.
        InputTarget.clearFocusedText(pid: app.processIdentifier) { [weak self] applied in
            guard let self else { return }
            self.clearingInput = false
            self.link.send(.inputResult(revision: revision, applied: applied,
                message: applied ? nil : "当前输入框无法安全清空，请在电脑端操作"))
            self.sendGestureState()
            self.setStatus(applied ? "已清空输入框" : "未能清空当前输入框", transient: true)
        }
    }

    /// 中心弦手势映射到当前前台应用的按键。设置关闭时完全不投递。
    private func handleInput(_ message: LinkMessage) {
        let action = message.action ?? ""
        if action == "clear" { clearInput(message); return }
        guard !disableInput, currentSession == nil, !inserting, !clearingInput, !polishEffect.blocksGestures,
              message.seq == nil || gestureLease.permits(message.seq) else { return }
        guard inputAllowed() else {
            IMicLog.write("mac.input", "ignored action=\(action) permission=false")
            refreshInputPermission()
            setStatus("需要辅助功能权限才能执行手势", transient: true)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let pid: pid_t?
        if let front, front.processIdentifier != getpid() {
            pid = front.processIdentifier
        } else if let targetPID {
            pid = targetPID
        } else {
            pid = nil
        }
        guard let pid else {
            IMicLog.write("mac.input", "ignored action=\(action) no target")
            setStatus("没有可输入的应用", transient: true)
            return
        }
        let key: CGKeyCode
        let label: String
        switch action {
        case "return":
            guard snapReturnEnabled else { return }
            key = 36; label = "回车"
        case "delete":
            guard pullDeleteEnabled else { return }
            key = 51; label = "删除"
        case "left":
            guard swipeCursorEnabled else { return }
            key = 123; label = "光标 ←"
        case "right":
            guard swipeCursorEnabled else { return }
            key = 124; label = "光标 →"
        default:
            IMicLog.write("mac.input", "unknown action=\(action)")
            return
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            IMicLog.write("mac.input", "event create failed action=\(action)")
            return
        }
        if currentSession != nil { liveInputBlocked = true }
        down.setIntegerValueField(.eventSourceUserData, value: InputTarget.keyboardEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: InputTarget.keyboardEventTag)
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
        IMicLog.write("mac.input", "action=\(action) pid=\(pid) app=\(front?.localizedName ?? "-")")
        setStatus(label, transient: true)
    }

    private func handle(_ packet: AudioPacket) {
        let packetSession = Int(packet.session)
        if currentSession == nil {
            IMicLog.write("mac.session", "implicit start session=\(packetSession) seq=\(packet.seq) bytes=\(packet.pcm.count)")
            startSession(packetSession, implicit: true)
            guard currentSession == packetSession else {
                IMicLog.write("mac.session", "implicit start rejected session=\(packetSession)")
                return
            }
        }
        guard let session = currentSession, packetSession == session, !broken else {
            IMicLog.write("mac.session", "packet ignored session=\(packetSession) current=\(currentSession ?? -1) broken=\(broken)")
            return
        }

        let seq = Int(packet.seq)
        let expected = frames
        if let waiting = waitingForSeq {
            if seq < waiting {
                IMicLog.write("mac.session", "duplicate while waiting seq=\(seq) waiting=\(waiting)")
                return
            }
            if seq > waiting {
                IMicLog.write("mac.session", "assumed gap still open seq=\(seq) waiting=\(waiting) frames=\(expected)")
                requestAudioNeed(from: waiting)
                return
            }
            waitingForSeq = nil
            IMicLog.write("mac.session", "replay filled seq=\(seq) frames=\(expected) samples=\(samples)")
        }

        if seq > expected {
            IMicLog.write("mac.session", "gap session=\(session) expected=\(expected) received=\(seq) missing=\(seq - expected)")
            requestAudioNeed(from: expected)
            return
        }
        if seq < expected {
            IMicLog.write("mac.session", "duplicate/late seq=\(seq) expected=\(expected) ignored")
            return
        }

        frames += 1
        samples += packet.pcm.count / 2
        receivedPackets += 1
        lastPacketAt = Date()
        if receivedPackets == 1 || receivedPackets % 25 == 0 {
            IMicLog.write("mac.session", "audio seq=\(seq) packets=\(receivedPackets) frames=\(frames) samples=\(samples) bytes=\(packet.pcm.count)")
        }
        if samples > IMicLink.sampleRate * IMicLink.maxSessionSeconds {
            abortSession(notifyPhone: true, message: "单次录音最长 \(IMicLink.maxSessionSeconds / 60) 分钟")
            return
        }
        do {
            if let accepted = try gate.append(packet.pcm) {
                if asr == nil { startRecognition(session) }
                guard currentSession == session, !broken else { return }
                asr?.append(accepted)
            }
        } catch {
            abortSession(notifyPhone: true, message: "音频数据不完整，本次输入已取消")
            return
        }
        var energy = 0.0
        packet.pcm.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let value = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: Int16.self)))
                energy += value * value
            }
        }
        let count = max(1, packet.pcm.count / 2)
        meter.doubleValue = min(1, sqrt(energy / Double(count)) / 7000)
        if stopAt == nil { elapsedLabel.stringValue = String(format: "%.1f s", Double(samples) / 16000) }

        if let pending = pendingEndMessage,
           pending.frames == frames, pending.samples == samples {
            pendingEndMessage = nil
            IMicLog.write("mac.session", "replay completed end session=\(session) frames=\(frames) samples=\(samples)")
            completeEnd(pending)
        }
    }

    private func startSession(_ session: Int, implicit: Bool = false) {
        guard !clearingInput else {
            link.send(.failure(session: session, code: "busy", message: "正在清空输入框，请稍后重试"))
            return
        }
        if currentSession == session {
            IMicLog.write("mac.session", "duplicate start session=\(session) frames=\(frames) samples=\(samples) implicit=\(implicit)")
            link.send(.state(session: session, phase: "listening"))
            return
        }
        if let previous = currentSession, previous != session {
            guard !inserting else {
                IMicLog.write("mac.session", "start rejected session=\(session) previous=\(previous) inserting=true")
                link.send(.failure(session: session, code: "busy", message: "上一条正在输入，请稍后重试"))
                return
            }
            // 用户已经开始新会话：旧的 ASR 不能继续占用单会话状态，否则
            // 新音频会被全部丢弃，最后只能看到旧结果或尾段。
            IMicLog.write("mac.session", "replace previous session=\(previous) with=\(session) frames=\(frames) samples=\(samples)")
            discardUnconfirmedInput()
            asr?.cancel()
            asr = nil
            gate.reset()
            waitingForSeq = nil
            pendingEndMessage = nil
            stopAt = nil
            currentSession = nil
        }
        guard !key.stringValue.isEmpty else {
            IMicLog.write("mac.session", "start rejected key missing session=\(session)")
            link.send(.failure(session: session, code: "key", message: "Mac 尚未配置百炼 API Key"))
            showSettings()
            polishEffect.cancel()
            polishTask?.cancel(); polishTask = nil
            sendGestureState()
            return
        }
        cancelPreview()
        lastPreviewApplied = .distantPast
        polishEffect.beginSession()
        polishDeadlineWork?.cancel()
        polishTask?.cancel()
        polishTask = nil
        polishFinalChoice = PolishFinalChoice()
        recognitionFinalReceived = false
        asrPreviewActive = false
        phonePreviewActive = false
        confirmedTranscript = ""
        committedInputText = ""
        liveInputBlocked = false
        inputMismatchSince = nil
        inserting = false
        currentSession = session
        sendGestureState()
        frames = 0
        samples = 0
        broken = false
        waitingForSeq = nil
        pendingEndMessage = nil
        lastAudioNeedAt = .distantPast
        audioNeedCount = 0
        receivedPackets = 0
        lastLoggedFrame = -1
        startAt = Date()
        lastPacketAt = Date()
        stopAt = nil
        asr = nil
        gate.reset()
        transcriptText = ""
        lastLatencyMS = 0
        lastInsertSucceeded = false
        targetPID = nil
        targetAppName = nil
        inputTarget = nil
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            targetPID = app.processIdentifier
            targetAppName = app.localizedName
        }
        if let targetPID { inputTarget = InputTarget.capture(pid: targetPID) }
        IMicLog.write("mac.session", "start session=\(session) implicit=\(implicit) target=\(targetAppName ?? "-")")
        IMicLog.write("mac.input", "target pid=\(targetPID ?? -1) streaming=\(inputTarget?.allowsStreaming == true) mode=\(inputTarget?.mode.rawValue ?? "unavailable")")
        link.send(.state(session: session, phase: "listening"))
        setStatus("正在听…")
        refreshUI()
        updateStatusBar()
    }

    /// 请求 iPhone 从 seq 开始补发本会话音频。等待期间忽略后续帧，
    /// 避免把缺口之后的内容先送进 ASR，造成只能在结果里看到尾段。
    private func requestAudioNeed(from seq: Int) {
        guard let session = currentSession, seq >= 0 else { return }
        waitingForSeq = seq
        lastAudioNeedAt = Date()
        audioNeedCount += 1
        IMicLog.write("mac.session", "audio.need session=\(session) from=\(seq) frames=\(frames) samples=\(samples) attempt=\(audioNeedCount)")
        if headless { emit("AUDIO_NEED session=\(session) from=\(seq) frames=\(frames)") }
        link.send(.audioNeed(session: session, from: seq))
    }

    private func startRecognition(_ session: Int) {
        guard currentSession == session, asr == nil, gate.isOpen else { return }
        IMicLog.write("mac.session", "recognition start session=\(session) gateOpen=\(gate.isOpen) frames=\(frames) samples=\(samples)")
        let recognizer = BailianASR()
        asr = recognizer
        recognizer.previewEnabled = true
        recognizer.onPreview = { [weak self] text in
            self?.handleASRPreview(text, session: session)
        }
        recognizer.onConfirmed = { [weak self] text in
            self?.handleConfirmedText(text, session: session)
        }
        recognizer.onFinal = { [weak self] text, latency in
            self?.finishSession(session, text: text, latency: latency)
        }
        recognizer.onError = { [weak self] message in
            guard let self = self, self.currentSession == session else { return }
            self.abortSession(notifyPhone: true, message: message)
        }
        recognizer.start(
            key: key.stringValue,
            endpoint: endpoint.stringValue,
            model: model.stringValue
        )
    }

    private func endSession(_ message: LinkMessage) {
        guard let session = currentSession, message.session == session else {
            IMicLog.write("mac.session", "end ignored session=\(message.session ?? -1) current=\(currentSession ?? -1)")
            return
        }
        let expectedFrames = message.frames ?? -1
        let expectedSamples = message.samples ?? -1
        IMicLog.write("mac.session", "end session=\(session) frames=\(frames)/\(expectedFrames) samples=\(samples)/\(expectedSamples)")
        if expectedFrames == frames, expectedSamples == samples {
            completeEnd(message)
            return
        }
        pendingEndMessage = message
        if expectedFrames > frames {
            requestAudioNeed(from: frames)
        } else if expectedFrames < frames {
            IMicLog.write("mac.session", "end is behind received frames; completing with received audio")
            pendingEndMessage = nil
            completeEnd(message)
        } else {
            // 帧数一致但样本数不同，说明最后一帧的长度记录有偏差；已有的帧都已收到，
            // 继续识别，避免重发最后一帧造成序号回退卡死。
            IMicLog.write("mac.session", "sample count differs at same frame count; completing with received audio")
            pendingEndMessage = nil
            completeEnd(message)
        }
    }

    private func completeEnd(_ message: LinkMessage) {
        guard let session = currentSession, message.session == session else { return }
        pendingEndMessage = nil
        if waitingForSeq != nil {
            IMicLog.write("mac.session", "end with replay still pending session=\(session) waiting=\(waitingForSeq ?? -1)")
            return
        }
        guard gate.isOpen else {
            cancelPreview()
            discardUnconfirmedInput()
            currentSession = nil
            inputTarget = nil
            transcriptText = ""
            gate.reset()
            link.send(.result(session: session, text: "", latency: 0, pasted: false, target: targetAppName))
            sendGestureState()
            setStatus("录音太短，已忽略", transient: true)
            refreshUI()
            updateStatusBar()
            return
        }
        // 先补齐节流队列，保留已输入的文字；最终识别和润色不阻塞实时尾部。
        previewWork?.cancel()
        previewWork = nil
        if !pendingPreview.isEmpty { applyPreview(pendingPreview) }
        stopAt = Date()
        IMicLog.write("mac.session", "transcribing session=\(session) frames=\(frames) samples=\(samples)")
        link.send(.state(session: session, phase: "transcribing"))
        setStatus("正在整理文字…")
        if asr == nil { startRecognition(session) }
        asr?.end()
        refreshUI()
        updateStatusBar()
    }

    private func handleASRPreview(_ text: String, session: Int) {
        guard currentSession == session, !recognitionFinalReceived, !text.isEmpty,
              !phonePreviewActive else { return }
        if !asrPreviewActive {
            cancelPreview()
            asrPreviewActive = true
        }
        handlePreview(text)
    }

    private func handleConfirmedText(_ text: String, session: Int) {
        guard currentSession == session, !recognitionFinalReceived else { return }
        confirmedTranscript = text
        // A completed cloud sentence is not a live-preview source takeover.
        // Phone hypotheses continue across pauses until the utterance is finalized.
        if !phonePreviewActive { handleASRPreview(text, session: session) }
    }

    private func finishSession(_ session: Int, text: String, latency: Double) {
        guard currentSession == session, !recognitionFinalReceived else { return }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            completeSession(session, text: "", latency: latency)
            return
        }
        // Freeze what the user already sees. Neither raw ASR nor the polished
        // candidate is presented until the final choice and one visual handoff.
        cancelPreview()
        recognitionFinalReceived = true
        confirmedTranscript = raw
        let options = DeepSeekConfiguration.options
        let provider = DeepSeekConfiguration.provider
        let polishKey = PolishCredentials.load(for: provider)
        guard DeepSeekConfiguration.enabled else {
            completeSession(session, text: raw, latency: latency)
            return
        }
        if !headless, automatic.state == .on, !disableInput,
           let target = inputTarget, target.allowsStreaming, let pid = targetPID {
            polishEffect.prepare(pid: pid, element: target.visualElement, text: committedInputText,
                allowed: { [weak self, weak target] in
                    guard let self, let target else { return false }
                    return self.currentSession == session && self.inputTarget === target
                        && !self.liveInputBlocked && target.permitsVisualEffect
                }, interrupted: { [weak self] in
                    guard let self, self.currentSession == session else { return }
                    self.liveInputBlocked = true
                })
        }
        let polishModel = DeepSeekConfiguration.modelName(for: provider)
        let polishAddress = DeepSeekConfiguration.endpoint(for: provider)
        // 终端命令模式下，润色失败不能把原话当命令输入，改为单行注释。
        let fallback = options.fallbackText(for: raw)
        do {
            _ = try DeepSeekClient.validatedURL(provider: provider, model: polishModel, endpoint: polishAddress)
            guard PolishCredentials.valid(polishKey, for: provider) else { throw PolishConfigurationError.key }
        } catch {
            IMicLog.write("mac.polish", "skipped provider=\(provider.rawValue) reason=invalid_configuration")
            deepseekHint?.stringValue = "\(provider.title)：\(error.localizedDescription)，已保留原文。"
            deepseekHint?.textColor = .systemRed
            choosePolishResult(session, raw: fallback, polished: nil, latency: latency)
            return
        }
        asr = nil
        setStatus("正在润色…")
        IMicLog.write("mac.session", "polish session=\(session) provider=\(provider.rawValue) chars=\(raw.count) strength=\(options.strength.rawValue) scenario=\(options.scenario.rawValue) output=\(options.output.rawValue)")
        // URLSession's request timeout is not a hard wall-clock deadline when
        // a server keeps sending bytes. The utterance has its own terminal gate.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.currentSession == session else { return }
            IMicLog.write("mac.polish", "fallback reason=hard_deadline session=\(session)")
            self.choosePolishResult(session, raw: fallback, polished: nil, latency: latency)
        }
        polishDeadlineWork = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
        polishTask = DeepSeekClient.polish(
            text: raw,
            key: polishKey,
            model: polishModel,
            endpoint: polishAddress,
            provider: provider,
            options: options
        ) { [weak self] polished in
            guard let self = self, self.currentSession == session else { return }
            self.choosePolishResult(session, raw: fallback, polished: polished, latency: latency)
        }
    }

    private func choosePolishResult(_ session: Int, raw: String, polished: String?, latency: Double) {
        guard currentSession == session, let final = polishFinalChoice.settle(raw: raw, polished: polished) else { return }
        polishDeadlineWork?.cancel(); polishDeadlineWork = nil
        polishTask?.cancel(); polishTask = nil
        if !headless { setStatus("正在完成输入…") }
        polishEffect.deliverAfterSweep { [weak self] in
            guard let self, self.currentSession == session else { return }
            self.completeSession(session, text: final, latency: latency)
        }
    }

    private func handlePreview(_ text: String) {
        guard livePreviewEnabled, currentSession != nil, !inserting, !recognitionFinalReceived else {
            IMicLog.write("mac.preview", "ignored chars=\(text.count) enabled=\(livePreviewEnabled)")
            return
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingPreview = clean
        let now = Date()
        let interval = now.timeIntervalSince(lastPreviewApplied)
        if interval >= 0.22 {
            applyPreview(clean)
        } else if previewWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.previewWork = nil
                self.applyPreview(self.pendingPreview)
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.22 - interval), execute: work)
        }
    }

    private func applyPreview(_ text: String) {
        guard currentSession != nil, !inserting, !recognitionFinalReceived, livePreviewEnabled else { return }
        if text != transcriptText {
            transcriptText = text
            lastPreviewApplied = Date()
            refreshUI()
            IMicLog.write("mac.preview", "displayed chars=\(text.count)")
        }
        if automatic.state == .on, !disableInput, inputTarget?.allowsStreaming == true,
           !text.isEmpty || !committedInputText.isEmpty {
            requestInput(text)
        }
    }

    private func cancelPreview() {
        previewWork?.cancel()
        previewWork = nil
        pendingPreview = ""
        cancelInputWork()
    }

    private func discardUnconfirmedInput() {
        guard !recognitionFinalReceived, !committedInputText.isEmpty,
              committedInputText != confirmedTranscript,
              automatic.state == .on, !disableInput,
              inputTarget?.allowsStreaming == true else { return }
        _ = insert(confirmedTranscript)
    }

    private func completeSession(_ session: Int, text: String, latency: Double) {
        guard currentSession == session else { return }
        cancelPreview()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetAppName
        var pasted = false
        if !clean.isEmpty, automatic.state == .on, !disableInput {
            if !inserting {
                // Final delivery owns a fresh confirmation window; time spent
                // waiting for raw ASR/polish is not evidence of user takeover.
                inputMismatchSince = nil
                inserting = true
            }
            guard let result = insert(clean) else {
                scheduleInput { [weak self] in
                    self?.completeSession(session, text: clean, latency: latency)
                }
                return
            }
            pasted = result
        } else if !clean.isEmpty {
            setStatus("识别完成")
        } else {
            setStatus("没有识别到语音")
        }
        IMicLog.write("mac.session", "finish session=\(session) chars=\(clean.count) latency_ms=\(Int(latency)) pasted=\(pasted) frames=\(frames) samples=\(samples)")
        inserting = false
        polishEffect.finishDelivery(succeeded: pasted, finalText: clean,
                                    verified: inputTarget?.requiresConfirmation == true)
        currentSession = nil
        polishDeadlineWork?.cancel(); polishDeadlineWork = nil
        polishTask?.cancel(); polishTask = nil
        inputTarget = nil
        asr = nil
        gate.reset()
        stopAt = nil
        waitingForSeq = nil
        pendingEndMessage = nil
        audioNeedCount = 0
        transcriptText = clean
        lastLatencyMS = latency
        lastInsertSucceeded = pasted
        link.send(.result(
            session: session,
            text: clean,
            latency: latency,
            pasted: pasted,
            target: target
        ))
        sendGestureState()
        if headless {
            emit("RESULT_BEGIN")
            emit(clean)
            emit("RESULT_END latency_ms=\(Int(latency)) pasted=\(pasted)")
        }
        refreshUI()
        updateStatusBar()
    }

    private func abortSession(notifyPhone: Bool, message: String) {
        polishEffect.cancel()
        polishDeadlineWork?.cancel(); polishDeadlineWork = nil
        polishTask?.cancel(); polishTask = nil
        guard let session = currentSession else {
            cancelInputWork()
            inserting = false
            inputTarget = nil
            asr?.cancel()
            asr = nil
            gate.reset()
            stopAt = nil
            waitingForSeq = nil
            pendingEndMessage = nil
            sendGestureState()
            refreshUI()
            updateStatusBar()
            return
        }
        IMicLog.write("mac.session", "abort session=\(session) notify=\(notifyPhone) frames=\(frames) samples=\(samples) waiting=\(waitingForSeq ?? -1) pendingEnd=\(pendingEndMessage != nil) reason=\(message)")
        let retainedPreview = pendingPreview.isEmpty ? transcriptText : pendingPreview
        cancelPreview()
        discardUnconfirmedInput()
        // On failure keep the latest local transcript available for copying,
        // independently of any best-effort rollback in the target editor.
        if !recognitionFinalReceived { transcriptText = notifyPhone ? retainedPreview : confirmedTranscript }
        currentSession = nil
        inputTarget = nil
        inserting = false
        broken = true
        asr?.cancel()
        asr = nil
        gate.reset()
        stopAt = nil
        waitingForSeq = nil
        pendingEndMessage = nil
        audioNeedCount = 0
        meter.doubleValue = 0
        if notifyPhone {
            link.send(.failure(session: session, code: "asr", message: message))
        }
        sendGestureState()
        if headless { emit("FAILURE \(message)") }
        setStatus(message)
        refreshUI()
        updateStatusBar()
    }

    private func tick() {
        if !headless { refreshInputPermission() }
        guard let session = currentSession else { return }
        if let waiting = waitingForSeq {
            let sinceRequest = Date().timeIntervalSince(lastAudioNeedAt)
            if sinceRequest > 0.8 {
                requestAudioNeed(from: waiting)
            }
            if Date().timeIntervalSince(lastPacketAt) > 12 {
                abortSession(notifyPhone: true, message: "音频补发超时，本次输入已取消")
            }
            elapsedLabel.stringValue = String(format: "%.1f s", Double(samples) / 16000)
            return
        }
        if stopAt == nil {
            if Date().timeIntervalSince(lastPacketAt) > 6 {
                abortSession(notifyPhone: true, message: "音频传输超时，本次输入已取消")
            } else {
                elapsedLabel.stringValue = String(format: "%.1f s", Double(samples) / 16000)
            }
        } else if let deadline = asr?.completionDeadline, Date() > deadline {
            abortSession(notifyPhone: true, message: "等待识别结果超时")
        }
        _ = session
    }

    // MARK: - Insertion

    func inputPermissionState() -> InputPermissionState {
        if let preview = preview {
            let allowed = preview != "permission"
            return InputPermissionState(accessibility: allowed, posting: allowed)
        }
        return InputPermissionState(
            accessibility: AXIsProcessTrusted(),
            posting: CGPreflightPostEventAccess()
        )
    }

    func inputAllowed() -> Bool { inputPermissionState().allowed }

    /// nil means the target's asynchronous AX snapshot has not settled yet.
    /// Callers must wait before another revision or reporting final delivery.
    func insert(_ text: String) -> Bool? {
        guard !liveInputBlocked else {
            setStatus("输入位置已变化 · 文字已保留")
            return false
        }
        guard inputAllowed() else {
            refreshInputPermission()
            setStatus("文字已保留 · 请允许自动输入")
            return false
        }
        guard let pid = targetPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else {
            liveInputBlocked = true
            setStatus("前台应用已变化 · 文字已保留")
            return false
        }
        switch inputTarget?.settlePendingReplacement() ?? .none {
        case .none: break
        case .waiting: return nil
        case .applied(let confirmed):
            committedInputText = confirmed
            inputMismatchSince = nil
        case .blocked:
            liveInputBlocked = true
            setStatus("输入结果暂无法核验 · 完整文字已保留")
            IMicLog.write("mac.input", "AX write unresolved; no automatic replay")
            return false
        }
        if !committedInputText.isEmpty, let inputTarget, inputTarget.allowsStreaming {
            switch inputTarget.validate(committedInputText) {
            case .ready:
                inputMismatchSince = nil
            case .interrupted(let reason):
                liveInputBlocked = true
                setStatus("输入位置已变化 · 文字已保留")
                IMicLog.write("mac.input", "revision interrupted reason=\(reason)")
                return false
            case .waiting(let reason):
                if inputMismatchSince == nil {
                    inputMismatchSince = Date()
                    IMicLog.write("mac.input", "waiting for target reason=\(reason)")
                }
                guard Date().timeIntervalSince(inputMismatchSince!) < 1.5 else {
                    inputMismatchSince = nil
                    if inputTarget.enableKeyboardCompatibility() {
                        IMicLog.write("mac.input", "mode=keyboard_compatibility reason=range_timeout details=\(reason)")
                        return insert(text)
                    }
                    setStatus("输入范围暂未同步 · 文字已保留")
                    IMicLog.write("mac.input", "target confirmation timed out recoverable=true reason=\(reason)")
                    return false
                }
                return nil
            }
        }
        if text != committedInputText {
            guard let inputTarget else {
                liveInputBlocked = true
                setStatus("输入位置无法确认 · 文字已保留")
                return false
            }
            let revision = TextRevision(from: committedInputText, to: text)
            let succeeded: Bool
            if committedInputText.isEmpty {
                switch inputTarget.prepareInitialInsertion() {
                case .ready: succeeded = typeText(text, pid: pid)
                case .collapseSelection: succeeded = typeText(text, pid: pid, collapseSelection: true)
                case .changed: succeeded = false
                }
            } else if revision.deleteCount > 0 {
                let replacement = inputTarget.replaceTail(previous: committedInputText, next: text, revision: revision) { deleting, inserting in
                    typeText(inserting, pid: pid, deletingCharacters: deleting)
                }
                switch replacement {
                case .applied: succeeded = true
                case .pending: return nil
                case .blocked: succeeded = false
                }
            } else {
                succeeded = typeText(revision.insertion, pid: pid)
            }
            guard succeeded else {
                liveInputBlocked = true
                setStatus("输入范围已变化 · 未覆盖原内容，结果已保留")
                IMicLog.write("mac.input", "revision blocked: field, caret or owned range could not be verified")
                return false
            }
            committedInputText = text
            IMicLog.write("mac.input", "owned revision chars=\(text.count) delete=\(revision.deleteCount) insert=\(revision.insertion.count) mode=\(inputTarget.mode.rawValue)")
            if inputTarget.requiresConfirmation, !text.isEmpty {
                inputMismatchSince = Date()
                return nil
            }
        }
        if currentSession == nil || recognitionFinalReceived {
            let verb = inputTarget?.requiresConfirmation == true ? "已输入" : "已投递"
            setStatus("\(verb) · \(targetAppName ?? "当前应用")")
        }
        return true
    }

    private func requestInput(_ text: String) {
        cancelInputWork()
        guard insert(text) == nil else { return }
        scheduleInput { [weak self] in self?.requestInput(text) }
    }

    private func scheduleInput(_ action: @escaping () -> Void) {
        let target = inputTarget
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inputTarget === target else { return }
            self.inputWork = nil
            action()
        }
        inputWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    private func cancelInputWork() {
        inputWork?.cancel()
        inputWork = nil
    }


    private func typeText(_ text: String, pid: pid_t, collapseSelection: Bool = false, deletingCharacters: Int = 0) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.userData = InputTarget.keyboardEventTag
        if collapseSelection || deletingCharacters > 0 {
            // Delete only the computed session tail; compatibility mode relies on takeover monitors.
            // Unknown initial selections are collapsed with Right, never deleted.
            let key: CGKeyCode = collapseSelection ? 124 : 51
            for _ in 0..<(collapseSelection ? 1 : deletingCharacters) {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
                down.flags = []
                up.flags = []
                down.postToPid(pid)
                up.postToPid(pid)
            }
        }
        var chunk = ""
        func post() -> Bool {
            guard !chunk.isEmpty else { return true }
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.postToPid(pid)
            up.postToPid(pid)
            chunk = ""
            return true
        }
        for character in text {
            if chunk.utf16.count + String(character).utf16.count > 20, !post() { return false }
            chunk.append(character)
        }
        return post()
    }

    // MARK: - Actions

    @objc func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    @objc func copyPairCode() {
        let code = PairingCode.formatted(store.currentCode())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        setStatus("配对码已复制")
        pairHint.stringValue = "已复制 · 在 iPhone 输入 \(code)"
    }

    @objc func rotatePairCode() {
        store.rotateCode()
        setStatus("已生成新的配对码")
        refreshUI()
    }

    @objc func copyText() {
        guard !transcriptText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        copyButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton.title = "复制文字"
        }
    }

    @objc func showSettings() {
        refreshInputPermission()
        rebuildPairedList()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleAutoInput() {
        if currentSession != nil, !committedInputText.isEmpty { liveInputBlocked = true }
        UserDefaults.standard.set(automatic.state == .on, forKey: "automaticInput")
        refreshInputPermission()
        refreshUI()
    }

    @objc func toggleSnapReturn() {
        UserDefaults.standard.set(snapReturnCheck.state == .on, forKey: "snapReturn")
        IMicLog.write("mac.settings", "snapReturn=\(snapReturnCheck.state == .on)")
        sendFeatureSettings()
    }

    @objc func togglePullDelete() {
        UserDefaults.standard.set(pullDeleteCheck.state == .on, forKey: "pullDelete")
        IMicLog.write("mac.settings", "pullDelete=\(pullDeleteCheck.state == .on)")
        sendFeatureSettings()
    }

    @objc func toggleSwipeCursor() {
        UserDefaults.standard.set(swipeCursorCheck.state == .on, forKey: "swipeCursor")
        IMicLog.write("mac.settings", "swipeCursor=\(swipeCursorCheck.state == .on)")
        sendFeatureSettings()
    }

    @objc func toggleDeepSeek() {
        applyPolishPreferences(
            LinkPolishPreferences(enabled: deepseekCheck.state == .on, options: DeepSeekConfiguration.options),
            confirmingSave: false
        )
    }

    func rememberPolishDraft() {
        polishDrafts[editingPolishProvider] = (
            deepseekModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            polishEndpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            deepseekKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @objc func changePolishProvider() {
        rememberPolishDraft()
        guard PolishProvider.allCases.indices.contains(polishProviderPicker.indexOfSelectedItem) else { return }
        editingPolishProvider = PolishProvider.allCases[polishProviderPicker.indexOfSelectedItem]
        loadPolishProviderFields()
        saveFeedback.textColor = .imicMuted
        saveFeedback.stringValue = "来源切换将在保存后生效"
    }

    func loadPolishProviderFields() {
        let provider = editingPolishProvider
        let draft = polishDrafts[provider]
        deepseekModel.stringValue = draft?.model ?? DeepSeekConfiguration.modelName(for: provider)
        polishEndpoint.stringValue = draft?.endpoint ?? DeepSeekConfiguration.endpoint(for: provider)
        deepseekKey.stringValue = provider == .bailian ? key.stringValue : (draft?.key ?? PolishCredentials.load(for: provider))
        deepseekKey.isEnabled = provider != .bailian
        deepseekKey.placeholderString = "\(provider.title) API Key"
        deepseekKey.setAccessibilityLabel("\(provider.title) API Key")
        deepseekKey.toolTip = provider == .bailian ? "复用上方百炼 API Key；请在上方修改" : nil
        deepseekModel.placeholderString = provider.defaultModel.isEmpty ? "服务提供的模型名称" : provider.defaultModel
        polishEndpoint.placeholderString = provider == .custom ? "https://example.com/v1/chat/completions" : provider.defaultEndpoint
        deepseekHint.textColor = .imicMuted
        let active = DeepSeekConfiguration.provider.title
        switch provider {
        case .deepseek:
            deepseekHint.stringValue = "当前生效：\(active)。官方 Key 独立保存到 ~/.zshrc；失败保留原文。"
            polishAddressHint.stringValue = "完整 Chat Completions 地址，仅允许 api.deepseek.com 的 HTTPS 地址。关闭思考，只整理口述内容。"
        case .bailian:
            deepseekHint.stringValue = "当前生效：\(active)。复用上方百炼 Key（DASHSCOPE_API_KEY / BAILIAN_API_KEY），请在上方修改。"
            polishAddressHint.stringValue = "填完整地址：https://业务空间ID.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions；默认是北京 DashScope。Key、模型须与地域匹配；关闭思考。"
        case .custom:
            deepseekHint.stringValue = "当前生效：\(active)。独立 Key 保存为 ~/.zshrc 中的 IMIC_CUSTOM_POLISH_API_KEY，不复用其他来源。"
            polishAddressHint.stringValue = "填写完整 HTTPS Chat Completions 地址，例如 https://example.com/v1/chat/completions，不是 Base URL。不支持思考专用模型；HTTP 仅允许 127.0.0.1 或 [::1] 本机联调。"
        }
        let expanded = provider == .custom
        polishAdvancedButton.state = expanded ? .on : .off
        updatePolishAdvanced()
    }

    @objc func togglePolishAdvanced() {
        updatePolishAdvanced()
    }

    func updatePolishAdvanced() {
        let expanded = polishAdvancedButton.state == .on
        polishAdvanced.isHidden = !expanded
        polishAdvancedButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil
        )
        polishAdvancedButton.setAccessibilityLabel(expanded ? "收起润色模型与地址" : "展开润色模型与地址")
    }

    func validatePolishSettings() -> Bool {
        rememberPolishDraft()
        guard let draft = polishDrafts[editingPolishProvider] else { return false }
        do {
            _ = try DeepSeekClient.validatedURL(provider: editingPolishProvider, model: draft.model, endpoint: draft.endpoint)
            let selectedKey = editingPolishProvider == .bailian
                ? key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : draft.key
            if deepseekCheck.state == .on || !selectedKey.isEmpty {
                guard PolishCredentials.valid(selectedKey, for: editingPolishProvider) else { throw PolishConfigurationError.key }
            }
            for (provider, value) in polishDrafts where provider != .bailian && !value.key.isEmpty {
                guard PolishCredentials.valid(value.key, for: provider) else {
                    saveFeedback.textColor = .systemRed
                    saveFeedback.stringValue = "\(provider.title)：API Key 格式无效"
                    return false
                }
            }
            return true
        } catch {
            saveFeedback.textColor = .systemRed
            saveFeedback.stringValue = error.localizedDescription
            polishAdvancedButton.state = .on
            updatePolishAdvanced()
            return false
        }
    }

    @objc func changePolishOptions(_ sender: NSSegmentedControl) {
        let strengths = PolishStrength.allCases
        let scenarios = PolishScenario.allCases
        guard strengths.indices.contains(polishStrengthButtons.selectedSegment),
              scenarios.indices.contains(polishScenarioButtons.selectedSegment) else { return }
        let strength = strengths[polishStrengthButtons.selectedSegment]
        let scenario = scenarios[polishScenarioButtons.selectedSegment]
        let outputs = PolishOutput.allCases
        let outputIndex = polishOutputPicker?.indexOfSelectedItem ?? -1
        let output = outputs.indices.contains(outputIndex) ? outputs[outputIndex] : DeepSeekConfiguration.options.output
        applyPolishPreferences(
            LinkPolishPreferences(
                enabled: DeepSeekConfiguration.enabled,
                options: PolishOptions(strength: strength, scenario: scenario, output: output)
            ),
            confirmingSave: false
        )
    }

    @objc func changePolishOutput(_ sender: NSPopUpButton) {
        changePolishOptions(polishScenarioButtons)
    }

    /// 终端命令不使用强度与场景，禁用对应控件以免误以为生效。
    func updatePolishOptionControls(_ options: PolishOptions) {
        let usesStyle = options.output != .command
        polishStrengthButtons?.isEnabled = usesStyle
        polishScenarioButtons?.isEnabled = usesStyle
        polishOptionsHint?.stringValue = options.summary
    }

    @objc func toggleLivePreview() {
        UserDefaults.standard.set(livePreviewCheck.state == .on, forKey: "livePreview")
        IMicLog.write("mac.settings", "livePreview=\(livePreviewCheck.state == .on)")
        sendFeatureSettings()
    }

    @objc func togglePolishSweep() {
        UserDefaults.standard.set(polishSweepCheck.state == .on, forKey: "polishSweep")
        if polishSweepCheck.state == .on { TextPolishEffect.prewarm() }
        // Changing visual preferences must not discard an in-flight final result.
        if polishSweepCheck.state == .off {
            polishSweepHint.stringValue = "已关闭扫光；仍等待润色结束后一次回写，失败保留百炼原文。"
        }
    }

    @objc func requestSweepPermission() {
        guard preview == nil else { return }
        let allowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        polishSweepHint.stringValue = allowed
            ? "屏幕录制已允许。截图与 OCR 只在本机处理，定位失败不阻塞输入。"
            : "请在系统设置 → 隐私与安全性 → 屏幕录制中允许 iMic；未授权时仍正常输入。"
    }

    @objc func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleBLEFallback() {
        UserDefaults.standard.set(bleFallbackCheck.state == .on, forKey: "bleFallback")
        IMicLog.write("mac.settings", "bleFallback=\(bleFallbackCheck.state == .on)")
        if bleFallbackCheck.state == .on {
            startBLEBridge()
        } else {
            bleBridge?.stop()
            bleBridge = nil
        }
    }

    @objc func toggleAdvanced() {
        let visible = advancedButton.state == .on
        advanced.isHidden = !visible
        advancedButton.image = NSImage(
            systemSymbolName: visible ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        advancedButton.setAccessibilityLabel(visible ? "收起高级设置" : "展开高级设置")
        if let window = settingsWindow {
            var frame = window.frame
            let delta: CGFloat = visible ? 120 : -120
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true)
        }
    }

    @objc func saveSettings() {
        let cleanedKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint.stringValue),
              url.scheme == "wss", url.host?.isEmpty == false,
              url.path == "/api-ws/v1/inference",
              model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == ASRConfiguration.model
        else {
            saveFeedback.textColor = .systemRed
            saveFeedback.stringValue = "请检查模型和 wss:// 服务地址"
            return
        }
        guard validatePolishSettings() else { return }
        if preview == nil {
            if !cleanedKey.isEmpty {
                guard MicCredentials.save(cleanedKey) else {
                    saveFeedback.textColor = .systemRed
                    saveFeedback.stringValue = "Key 保存失败，请检查文件权限"
                    return
                }
            }
            UserDefaults.standard.set(model.stringValue, forKey: "asrModel")
            UserDefaults.standard.set(endpoint.stringValue, forKey: "asrEndpoint")
        }
        for (provider, value) in polishDrafts {
            if provider != .bailian, (!value.key.isEmpty || !PolishCredentials.load(for: provider).isEmpty),
               !PolishCredentials.save(value.key, for: provider) {
                saveFeedback.textColor = .systemRed
                saveFeedback.stringValue = "\(provider.title) Key 保存失败，请检查 ~/.zshrc 权限"
                return
            }
        }
        for (provider, value) in polishDrafts {
            DeepSeekConfiguration.save(provider: provider, model: value.model, endpoint: value.endpoint)
        }
        UserDefaults.standard.set(editingPolishProvider.rawValue, forKey: "polishProvider")
        UserDefaults.standard.set(deepseekCheck.state == .on, forKey: "deepseekEnabled")
        loadPolishProviderFields()
        saveFeedback.textColor = .secondaryLabelColor
        saveFeedback.stringValue = "已保存"
        refreshUI()
    }

    @objc func permissions() {
        guard let applicationURL = PermissionApplication.current else {
            setStatus("请从「应用程序」打开 iMic 后设置权限")
            return
        }
        if permissionGuide == nil {
            permissionGuide = InputPermissionGuide(
                applicationURL: applicationURL,
                preview: preview != nil,
                check: { [weak self] in
                    self?.inputPermissionState() ?? InputPermissionState(accessibility: false, posting: false)
                },
                request: { [weak self] in self?.requestInputAuthorization() }
            )
        }
        permissionGuide?.refreshState()
        permissionGuide?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestInputAuthorization() {
        guard preview == nil else { return }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
        } else if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    @objc func testInput() {
        guard preview == nil else { saveFeedback.stringValue = "预览模式不发送文字"; return }
        guard currentSession == nil else { setStatus("请先结束当前录音"); return }
        guard inputAllowed() else { permissions(); return }
        setStatus("3 秒后输入，请点击目标文本框")
        saveFeedback.stringValue = "请在 3 秒内点击目标文本框"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.currentSession == nil else { return }
            let app = NSWorkspace.shared.frontmostApplication
            self.targetPID = app?.processIdentifier == getpid() ? nil : app?.processIdentifier
            self.targetAppName = app?.localizedName
            self.committedInputText = ""
            self.liveInputBlocked = false
            self.inputTarget = self.targetPID.map { InputTarget.capture(pid: $0) }
            self.inputMismatchSince = nil
            self.completeInputTest()
        }
    }

    private func completeInputTest() {
        guard currentSession == nil else { return }
        guard let succeeded = insert("iMic 输入测试") else {
            scheduleInput { [weak self] in self?.completeInputTest() }
            return
        }
        inputTarget = nil
        saveFeedback.stringValue = succeeded ? "测试已投递" : "未自动输入，请检查目标位置与权限"
    }

    @objc func forgetDevice(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        store.forget(deviceID: id)
        if !store.isPaired { link.disconnect() }
        rebuildPairedList()
        refreshUI()
    }

    @objc func forgetAllDevices() {
        store.forgetAll()
        link.disconnect()
        rebuildPairedList()
        refreshUI()
    }

    @objc func quit() {
        asr?.cancel()
        link.stop()
        bleBridge?.stop()
        NSApp.terminate(nil)
    }

    func setStatus(_ text: String, transient: Bool = false) {
        IMicLog.write("mac.ui", "status=\(text) transient=\(transient)")
        stateLabel.stringValue = text
        stateLabel.toolTip = text
        statusResetWork?.cancel()
        statusResetWork = nil
        if transient {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if let name = self.connectedName {
                    self.setStatus("已连接 \(name)")
                } else {
                    self.setStatus("等待 iPhone 连接")
                }
            }
            statusResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
        if headless { emit("STATUS \(text)") }
    }

    func cuePairing() {
        guard let cue = cueView else { return }
        cue.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            cue.animator().alphaValue = 1
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.7
                cue.animator().alphaValue = 0.15
            }
        }
        NSSound(named: "Ping")?.play()
    }

    // MARK: - Preview

    private func showPreview(_ preview: String) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        connectedName = preview == "ready" || preview == "result" || preview == "listening" || preview == "processing" ? "iPhone 17 Pro" : nil
        switch preview {
        case "pairing":
            pairingRequested = true
            setStatus("在 iPhone 输入配对码")
            pairHint.stringValue = "在 iPhone 输入这个配对码"
        case "ready":
            setStatus("已连接 iPhone 17 Pro")
        case "listening":
            setStatus("正在听…")
            currentSession = 1
            samples = 12_800
            frames = 40
            meter.prepareForSession(currentSession)
            meter.doubleValue = 0.62
            elapsedLabel.stringValue = "0.8 s"
        case "processing":
            setStatus("正在整理文字…")
            currentSession = 1
            stopAt = Date()
            samples = 22_400
        case "result":
            setStatus("已输入 · Craft")
            transcriptText = "把今天讨论的交互细节整理成一页说明，重点保留按住说话、松开即输入的节奏。"
            lastInsertSucceeded = true
            samples = 51_200
        case "permission":
            setStatus("文字已保留 · 请允许自动输入")
            transcriptText = "文字已经识别完成，可以先复制使用。"
            automatic.state = .on
        default:
            setStatus("等待 iPhone 连接")
        }
        store.overrideCode("482916")
        refreshUI()
        updateStatusBar()
        if preview == "settings" { showSettings() }
        show()
    }
}

// MARK: - Entry point

if headlessMode || previewMode != nil {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 直接运行可执行文件时不会经过 Launch Services，需要手动补齐启动通知。
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    withExtendedLifetime(delegate) { app.run() }
} else {
    let instanceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/iMic/instance.lock")
    let instanceLock = SingleInstanceLock(url: instanceURL)
    let reopenNotification = Notification.Name("com.drafffffff.imic.reopen.\(getuid())")
    do {
        if try !instanceLock.acquire() {
            if let pid = instanceLock.ownerPID {
                DistributedNotificationCenter.default().postNotificationName(
                    reopenNotification,
                    object: String(pid),
                    userInfo: ["showPermissions": CommandLine.arguments.contains("--show-permissions")],
                    deliverImmediately: true
                )
                if let running = NSRunningApplication(processIdentifier: pid),
                   running.bundleIdentifier == "com.drafffffff.imic" {
                    running.activate(options: [.activateAllWindows])
                }
            }
            exit(0)
        }
    } catch {
        fputs("iMic could not acquire its instance lock: \(error)\n", stderr)
        exit(1)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
    instanceLock.release()
}
