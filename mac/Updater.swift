import AppKit
import Sparkle

/// All Sparkle entry points run on the main thread. The same gate covers setup,
/// recording, ASR/polish, sweep animation and delivery, including the relaunch race.
final class MacUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var app: AppDelegate?
    private(set) var controller: SPUStandardUpdaterController!
    private var started = false
    private var pendingCheck = false
    private var pendingPresentation = false
    private var pendingRelaunch: (() -> Void)?
    private var pendingMessage: String?
    private var manualCheck = false
    private var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    static var testing: Bool {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "IMicUpdaterTest") as? Bool == true
        #else
        return false
        #endif
    }
    static var configured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }

    var idle: Bool { app?.updateIsIdle == true }
    var automaticallyChecks: Bool { Self.configured && controller.updater.automaticallyChecksForUpdates }
    var automaticallyInstalls: Bool { Self.configured && controller.updater.automaticallyDownloadsUpdates }
    func setAutomaticChecks(_ value: Bool) { controller.updater.automaticallyChecksForUpdates = value && Self.configured }
    func setAutomaticInstalls(_ value: Bool) { controller.updater.automaticallyDownloadsUpdates = value && Self.configured }

    func start() {
        guard timer == nil, (app?.preview == nil || Self.testing) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.drain() }
        drain()
    }
    deinit { timer?.invalidate() }

    @objc func check() {
        guard (app?.preview == nil || Self.testing) else { return }
        if !Self.configured { pendingMessage = "此构建尚未配置更新公钥，请等待发布者提供正式版本。" }
        else { pendingCheck = true }
        start()
        drain()
    }

    func drain() {
        guard idle else { return }
        if let relaunch = pendingRelaunch {
            pendingRelaunch = nil
            app?.prepareForUpdateRestart()
            relaunch()
            return
        }
        if let message = pendingMessage {
            pendingMessage = nil
            let alert = NSAlert(); alert.messageText = "iMic 更新"; alert.informativeText = message
            alert.runModal()
        }
        guard Self.configured else { return }
        if !started {
            started = true
            controller.updater.sendsSystemProfile = false
            controller.startUpdater()
            // Do not allow an old defaults override to redirect release builds.
            controller.updater.clearFeedURLFromUserDefaults()
        }
        if pendingPresentation {
            pendingPresentation = false
            controller.checkForUpdates(nil)
        } else if pendingCheck && !controller.updater.sessionInProgress {
            pendingCheck = false; manualCheck = true
            // Checking itself must not open a progress/error window during an input
            // session that starts while the network request is still in flight.
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--debug-update-feed=") }) {
            let url = String(value.dropFirst("--debug-update-feed=".count))
            if let parsed = URL(string: url), parsed.scheme == "http", parsed.host == "127.0.0.1" { return url }
        }
        #endif
        return "https://drafffffff.github.io/iMic/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard idle else {
            pendingCheck = true
            throw NSError(domain: "iMic.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "等待本轮输入和设置向导结束后检查更新。"])
        }
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Even a manual request uses a background check first, so this gate applies
        // when the feed finishes loading after the user has started speaking.
        false
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingPresentation = true }
        manualCheck = false
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if manualCheck, let error { pendingMessage = (error as NSError).localizedDescription }
        manualCheck = false
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if !idle { pendingRelaunch = installHandler; return true }
        app?.prepareForUpdateRestart()
        return false
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { app?.prepareForUpdateRestart() }
}

extension AppDelegate {
    var updateIsIdle: Bool {
        #if DEBUG
        if let marker = CommandLine.arguments.first(where: { $0.hasPrefix("--debug-update-busy-file=") }),
           FileManager.default.fileExists(atPath: String(marker.dropFirst("--debug-update-busy-file=".count))) { return false }
        #endif
        return currentSession == nil && !inserting && !clearingInput && !polishEffect.blocksGestures
            && polishTask == nil && inputWork == nil
            && setupWizard?.window?.isVisible != true && SetupProgress.saved() == nil
    }
    func prepareForUpdateRestart() {
        // Called only after the idle gate passes; disconnect before Sparkle terminates.
        link.disconnect()
        link.stop()
        _ = link.isConnected // Serial-queue barrier: the disconnect completes before exit.
        bleBridge?.stop()
    }
    @objc func checkForUpdates() { macUpdater.check() }
}
