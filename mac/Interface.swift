import AppKit
import ApplicationServices

extension NSColor {
    static let imicInk = NSColor(srgbRed: 0.035, green: 0.035, blue: 0.035, alpha: 1)
    static let imicCard = NSColor(srgbRed: 0.062, green: 0.062, blue: 0.062, alpha: 1)
    static let imicOrange = NSColor(srgbRed: 1.0, green: 0.29, blue: 0.0, alpha: 1)
    static let imicIvory = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1)
    static let imicMuted = NSColor(srgbRed: 0.55, green: 0.54, blue: 0.51, alpha: 1)
    static let imicHairline = NSColor(white: 1, alpha: 0.09)
}

final class InkView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.imicInk.setFill()
        dirtyRect.fill()
    }
}

/// Scroll document that starts at the top.
final class FlippedInkView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.imicInk.setFill()
        dirtyRect.fill()
    }
}

/// A fixed 1.92-second history of received 20 ms RMS frames, not a frequency spectrum.
final class AudioActivityView: NSControl {
    private static let frameCount = 96
    // Input is RMS / 7000; this floor is approximately -60 dBFS for signed 16-bit PCM.
    private static let noiseFloor = 0.0047
    private var levels = [Double](repeating: 0, count: AudioActivityView.frameCount)
    private var nextFrame = 0
    private var latestLevel = 0.0
    private var sessionID: Int?
    private var hasFrames = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override var doubleValue: Double {
        get { latestLevel }
        set {
            latestLevel = newValue.isFinite ? min(1, max(0, newValue)) : 0
            let gate = min(1, max(0, (latestLevel - Self.noiseFloor) / Self.noiseFloor))
            let softGate = gate * gate * (3 - 2 * gate)
            levels[nextFrame] = sqrt(latestLevel) * softGate
            nextFrame = (nextFrame + 1) % Self.frameCount
            hasFrames = true
            needsDisplay = true
        }
    }

    func prepareForSession(_ session: Int?) {
        guard sessionID != session else { return }
        sessionID = session
        reset()
    }

    func reset() {
        guard hasFrames else { return }
        for index in levels.indices { levels[index] = 0 }
        nextFrame = 0
        latestLevel = 0
        hasFrames = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let plot = bounds.insetBy(dx: 1, dy: 3)
        guard plot.width > 0, plot.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        context.setFillColor(NSColor.imicHairline.cgColor)
        context.fill(CGRect(x: plot.minX, y: plot.midY - pixel / 2,
                            width: plot.width, height: pixel))

        let step = plot.width / CGFloat(Self.frameCount)
        let barWidth = min(step, min(2.5, step * 0.68))
        context.setFillColor(NSColor.imicOrange.cgColor)
        for column in 0..<Self.frameCount {
            let level = levels[(nextFrame + column) % Self.frameCount]
            guard level > 0 else { continue }
            let height = plot.height * CGFloat(level)
            let x = plot.minX + (CGFloat(column) + 0.5) * step - barWidth / 2
            context.fill(CGRect(x: x, y: plot.midY - height / 2,
                                width: barWidth, height: height))
        }
    }
}

extension AppDelegate {
    // MARK: - Helpers

    func label(_ text: String, size: CGFloat = 13, color: NSColor = .imicMuted,
               mono: Bool = false, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        return field
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func linkButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = nil
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }

    func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.isBordered = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    func fullWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func checkbox(_ title: String, _ action: Selector, key: String, defaultValue: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel(title)
        button.contentTintColor = nil
        button.state = (MacPreferences.defaults.object(forKey: key) as? Bool ?? defaultValue) ? .on : .off
        return button
    }

    func divider() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func attach(_ stack: NSStackView, to content: NSView, inset: CGFloat = 26, top: CGFloat = 50) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: top),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func overline(_ text: String) -> NSTextField {
        let field = label(text, size: 10, color: .imicOrange, mono: true, weight: .bold)
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.imicOrange,
                .kern: 2.2
            ]
        )
        return field
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Main window

    func buildUI() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MicStatusBarIcons.image(MicStatusBarPresentation(phase: .offline))
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("iMic")

        let menu = NSMenu()
        menu.addItem(menuItem("打开 iMic", #selector(show)))
        menu.addItem(menuItem("设置向导…", #selector(showSetupAction)))
        menu.addItem(menuItem("复制配对码", #selector(copyPairCode)))
        menu.addItem(menuItem("重新生成配对码", #selector(rotatePairCode)))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 iMic", #selector(quit), "q"))
        statusMenu = menu
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = menu
        appMenu.addItem(root)
        NSApp.mainMenu = appMenu

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "iMic"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .imicInk
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 440, height: 560)
        window.center()
        let content = InkView()
        window.contentView = content

        // Header
        let logo = NSImageView(image: MicBrand.logo(size: 26))
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 26),
            logo.heightAnchor.constraint(equalToConstant: 26)
        ])
        let wordmark = label("iMic", size: 18, color: .imicIvory, mono: true, weight: .semibold)
        wordmark.attributedStringValue = NSAttributedString(
            string: "iMic",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.imicIvory,
                .kern: 0.6
            ]
        )
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = .imicOrange
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.alignment = .right
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([
            logo, wordmark, stateLabel, headerSpacer,
            symbolButton("gearshape", "设置", #selector(showSettings)),
            symbolButton("ellipsis", "更多操作", #selector(statusMenuButton))
        ], spacing: 9)
        stateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        cueView = NSView()
        cueView.wantsLayer = true
        cueView.layer?.backgroundColor = NSColor.imicOrange.cgColor
        cueView.alphaValue = 0
        cueView.heightAnchor.constraint(equalToConstant: 3).isActive = true

        // Pair card
        pairPanel.orientation = .vertical
        pairPanel.alignment = .leading
        pairPanel.spacing = 12
        pairPanel.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        pairPanel.wantsLayer = true
        pairPanel.layer?.backgroundColor = NSColor.imicCard.cgColor
        pairPanel.layer?.cornerRadius = 12
        pairPanel.layer?.borderWidth = 1
        pairPanel.layer?.borderColor = NSColor.imicOrange.withAlphaComponent(0.32).cgColor

        let eyebrow = overline("PAIR IPHONE")
        pairCodeLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        pairCodeLabel.textColor = .imicOrange
        pairHint.font = .systemFont(ofSize: 12)
        pairHint.textColor = .imicMuted
        pairHint.maximumNumberOfLines = 2
        pairHint.lineBreakMode = .byWordWrapping
        pairHint.preferredMaxLayoutWidth = 380
        for view in [eyebrow, pairCodeLabel, pairHint] as [NSView] {
            pairPanel.addArrangedSubview(view)
        }

        // Stage
        emptyMark.image = MicBrand.logo(size: 42)
        emptyMark.imageScaling = .scaleProportionallyUpOrDown
        emptyMark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyMark.widthAnchor.constraint(equalToConstant: 46),
            emptyMark.heightAnchor.constraint(equalToConstant: 46)
        ])
        stageTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        stageTitle.textColor = .imicIvory
        stageHint.font = .systemFont(ofSize: 12)
        stageHint.textColor = .imicMuted
        stageHint.maximumNumberOfLines = 2
        stageHint.lineBreakMode = .byWordWrapping

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = .systemFont(ofSize: 19, weight: .regular)
        transcript.textColor = .imicIvory
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 0, height: 10)
        transcript.isVerticallyResizable = true
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        transcript.defaultParagraphStyle = paragraph
        transcript.setAccessibilityLabel("识别文字")
        resultScroll.documentView = transcript
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.drawsBackground = false
        resultScroll.borderType = .noBorder
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 168).isActive = true

        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.setContentHuggingPriority(.init(1), for: .horizontal)
        meter.heightAnchor.constraint(equalToConstant: 36).isActive = true
        meter.setAccessibilityLabel("接收音量")
        meter.setAccessibilityHelp("从左到右显示最近 1.92 秒的真实音量；不是频率分布。")
        meter.toolTip = "接收音量 · 最近 1.92 秒"
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .imicMuted
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        activityHint.font = .systemFont(ofSize: 11)
        activityHint.textColor = .imicMuted
        let activityDetails = row([elapsedLabel, spinner, activityHint], spacing: 10)
        activityRow = column([meter, activityDetails], spacing: 8)
        activityRow.detachesHiddenViews = true
        fullWidth(meter, in: activityRow)
        fullWidth(activityDetails, in: activityRow)

        stageStack = column([emptyMark, stageTitle, stageHint, resultScroll, activityRow], spacing: 12)
        stageStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        for view in [stageTitle, stageHint, resultScroll, activityRow!] as [NSView] {
            fullWidth(view, in: stageStack)
        }

        // Controls
        automatic.target = self
        automatic.action = #selector(toggleAutoInput)
        automatic.font = .systemFont(ofSize: 12)
        automatic.contentTintColor = .imicOrange
        automatic.title = "识别后自动输入到当前应用"
        copyButton = button("复制文字", #selector(copyText))
        copyButton.isEnabled = false
        let controlsSpacer = NSView()
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsRow = row([controlsSpacer, copyButton], spacing: 12)

        permissionState.font = .systemFont(ofSize: 11)
        permissionState.textColor = .imicMuted
        permissionState.maximumNumberOfLines = 2
        permissionButton = linkButton("继续设置…", #selector(showSetupAction))
        let permissionSpacer = NSView()
        permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionRow = row([permissionState, permissionSpacer, permissionButton], spacing: 10)

        let flexible = NSView()
        flexible.setContentHuggingPriority(.init(1), for: .vertical)
        flexible.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let stack = column([
            header, cueView!, pairPanel, stageStack, flexible, controlsRow!, permissionRow!
        ], spacing: 16)
        stack.detachesHiddenViews = true
        attach(stack, to: content, inset: 26, top: 46)
        for view in [header, cueView!, pairPanel, stageStack, controlsRow!, permissionRow!] as [NSView] {
            fullWidth(view, in: stack)
        }
        flexible.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        buildSettings()
        refreshUI()
        if preview == nil { window.orderFront(nil) }
    }

    @objc func statusMenuButton(_ sender: NSButton) {
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    // MARK: - State rendering

    func refreshUI() {
        guard window != nil else { return }
        let connected = connectedName != nil
        let showStage = connected || !transcriptText.isEmpty || currentSession != nil
        pairPanel.isHidden = showStage
        stageStack.isHidden = !showStage

        let code = PairingCode.formatted(store.currentCode())
        pairCodeLabel.attributedStringValue = NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 38, weight: .semibold),
                .foregroundColor: NSColor.imicOrange,
                .kern: 4
            ]
        )
        pairHint.stringValue = pairingRequested
            ? "在 iPhone 输入这个配对码，即可建立加密连接。"
            : store.isPaired
                ? "打开 iPhone 上的 iMic 会自动连接。新设备输入上方配对码。"
                : "在 iPhone 上打开 iMic，点顶部的电脑名称，输入这个配对码。"

        copyButton.title = "复制文字"
        copyButton.isEnabled = !transcriptText.isEmpty
        controlsRow?.isHidden = transcriptText.isEmpty
        transcript.string = transcriptText

        let listening = currentSession != nil && stopAt == nil
        let processing = currentSession != nil && stopAt != nil
        let hasText = !transcriptText.isEmpty
        meter.prepareForSession(listening ? currentSession : nil)

        emptyMark.isHidden = hasText || listening || processing
        resultScroll.isHidden = !hasText
        stageTitle.isHidden = false
        stageHint.isHidden = false
        activityRow.isHidden = !(listening || processing)
        spinner.isHidden = !processing
        meter.isHidden = !listening
        elapsedLabel.isHidden = !listening

        if listening {
            stageTitle.stringValue = "正在听…"
            stageHint.stringValue = "在 iPhone 上松开会自动识别。上滑即可取消。"
            activityHint.stringValue = "接收音量 · 16 kHz"
        } else if processing {
            stageTitle.stringValue = "正在整理文字…"
            stageHint.stringValue = "语音正在识别与整理，请稍候；已有文字会保留。"
            activityHint.stringValue = "识别中"
            spinner.startAnimation(nil)
        } else if hasText {
            stageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
            stageTitle.stringValue = lastInsertSucceeded ? "已输入" : "识别完成"
            if lastInsertSucceeded {
                stageHint.stringValue = "文字已填入 \(targetAppName ?? "当前应用")。也可以复制到剪贴板。"
            } else {
                stageHint.stringValue = "文字保留在这里，点击复制即可使用。"
            }
            stageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        } else {
            stageTitle.font = .systemFont(ofSize: 20, weight: .semibold)
            if key.stringValue.isEmpty {
                stageTitle.stringValue = "先配置百炼 API Key"
                stageHint.stringValue = "打开设置向导，粘贴百炼 Key 后就能开始。"
            } else {
                stageTitle.stringValue = "按住 iPhone 说话"
                stageHint.stringValue = "松开后，文字会自动填入当前应用。"
            }
        }
        if !processing { spinner.stopAnimation(nil) }

        refreshInputPermission()
        updateStatusBar()
        if settingsWindow != nil { rebuildPairedList() }
    }

    func refreshInputPermission() {
        let state = inputPermissionState()
        let keyMissing = key.stringValue.isEmpty
        permissionState.stringValue = keyMissing ? "还没有百炼 API Key"
            : state.allowed ? "" : (state.accessibility ? "输入授权尚未生效" : "需要辅助功能权限")
        permissionState.textColor = .imicOrange
        let showRow = keyMissing || (automatic.state == .on && !state.allowed)
        permissionRow?.isHidden = !showRow
        permissionButton?.isHidden = !showRow
        settingsPermissionLabel.stringValue = state.message
        settingsPermissionLabel.textColor = state.allowed ? .imicMuted : .imicOrange
        settingsPermissionButton?.isHidden = state.allowed
        testInputButton?.isEnabled = state.allowed
        setupWizard?.refresh()
    }

    func updateStatusBar() {
        guard let button = statusItem?.button else { return }
        let phase: MicStatusBarPresentation.Phase
        if connectedName == nil {
            phase = pairingRequested ? .pairing : .offline
        } else if currentSession != nil {
            phase = stopAt == nil ? .listening : .processing
        } else {
            phase = .ready
        }
        let presentation = MicStatusBarPresentation(phase: phase)
        let key = "\(phase)" + (presentation.menuTitle)
        if key != lastStatusBarKey {
            lastStatusBarKey = key
            button.image = MicStatusBarIcons.image(presentation)
            button.title = presentation.menuTitle.isEmpty ? "" : " " + presentation.menuTitle
            button.setAccessibilityLabel(presentation.label)
        }
        button.toolTip = presentation.label + (connectedName.map { "\n\($0)" } ?? "")
    }

    // MARK: - Settings

}
