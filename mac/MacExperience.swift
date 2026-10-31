import AppKit

extension AppDelegate: NSMenuDelegate {
    /// Called only at launch; explicit reopen actions always show the main window.
    func presentLaunchWindows(needsSetup: Bool) {
        if needsSetup { show(); showSetup() }
        else if MacPreferences.defaults.bool(forKey: "showMainWindowOnLaunch") { show() }
    }

    func buildStatusMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            value.target = self; return value
        }
        menuStatusItem = item("○ 等待 iPhone 连接", nil); menuStatusItem.isEnabled = false
        menu.addItem(menuStatusItem)
        menuIssueAction = item("打开设置", #selector(performIssueAction)); menuIssueAction.isHidden = true
        menu.addItem(menuIssueAction)
        menuPolishItem = item("AI 润色", #selector(toggleMenuPolish)); menu.addItem(menuPolishItem)
        let modes = NSMenu(); modes.autoenablesItems = false
        menuModeItems = PolishMode.allCases.enumerated().map { index, mode in
            let value = item(mode.title, #selector(selectMenuMode(_:))); value.tag = index
            modes.addItem(value); return value
        }
        let mode = item("转换模式", nil); mode.submenu = modes; menu.addItem(mode)
        menu.addItem(.separator())
        menu.addItem(item("打开 iMic", #selector(show)))
        menu.addItem(item("设置…", #selector(showSettings), key: ","))
        menu.addItem(item("iMic 官网与帮助…", #selector(openWebsite)))
        menu.addItem(item("检查更新…", #selector(checkForUpdates)))
        menu.addItem(item("配对新 iPhone…", #selector(pairNewPhone)))
        menu.addItem(.separator())
        menu.addItem(item("退出 iMic", #selector(quit), key: "q"))
        statusMenu = menu
        let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = menu
        appMenu.addItem(root); NSApp.mainMenu = appMenu
        refreshStatusMenu()
    }

    func popUpStatusMenu() {
        guard let button = statusItem.button else { return }
        statusMenu.popUp(positioning: menuStatusItem, at: NSPoint(x: 0, y: button.bounds.minY - 12), in: button)
    }

    func menuWillOpen(_ menu: NSMenu) { refreshInputPermission(); refreshStatusMenu() }

    func refreshStatusMenu() {
        guard menuStatusItem != nil else { return }
        if connectionRecovered {
            menuStatusItem.title = "连接检查通过 · 请重新录音"
        } else if let cloudFailure {
            menuStatusItem.title = cloudFailure.title(service: issueServiceName)
        } else if automatic.state == .on && !inputPermissionState().allowed {
            menuStatusItem.title = "需要设置：辅助功能"
        } else if let connectedName {
            menuStatusItem.title = "● 已连接 \(connectedName)"
        } else { menuStatusItem.title = "○ 等待 iPhone 连接" }
        menuIssueAction?.isHidden = cloudFailure == nil
        menuIssueAction?.title = cloudFailure == .network ? "重试连接" : "打开设置"
        menuIssueAction?.isEnabled = currentSession == nil && connectionCheck == nil
        menuPolishItem.state = DeepSeekConfiguration.enabled ? .on : .off
        for (index, item) in menuModeItems.enumerated() {
            item.state = PolishMode.allCases[index] == DeepSeekConfiguration.options.mode ? .on : .off
        }
    }

    @objc func openWebsite() {
        guard preview == nil else { return }
        NSWorkspace.shared.open(SetupLinks.website)
    }

    @objc func toggleMenuPolish() {
        applyPolishPreferences(LinkPolishPreferences(enabled: !DeepSeekConfiguration.enabled,
            options: DeepSeekConfiguration.options), confirmingSave: false)
    }
    @objc func selectMenuMode(_ sender: NSMenuItem) {
        guard PolishMode.allCases.indices.contains(sender.tag) else { return }
        let options = DeepSeekConfiguration.options
        applyPolishPreferences(LinkPolishPreferences(enabled: DeepSeekConfiguration.enabled,
            options: PolishOptions(output: options.output, mode: PolishMode.allCases[sender.tag], tone: options.tone)), confirmingSave: false)
    }
    @objc func pairNewPhone() {
        pairPanelVisible = true
        refreshUI(); show()
    }
    @objc func hidePairCode() { pairPanelVisible = false; pairingRequested = false; refreshUI() }

    var issueServiceName: String {
        switch issueProvider {
        case .bailian: return "百炼"
        case .deepseek: return "DeepSeek"
        case .custom: return "自定义服务"
        }
    }
    func showCloudFailure(_ failure: CloudFailure, provider: PolishProvider, recognition: Bool = false) {
        connectionRecovered = false
        cloudFailure = failure; issueProvider = provider; issueIsRecognition = recognition
        refreshCloudFailure(); refreshStatusMenu()
    }
    func clearCloudFailure() {
        issueGeneration = UUID(); connectionCheck?.cancel(); connectionCheck = nil
        cloudFailure = nil; connectionRecovered = false; polishFallback = false; polishFallbackIsCommand = false
        refreshCloudFailure(); refreshStatusMenu()
    }
    func refreshCloudFailure() {
        guard issueRow != nil else { return }
        issueRow.isHidden = cloudFailure == nil && !connectionRecovered
        if connectionRecovered {
            issueLabel.stringValue = "连接检查通过，请在 iPhone 重新录音。"
            issueButton.isHidden = true
            return
        }
        guard let cloudFailure else { return }
        issueButton.isHidden = false
        if polishFallback && currentSession == nil {
            issueLabel.stringValue = polishFallbackIsCommand
                ? "润色失败，已保留为安全注释。"
                : lastInsertSucceeded ? "润色失败，已输入原文。" : "润色失败，原文已保留，可复制。"
            issueLabel.stringValue += " " + cloudFailure.title(service: issueServiceName)
        } else { issueLabel.stringValue = cloudFailure.title(service: issueServiceName) }
        let console = issueProvider == .bailian && cloudFailure.needsConsole
        issueButton.title = console ? "打开百炼控制台" : cloudFailure == .network ? "重试连接" : "打开设置"
        issueButton.action = console ? #selector(openFailureConsole) : #selector(performIssueAction)
        issueButton.setAccessibilityLabel(issueButton.title)
        issueButton.isEnabled = currentSession == nil && connectionCheck == nil
        issueButton.toolTip = cloudFailure == .network ? "检查服务连接；本次音频不会重发，请在连接恢复后重新录音。" : nil
    }
    @objc private func openFailureConsole() {
        guard preview == nil else { return }
        NSWorkspace.shared.open(SetupLinks.bailianKeys)
    }
    func markConnectionRecovered() {
        clearCloudFailure(); connectionRecovered = true
        refreshCloudFailure(); refreshStatusMenu()
    }
    @objc func performIssueAction() {
        guard currentSession == nil, let failure = cloudFailure, connectionCheck == nil else { return }
        guard failure == .network else {
            settingsCoordinator?.select(failure == .address || issueProvider != .bailian ? .advanced : .bailian)
            showSettings(); return
        }
        // Audio is intentionally not retained. Retry only a read-only connectivity request.
        guard preview == nil else { markConnectionRecovered(); return }
        let generation = UUID(); issueGeneration = generation
        let provider = issueProvider
        let recognition = issueIsRecognition
        let credential = recognition ? key.stringValue : PolishCredentials.load(for: provider)
        let address = recognition ? endpoint.stringValue : DeepSeekConfiguration.endpoint(for: provider)
        let completion: (Result<Void, SettingsValidation.Failure>) -> Void = { [weak self] result in
            guard let self, self.issueGeneration == generation else { return }
            self.connectionCheck = nil
            // A response for an older credential/address cannot describe the current service.
            let currentKey = recognition ? self.key.stringValue : PolishCredentials.load(for: provider)
            let currentAddress = recognition ? self.endpoint.stringValue : DeepSeekConfiguration.endpoint(for: provider)
            guard currentKey == credential, currentAddress == address else { self.clearCloudFailure(); return }
            switch result {
            case .success:
                self.markConnectionRecovered()
            case .failure(let error):
                let issue: CloudFailure
                switch error {
                case .bailian(let reason): issue = reason == .network ? .network : .bailian(reason)
                case .rejected: issue = .key
                case .network: issue = .network
                case .http: issue = .service
                }
                self.showCloudFailure(issue, provider: provider, recognition: recognition)
            }
        }
        issueLabel.stringValue = "正在检查连接…"
        if recognition {
            connectionCheck = SettingsValidation.runBailian(key: credential, endpoint: address, completion: completion)
        } else if let request = try? SettingsValidation.request(provider: provider, key: credential,
                    model: DeepSeekConfiguration.modelName(for: provider), endpoint: address) {
            connectionCheck = SettingsValidation.run(request, completion: completion)
        } else { showCloudFailure(credential.isEmpty ? .key : .address, provider: provider); return }
        if connectionCheck != nil {
            refreshCloudFailure(); refreshStatusMenu()
            issueLabel.stringValue = "正在检查连接…"
        }
    }
}
