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
        button.setAccessibilityLabel(title)
        return button
    }

    func linkButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = nil
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(title)
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

        buildStatusMenu()

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
            symbolButton("gearshape", L10n.text("Settings"), #selector(showSettings)),
            symbolButton("ellipsis", L10n.text("More actions"), #selector(statusMenuButton))
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

        let pairActions = row([linkButton(L10n.text("Copy pairing code"), #selector(copyPairCode)),
            linkButton(L10n.text("Regenerate"), #selector(rotatePairCode))], spacing: 16)
        pairCollapseButton = linkButton(L10n.text("Collapse"), #selector(hidePairCode))
        pairActions.addArrangedSubview(pairCollapseButton)
        pairPanel.addArrangedSubview(pairActions)
        firstPairSteps.stringValue = L10n.text("01   Install and open iMic on your iPhone\n\n02   Connect your iPhone and Mac to the same Wi-Fi\n\n03   Tap the computer name at the top of your iPhone and enter the pairing code")
        firstPairSteps.font = .systemFont(ofSize: 13)
        firstPairSteps.textColor = .imicMuted
        firstPairSteps.preferredMaxLayoutWidth = 388
        waitingPanel.orientation = .vertical; waitingPanel.alignment = .leading; waitingPanel.spacing = 18
        let waitingTitle = label(L10n.text("Waiting for your iPhone"), size: 22, color: .imicIvory, weight: .semibold)
        pairedNames.font = .systemFont(ofSize: 14, weight: .medium)
        pairedNames.textColor = .imicIvory; pairedNames.preferredMaxLayoutWidth = 388
        pairedNames.maximumNumberOfLines = 3; pairedNames.lineBreakMode = .byTruncatingTail
        let waitingHint = label(L10n.text("Open iMic on your iPhone to connect automatically.\nKeep both devices on the same network."), size: 12)
        for view in [waitingTitle, pairedNames, waitingHint,
                     linkButton(L10n.text("Pair a new iPhone…"), #selector(pairNewPhone))] {
            waitingPanel.addArrangedSubview(view)
        }
        waitingPanel.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 18, right: 0)

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
        transcript.setAccessibilityLabel(L10n.text("Recognized text"))
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
        meter.setAccessibilityLabel(L10n.text("Received volume"))
        meter.setAccessibilityHelp(L10n.text("Shows actual volume over the last 1.92 seconds from left to right, rather than a frequency distribution."))
        meter.toolTip = L10n.text("Received volume · Last 1.92 seconds")
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

        issueLabel.font = .systemFont(ofSize: 11); issueLabel.textColor = .imicMuted
        issueLabel.preferredMaxLayoutWidth = 275
        issueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        issueButton = linkButton(L10n.text("Open Settings"), #selector(performIssueAction))
        issueButton.setContentHuggingPriority(.required, for: .horizontal)
        issueRow = row([issueLabel, issueButton], spacing: 12)
        issueRow.isHidden = true

        // Controls
        automatic.target = self
        automatic.action = #selector(toggleAutoInput)
        automatic.font = .systemFont(ofSize: 12)
        automatic.contentTintColor = .imicOrange
        automatic.title = L10n.text("Type into the active app after recognition")
        copyButton = button(L10n.text("Copy text"), #selector(copyText))
        copyButton.isEnabled = false
        let controlsSpacer = NSView()
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsRow = row([controlsSpacer, copyButton], spacing: 12)

        permissionState.font = .systemFont(ofSize: 11)
        permissionState.textColor = .imicMuted
        permissionState.maximumNumberOfLines = 2
        permissionButton = linkButton(L10n.text("Continue setup…"), #selector(showSetupAction))
        let permissionSpacer = NSView()
        permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionRow = row([permissionState, permissionSpacer, permissionButton], spacing: 10)

        let flexible = NSView()
        flexible.setContentHuggingPriority(.init(1), for: .vertical)
        flexible.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let stack = column([
            header, cueView!, waitingPanel, pairPanel, firstPairSteps, stageStack, flexible, issueRow!, controlsRow!, permissionRow!
        ], spacing: 16)
        stack.detachesHiddenViews = true
        attach(stack, to: content, inset: 26, top: 46)
        for view in [header, cueView!, waitingPanel, pairPanel, firstPairSteps, stageStack, issueRow!, controlsRow!, permissionRow!] as [NSView] {
            fullWidth(view, in: stack)
        }
        flexible.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        buildSettings()
        refreshUI()
    }

    @objc func statusMenuButton(_ sender: NSButton) {
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    // MARK: - State rendering

    func refreshUI() {
        guard window != nil else { return }
        let connected = connectedName != nil
        let revealingPairCode = pairPanelVisible && currentSession == nil
        let showStage = (connected || !transcriptText.isEmpty || currentSession != nil) && !revealingPairCode
        let pairedWaiting = store.isPaired && !connected && transcriptText.isEmpty && currentSession == nil
        waitingPanel.isHidden = !pairedWaiting
        pairedNames.stringValue = store.devices.prefix(3).map(\.name).joined(separator: " · ")
            + (store.devices.count > 3 ? L10n.text(" · %@ more (see iPhone settings)", L10n.argument(store.devices.count - 3)) : "")
        pairCollapseButton.isHidden = !store.isPaired && !connected && transcriptText.isEmpty
        pairPanel.isHidden = showStage || (pairedWaiting && !pairPanelVisible && !pairingRequested)
        firstPairSteps.isHidden = showStage || store.isPaired || connected
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
            ? L10n.text("Enter this pairing code on your iPhone to establish an encrypted connection.")
            : store.isPaired
                ? L10n.text("Open iMic on your iPhone to connect automatically. New devices use the pairing code above.")
                : L10n.text("Open iMic on your iPhone, tap the computer name at the top, and enter this pairing code.")

        copyButton.title = L10n.text("Copy text")
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
            stageTitle.stringValue = L10n.text("Listening…")
            stageHint.stringValue = L10n.text("Release on your iPhone to recognize. Slide up to cancel.")
            activityHint.stringValue = L10n.text("Received volume · 16 kHz")
        } else if processing {
            stageTitle.stringValue = L10n.text("Preparing text…")
            stageHint.stringValue = L10n.text("Recognizing and polishing your voice. Please wait. Existing text will be kept.")
            activityHint.stringValue = L10n.text("Recognizing")
            spinner.startAnimation(nil)
        } else if hasText {
            stageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
            stageTitle.stringValue = lastInsertSucceeded ? L10n.text("Typed") : L10n.text("Recognition complete")
            if lastInsertSucceeded {
                stageHint.stringValue = L10n.text("Text typed into %@. You can also copy it to the clipboard.", L10n.argument(targetAppName ?? L10n.text("the active app")))
            } else {
                stageHint.stringValue = L10n.text("Your text is kept here. Click Copy to use it.")
            }
            stageTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        } else {
            stageTitle.font = .systemFont(ofSize: 20, weight: .semibold)
            if key.stringValue.isEmpty {
                stageTitle.stringValue = L10n.text("Configure your Model Studio API Key first##b5e24567")
                stageHint.stringValue = L10n.text("Open setup and paste your Model Studio Key to get started.")
            } else {
                stageTitle.stringValue = L10n.text("Hold to speak on your iPhone")
                stageHint.stringValue = L10n.text("Release to type into the active app automatically.")
            }
        }
        if !processing { spinner.stopAnimation(nil) }

        refreshInputPermission()
        updateStatusBar()
        refreshStatusMenu()
        refreshCloudFailure()
        if settingsWindow != nil { rebuildPairedList() }
    }

    func refreshInputPermission() {
        let state = inputPermissionState()
        let keyMissing = key.stringValue.isEmpty
        permissionState.stringValue = keyMissing ? L10n.text("No Model Studio API Key yet")
            : state.allowed ? "" : (state.accessibility ? L10n.text("Typing permission has not taken effect") : L10n.text("Accessibility permission required"))
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
