import Foundation
import Network
import CryptoKit
import Security
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    /// 一台 Mac 可通过不同接口或重复 Bonjour 实例出现；身份相同才合并。
    static func coalesced(_ candidates: [DiscoveredMac], preferredEndpoint: NWEndpoint? = nil) -> [DiscoveredMac] {
        var byID: [String: DiscoveredMac] = [:]
        for candidate in candidates {
            guard let existing = byID[candidate.id] else {
                byID[candidate.id] = candidate
                continue
            }
            if candidate.endpoint == preferredEndpoint ||
                (existing.endpoint != preferredEndpoint &&
                 candidate.endpoint.debugDescription < existing.endpoint.debugDescription) {
                byID[candidate.id] = candidate
            }
        }
        return byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct RememberedMac: Identifiable {
    let id: String
    let name: String
}

/// iPhone 侧链路：Bonjour 发现 → Curve25519 握手 → 六位配对码 → 令牌会话。
/// 所有网络状态在私有串行队列，`@Published` 只在主线程更新。
final class LinkClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case connecting(String)
        case needsCode(String)
        case ready(String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var macName: String? {
            switch self {
            case .connecting(let name), .needsCode(let name), .ready(let name): return name
            default: return nil
            }
        }
    }

    enum Transport: String {
        case network
        case bluetooth
    }

    #if DEBUG
    /// Landing-page demo recordings log preview inputs (set by DemoScript; nil otherwise).
    static var demoInputObserver: ((String) -> Void)?
    #endif

    /// Set synchronously before HomeView appears; also gates foreground activation.
    var startDeferred = false
    @Published private(set) var localNetworkDenied = false
    private let practiceLock = NSLock()
    private var practiceDepth = 0

    func setPracticeActive(_ active: Bool) {
        practiceLock.lock()
        practiceDepth = max(0, practiceDepth + (active ? 1 : -1))
        practiceLock.unlock()
    }

    private func permitsSend(_ kind: String) -> Bool {
        practiceLock.lock()
        let blocked = practiceDepth > 0
        practiceLock.unlock()
        if blocked { IMicLog.write("iphone.practice", "blocked send kind=\(kind)") }
        return !blocked
    }

    @Published private(set) var transport: Transport?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var pairingError: String?
    @Published private(set) var pairing = false
    @Published private(set) var hasPairedMac = false
    @Published private(set) var isManualSelection = false
    @Published private(set) var selectedMacID: String?
    @Published private(set) var selectedMacName: String?
    @Published private(set) var rememberedMacs: [RememberedMac] = []
    @Published private(set) var pairedMacIDs: Set<String> = []
    @Published private(set) var polishPreferences: LinkPolishPreferences?
    @Published private(set) var polishPreferencesSupported = false
    /// Mac 是否支持润色输出模式（翻译 / 终端命令）；不支持时设置页不显示该项。
    @Published private(set) var polishOutputSupported = false
    @Published private(set) var polishPreferencesSaving = false
    @Published private(set) var polishPreferencesError: String?

    @Published private(set) var gestureReady = false
    @Published private(set) var gestureSupported = false
    @Published private(set) var clearPending = false
    private var gestureRevision: Int?
    private var remoteGestureRevision: Int?
    private var remoteGestureReady = false
    private var pendingClearRevision: Int?
    var onInputResult: ((LinkMessage) -> Void)?

    var onReady: ((String) -> Void)?
    var onLost: (() -> Void)?
    var onResult: ((LinkMessage) -> Void)?
    var onRemoteState: ((String) -> Void)?
    var onAudioNeed: ((UInt16, UInt32) -> Void)?
    var onSettings: ((Int) -> Void)?

    private let isPreview: Bool
    private let queue = DispatchQueue(label: "imic.link.ios")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var decoder = LinkFrameDecoder()
    private var privateKey = LinkCrypto.makePrivateKey()
    private var serverPublic: String?
    private var cipher: LinkCipher?
    private var pairingCipher: LinkCipher?
    private var pendingToken: Data?
    private var ready = false
    private var running = false
    private var lastMac: DiscoveredMac?
    private var discoveredMacs: [DiscoveredMac] = []
    private var activeLinkSession: Int?
    private var currentMacID: String?
    private var currentMacName: String?
    private var preferredMacID: String?
    private var pendingCode: String?
    private var needsCode = false
    private var forcePair = false
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var waitingWork: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var backgroundAt: TimeInterval?
    private var foregroundProbe: (stamp: Double, started: TimeInterval)?
    private var foregroundProbeWork: DispatchWorkItem?
    private var foregroundRestartEpoch: UInt64?
    private var connectionGeneration = 0
    private var bleClient: BLELinkClient?
    private var usingBLE = false
    private var bleSelectedMacID: String?
    private var bleFallbackWork: DispatchWorkItem?
    private let forceBLE: Bool
    private let epochLock = NSLock()
    private var transportEpoch: UInt64 = 0
    private var pendingWrites: [UUID: (Bool) -> Void] = [:]
    private var supportsPolishPreferences = false
    private var pendingPolishPreferences: LinkPolishPreferences?
    private var polishSaveGeneration: UInt64 = 0
    private var knownNames: [String: String] = [:]
    private var macLastConnected: [String: Double] = [:]
    private var manualSelection = false
    private var attemptedThisRound: Set<String> = []
    // Revoked tokens cannot cause an automatic pairing prompt on the next retry.
    private var rejectedPairingIDs: Set<String> = []
    private var automaticTargetWasPaired = false
    private var graceDeadline: TimeInterval?
    private var graceWork: DispatchWorkItem?


    private let deviceID: String
    private let deviceName: String
    private let directMac: DiscoveredMac?
    private let autoPairCode: String?

    init() {
        #if DEBUG
        isPreview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-preview=") }
        #else
        isPreview = false
        #endif
        if let stored = UserDefaults.standard.string(forKey: "imic.deviceID"),
           UUID(uuidString: stored) != nil {
            deviceID = stored
        } else {
            let value = UUID().uuidString
            UserDefaults.standard.set(value, forKey: "imic.deviceID")
            deviceID = value
        }
        #if canImport(UIKit)
        deviceName = UIDevice.current.name.isEmpty ? "iPhone" : String(UIDevice.current.name.prefix(48))
        #else
        deviceName = "iMic reconnect test"
        #endif
        preferredMacID = UserDefaults.standard.string(forKey: "imic.preferredMacID")

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        forceBLE = args.contains("--debug-ble")
        let host = args.first { $0.hasPrefix("--debug-host=") }
            .map { String($0.dropFirst("--debug-host=".count)) }
        let port = args.first { $0.hasPrefix("--debug-port=") }
            .flatMap { UInt16($0.dropFirst("--debug-port=".count)) }
        if let host = host, let port = port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            directMac = DiscoveredMac(
                id: "direct",
                name: "Direct Mac",
                endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
            )
        } else {
            directMac = nil
        }
        autoPairCode = args.first { $0.hasPrefix("--debug-pair-code=") }
            .map { PairingCode.normalize(String($0.dropFirst("--debug-pair-code=".count))) }
        #else
        directMac = nil
        autoPairCode = nil
        forceBLE = false
        #endif
        knownNames = UserDefaults.standard.dictionary(forKey: "imic.macNames") as? [String: String] ?? [:]
        if let preferredMacID, knownNames[preferredMacID] == nil {
            knownNames[preferredMacID] = "Mac"
        }
        macLastConnected = (UserDefaults.standard.dictionary(forKey: "imic.macLastConnected") as? [String: Double] ?? [:])
            .filter { $0.value.isFinite }
        selectedMacID = preferredMacID
        selectedMacName = preferredMacID.map { knownNames[$0] ?? "Mac" }
        let paired = Set(knownNames.keys.filter { TokenStore.load(for: $0) != nil })
        pairedMacIDs = paired
        rememberedMacs = knownNames.map { RememberedMac(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        hasPairedMac = preferredMacID.map { TokenStore.load(for: $0) != nil } ?? false
        currentMacID = preferredMacID
        currentMacName = selectedMacName

        #if DEBUG
        if isPreview {
            let name = "MacBook Pro"
            let mac = DiscoveredMac(
                id: "preview-mac",
                name: name,
                endpoint: .hostPort(host: "127.0.0.1", port: 1)
            )
            macs = [mac]
            selectedMacID = mac.id
            selectedMacName = mac.name
            rememberedMacs = [RememberedMac(id: mac.id, name: mac.name)]
            lastMac = mac
            let mode = ProcessInfo.processInfo.arguments
                .first { $0.hasPrefix("--ui-preview=") }?
                .replacingOccurrences(of: "--ui-preview=", with: "") ?? "idle"
            if mode.hasPrefix("onboarding-") {
                macs = mode == "onboarding-pair" ? [mac] : []
                phase = mode == "onboarding-pair" ? .needsCode(name) : .idle
                localNetworkDenied = mode == "onboarding-link-denied"
            } else {
                switch mode {
                case "pairing": phase = .needsCode(name)
                case "offline": phase = .searching
                default: phase = .ready(name)
                }
            }
            hasPairedMac = phase.isReady
            gestureReady = phase.isReady
            gestureSupported = true
            gestureRevision = 1
            remoteGestureRevision = 1
            remoteGestureReady = true
            #if DEBUG
            // 仅为设置页静态排版预览提供示例；真实链路仍只接受 Mac 回显。
            if mode == "settings" {
                polishPreferencesSupported = true
                polishOutputSupported = true
                polishPreferences = LinkPolishPreferences(enabled: true, options: .default)
            }
            #endif
        }
        #endif
    }

    // MARK: - Lifecycle

    func start() {
        guard !startDeferred, !isPreview, !running else { return }
        running = true
        queue.async {
            self.resetSelectionLocked()
            if self.forceBLE {
                self.startBLELocked()
                return
            }
            if let mac = self.directMac {
                self.connectLocked(to: mac)
            } else {
                self.startBrowserLocked()
            }
            self.scheduleBLEFallback(after: 3)
        }
    }

    func activate() {
        guard !startDeferred, !isPreview else { return }
        if !running {
            start()
            return
        }
        queue.async {
            guard self.foregroundRestartEpoch == nil else { return }
            let returning = self.backgroundAt != nil
            self.backgroundAt = nil
            if returning { self.resetSelectionLocked() }
            self.reconnectAttempts = 0
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            if self.ready, returning {
                self.probeForegroundLocked()
            } else if !self.ready, !self.needsCode,
                      returning || (self.connection == nil && !self.usingBLE) {
                self.restartForegroundLocked(reason: "返回前台")
            }
        }
    }

    /// Keep a live session available for final results; foreground will verify it afresh.
    func enterBackground() {
        guard !isPreview else { return }
        queue.async {
            self.backgroundAt = ProcessInfo.processInfo.systemUptime
            self.foregroundProbeWork?.cancel()
            self.foregroundProbeWork = nil
            self.foregroundProbe = nil
        }
    }

    private func probeForegroundLocked() {
        guard foregroundProbe == nil else { return }
        let stamp = Date().timeIntervalSince1970
        let started = ProcessInfo.processInfo.systemUptime
        foregroundProbe = (stamp, started)
        let epoch = currentEpoch()
        let name = currentMacName ?? "Mac"
        publish { self.phase = .connecting(name); self.gestureReady = false }
        IMicLog.write("iphone.link", "foreground probe transport=\(usingBLE ? "ble" : "tcp")")
        sendSealed(.ping(stamp))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentEpoch() == epoch,
                  self.foregroundProbe?.stamp == stamp else { return }
            self.restartForegroundLocked(reason: "前台存活检查超时")
        }
        foregroundProbeWork = work
        queue.asyncAfter(deadline: .now() + (usingBLE ? 1.5 : 0.8), execute: work)
    }

    /// Publish the loss before a new epoch starts, so a pending voice session cannot
    /// silently survive on a replacement socket. No reconnect backoff on foreground.
    private func restartForegroundLocked(reason: String) {
        // A new recording buffered during this probe never used the old socket.
        // Only an announced old session must be failed on replacement.
        let notifyLoss = activeLinkSession != nil
        let name = currentMacName ?? "Mac"
        resetSelectionLocked()
        let mac = directMac
        closeConnectionLocked()
        let epoch = currentEpoch()
        foregroundRestartEpoch = epoch
        reconnectAttempts = 0
        IMicLog.write("iphone.link", "foreground reconnect reason=\(reason)")
        publish {
            self.phase = mac == nil ? .searching : .connecting(name)
            self.isManualSelection = false
            self.transport = nil
            if notifyLoss { self.onLost?() }
            self.queue.async {
                guard self.running, self.currentEpoch() == epoch else { return }
                self.foregroundRestartEpoch = nil
                if self.forceBLE {
                    self.startBLELocked()
                } else {
                    if self.directMac == nil { self.startBrowserLocked() }
                    if let mac {
                        self.connectLocked(to: mac)
                    }
                    self.scheduleBLEFallback(after: 3)
                }
            }
        }
    }

    func retry() {
        guard !isPreview else { return }
        queue.async {
            guard !self.ready else { return }
            self.closeConnectionLocked()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.reconnectAttempts = 0
            self.needsCode = false
            self.bleClient?.stop()
            self.bleClient = nil
            self.usingBLE = false
            if self.forceBLE {
                self.startBLELocked()
            } else if let mac = self.directMac {
                self.connectLocked(to: mac)
            } else {
                self.attemptedThisRound.removeAll()
                self.startBrowserLocked()
            }
            self.scheduleBLEFallback(after: 3)
        }
    }

    /// 仅在空闲时主动离开蓝牙；绝不打断录音、补传或等待结果的会话。
    func reconnectUsingNetwork() {
        guard !isPreview else { return }
        queue.async {
            guard self.running, self.ready, self.usingBLE, !self.forceBLE,
                  self.activeLinkSession == nil else { return }
            let candidate = self.networkCandidateLocked(self.discoveredMacs)
            IMicLog.write("iphone.link", "prefer network selected=\(self.preferredMacID ?? "-") discovered=\(candidate != nil)")
            self.closeConnectionLocked()
            self.reconnectAttempts = 0
            self.needsCode = false
            if let candidate {
                self.connectLocked(to: candidate)
            } else {
                self.lastMac = nil
                self.startBrowserLocked()
            }
            self.scheduleBLEFallback(after: 3)
        }
    }

    /// 调用前由 SessionModel 停止当前会话；换设备不删除任何配对令牌。
    func connect(to mac: DiscoveredMac) {
        guard !isPreview else { return }
        invalidateEpoch()
        queue.async {
            self.manualSelection = true
            self.attemptedThisRound.removeAll()
            self.publish { self.isManualSelection = true }
            self.preferredMacID = mac.id
            self.currentMacID = mac.id
            self.currentMacName = mac.name
            self.pendingCode = nil
            self.needsCode = false
            self.closeConnectionLocked()
            self.connectLocked(to: mac)
            self.rememberTarget(id: mac.id, name: mac.name)
            self.scheduleBLEFallback(after: 3)
        }
    }

    func selectRememberedMac(_ mac: RememberedMac) {
        guard !isPreview else { return }
        if let nearby = macs.first(where: { $0.id == mac.id }) {
            connect(to: nearby)
            return
        }
        invalidateEpoch()
        queue.async {
            self.closeConnectionLocked()
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.manualSelection = true
            self.attemptedThisRound.removeAll()
            self.publish { self.isManualSelection = true }
            self.preferredMacID = mac.id
            self.currentMacID = mac.id
            self.currentMacName = mac.name
            self.lastMac = nil
            self.pendingCode = nil
            self.needsCode = false
            self.rememberTarget(id: mac.id, name: mac.name)
            self.publish {
                self.phase = .searching
                self.pairing = false
                self.pairingError = nil
            }
            self.startBrowserLocked()
            self.scheduleBLEFallback(after: 3)
        }
    }

    func forgetMac() {
        guard !isPreview else { return }
        invalidateEpoch()
        queue.async {
            if let id = self.currentMacID ?? self.preferredMacID {
                TokenStore.delete(for: id)
            }
            if let id = self.currentMacID ?? self.preferredMacID {
                self.knownNames.removeValue(forKey: id)
                self.macLastConnected.removeValue(forKey: id)
                UserDefaults.standard.set(self.macLastConnected, forKey: "imic.macLastConnected")
            }
            self.resetSelectionLocked()
            UserDefaults.standard.set(self.knownNames, forKey: "imic.macNames")
            UserDefaults.standard.removeObject(forKey: "imic.preferredMacID")
            self.preferredMacID = nil
            self.currentMacID = nil
            self.currentMacName = nil
            self.lastMac = nil
            self.pendingCode = nil
            self.needsCode = false
            self.forcePair = true
            self.closeConnectionLocked()
            self.startBrowserLocked()
            let remembered = self.knownNames.map { RememberedMac(id: $0.key, name: $0.value) }
            self.publish {
                self.phase = .searching
                self.macs = []
                self.pairingError = nil
                self.pairing = false
                self.hasPairedMac = false
                self.isManualSelection = false
                self.selectedMacID = nil
                self.selectedMacName = nil
                self.rememberedMacs = remembered
                self.refreshRememberedPublished()
            }
        }
    }

    // MARK: - Discovery

    private func startBrowserLocked() {
        guard running else { return }
        if let mac = directMac {
            connectLocked(to: mac)
            return
        }
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: IMicLink.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser
        discoveredMacs = []
        beginDiscoveryGraceLocked()
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.browser === browser else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 {
                    self.publish { self.localNetworkDenied = true }
                }
            case .ready:
                self.publish { self.localNetworkDenied = false }
            default: break
            }
            switch state {
            case .failed(let error):
                self.publish {
                    self.phase = .failed(L10n.text("Cannot search for Macs · %@", L10n.argument(Self.readable(error))))
                }
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.running, !self.ready else { return }
                    self.startBrowserLocked()
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self, self.browser === browser else { return }
            let candidates = results.compactMap { result -> DiscoveredMac? in
                guard case .bonjour(let txt) = result.metadata,
                      let rawID = txt["id"], let uuid = UUID(uuidString: rawID) else { return nil }
                let id = uuid.uuidString
                var name: String?
                if case let .service(serviceName, _, _, _) = result.endpoint {
                    name = serviceName
                        .replacingOccurrences(of: "iMic · ", with: "")
                        .replacingOccurrences(of: "iMic - ", with: "")
                }
                return DiscoveredMac(id: id, name: name ?? "Mac", endpoint: result.endpoint)
            }
            let macs = DiscoveredMac.coalesced(candidates, preferredEndpoint: self.lastMac?.endpoint)
            self.discoveredMacs = macs
            IMicLog.write("iphone.link", "discovered macs=\(macs.count) selectedAvailable=\(macs.contains { $0.id == self.preferredMacID })")
            self.autoConnect(macs)
            self.publish {
                self.macs = macs
                self.pairedMacIDs = Set(macs.map(\.id).filter { TokenStore.load(for: $0) != nil })
                    .union(self.rememberedMacs.map(\.id).filter { TokenStore.load(for: $0) != nil })
            }
        }
        browser.start(queue: queue)
        publish {
            if !self.phase.isReady, !self.phase.macNameIsConnecting, !self.pairing {
                self.phase = .searching
            }
        }
    }

    private func resetSelectionLocked() {
        manualSelection = false
        attemptedThisRound.removeAll()
        rejectedPairingIDs.removeAll()
        graceWork?.cancel()
        graceWork = nil
        graceDeadline = nil
        publish { self.isManualSelection = false }
    }

    private func beginDiscoveryGraceLocked() {
        graceWork?.cancel()
        graceDeadline = ProcessInfo.processInfo.systemUptime + MacSelection.preferredGrace
        let deadline = graceDeadline
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.graceDeadline == deadline, self.running else { return }
            self.graceWork = nil
            self.autoConnect(self.discoveredMacs)
        }
        graceWork = work
        queue.asyncAfter(deadline: .now() + MacSelection.preferredGrace, execute: work)
    }

    private func knownPairedCandidatesLocked() -> [MacCandidate] {
        var ids = Set(knownNames.keys).union(macLastConnected.keys).union(discoveredMacs.map(\.id))
        if let preferredMacID { ids.insert(preferredMacID) }
        return ids.map { MacCandidate(id: $0, paired: TokenStore.load(for: $0) != nil,
                                     lastConnected: macLastConnected[$0]) }
    }

    private func networkCandidateLocked(_ discovered: [DiscoveredMac]) -> DiscoveredMac? {
        let candidates = discovered.map {
            MacCandidate(id: $0.id, paired: TokenStore.load(for: $0.id) != nil,
                         lastConnected: macLastConnected[$0.id])
        }
        let preferredPaired = preferredMacID.flatMap { TokenStore.load(for: $0) } != nil
        let expired = graceDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? true
        let chosen = MacSelection.choose(discovered: candidates, preferredID: preferredMacID,
            graceExpired: expired, hasAnyPairedMac: knownPairedCandidatesLocked().contains { $0.paired },
            excluded: attemptedThisRound.union(manualSelection ? [] : rejectedPairingIDs),
            manualSelection: manualSelection, preferredIsPaired: preferredPaired)
        let reason = chosen.map { id in
            manualSelection ? "manual" : id == preferredMacID && preferredPaired ? "preferred" :
                candidates.first(where: { $0.id == id })?.paired == true ? "recent" : "single_unpaired"
        } ?? (!manualSelection && preferredPaired && !expired ? "grace" : "none")
        IMicLog.write("iphone.link", "auto select chosen=\(chosen ?? "-") reason=\(reason) candidates=\(candidates.count)")
        return discovered.first { $0.id == chosen }
    }

    @discardableResult
    private func autoConnect(_ discovered: [DiscoveredMac]) -> Bool {
        guard !ready, connection == nil, !usingBLE, activeLinkSession == nil,
              reconnectWork == nil else { return false }
        guard let match = networkCandidateLocked(discovered) else { return false }
        connectLocked(to: match)
        return true
    }

    /// One pass tries each available target once. Only the existing backoff starts a new pass.
    private func continueAfterLossLocked(reason: String) {
        if directMac == nil, !manualSelection, autoConnect(discoveredMacs) { return }
        scheduleReconnect(reason: reason)
    }

    // MARK: - Connection

    private func connectLocked(to mac: DiscoveredMac) {
        guard running, !ready else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        handshakeWork?.cancel()
        closeConnectionLocked()
        lastMac = mac
        currentMacID = mac.id == "direct" ? preferredMacID : mac.id
        currentMacName = mac.name
        automaticTargetWasPaired = !manualSelection && directMac == nil &&
            currentMacID.flatMap { TokenStore.load(for: $0) } != nil
        privateKey = LinkCrypto.makePrivateKey()
        decoder.reset()
        serverPublic = nil
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        forcePair = false
        connectionGeneration += 1
        let generation = connectionGeneration
        let isPaired = currentMacID.flatMap { TokenStore.load(for: $0) } != nil
        let manual = manualSelection
        publish {
            self.phase = .connecting(mac.name)
            self.selectedMacID = mac.id
            self.selectedMacName = mac.name
            self.hasPairedMac = isPaired
            self.isManualSelection = manual
            self.transport = nil
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.waitingWork?.cancel()
                self.waitingWork = nil
                // TCP 已通，等待用户配对不等于网络不可用，不能再被 3 秒兜底抢走。
                self.bleFallbackWork?.cancel()
                self.bleFallbackWork = nil
                IMicLog.write("iphone.link", "TCP connected endpoint=\(mac.endpoint) interfaces=\(String(describing: connection.currentPath?.availableInterfaces))")
                self.sendHello()
                self.receive()
            case .waiting(let error):
                IMicLog.write("iphone.link", "TCP waiting reason=\(Self.readable(error))")
                self.publish { self.phase = .connecting("\(mac.name) · \(Self.readable(error))") }
                // NWConnection 在 localhost 上可能长期停在 waiting；主动关闭重连，
                // 让「Mac 稍后才启动」也能在录音超时前接上。
                self.waitingWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.connection === connection, !self.ready else { return }
                    self.connectionLost(generation: generation, reason: "连接重试")
                }
                self.waitingWork = work
                self.queue.asyncAfter(deadline: .now() + 2, execute: work)
            case .failed(let error):
                self.connectionLost(generation: generation, reason: Self.readable(error))
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection === connection, !self.ready else { return }
            self.connectionLost(generation: generation, reason: "连接超时")
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + IMicLink.handshakeTimeout, execute: work)
    }

    private func sendHello() {
        let token = currentMacID.flatMap { TokenStore.load(for: $0) }
        let hasToken = token != nil && !forcePair
        sendPlain(.hello(
            deviceID: deviceID,
            deviceName: deviceName,
            publicKey: LinkCrypto.publicKeyBase64(privateKey),
            hasToken: hasToken
        ))
    }

    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let data = data, !data.isEmpty {
                    do {
                        for frame in try self.decoder.append(data) {
                            try self.handle(frame)
                            // 处理过程中可能已重置连接（令牌失效、保存失败），剩余帧属于旧链路。
                            guard self.connection === connection else { return }
                        }
                    } catch {
                        self.connectionLost(generation: self.connectionGeneration, reason: "链路数据异常，请重试")
                        return
                    }
                }
                if isComplete || error != nil {
                    self.connectionLost(
                        generation: self.connectionGeneration,
                        reason: error.map(Self.readable) ?? L10n.text("Disconnected")
                    )
                    return
                }
                self.receive()
            }
        }
    }

    private func handle(_ frame: LinkFrame) throws {
        switch frame.kind {
        case .json:
            let message = try LinkMessage.decode(frame.payload)
            try handlePlain(message)
        case .sealedJSON:
            guard let cipher = cipher else { throw LinkError.decryptionFailed }
            let message = try LinkMessage.decode(cipher.open(frame.payload))
            handleSealed(message)
        case .sealedAudio:
            break
        }
    }

    private func handlePlain(_ message: LinkMessage) throws {
        if message.t == "error" {
            handleServerError(message)
            return
        }
        guard message.t == "hello", let serverPublic = message.publicKey else {
            throw LinkError.decodingFailed
        }
        self.serverPublic = serverPublic
        if let macID = message.macID {
            if let expected = currentMacID, UUID(uuidString: expected) != nil, expected != macID {
                throw LinkError.decodingFailed
            }
            currentMacID = macID
        }
        if let name = message.name { currentMacName = name }
        let name = currentMacName ?? "Mac"

        switch message.status {
        case "auth":
            guard let macID = currentMacID,
                  let token = TokenStore.load(for: macID)
            else {
                // Mac 记得我们，但本机令牌已丢失：改成首次配对。
                forcePair = true
                reconnectAfterReset()
                return
            }
            cipher = try LinkCrypto.sessionCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                token: token
            )
            sendSealed(.auth())
            publish { self.phase = .connecting(name) }
        case "pair_required":
            if !manualSelection, directMac == nil,
               automaticTargetWasPaired || usingBLE || knownPairedCandidatesLocked().contains(where: { $0.paired }) {
                if let id = currentMacID { TokenStore.delete(for: id) }
                forcePair = true
                reconnectAfterReset()
                return
            }
            IMicLog.write("iphone.link", "waiting for pair code transport=\(usingBLE ? "ble" : "tcp")")
            if let code = autoPairCode, code.count == 6 {
                publish { self.phase = .connecting(name) }
                submit(code)
            } else {
                needsCode = true
                publish {
                    self.pairing = true
                    self.pairingError = nil
                    self.phase = .needsCode(name)
                }
                if let code = pendingCode {
                    submit(code)
                }
            }
        default:
            throw LinkError.decodingFailed
        }
    }

    private func handleSealed(_ message: LinkMessage) {
        switch message.t {
        case "paired":
            if let macID = currentMacID, let token = pendingToken {
                guard TokenStore.save(token, for: macID) else {
                    // Mac 已信任该令牌，但本机未能保存；继续使用会让下次启动静默失效，明确要求重新配对。
                    IMicLog.write("iphone.link", "token save failed mac=\(macID)")
                    pendingToken = nil
                    pairingCipher = nil
                    pendingCode = nil
                    closeConnectionLocked()
                    fail(L10n.text("Could not save pairing details. Please pair again."))
                    return
                }
                publish { self.refreshRememberedPublished() }
            }
            if let token = pendingToken, let serverPublic = serverPublic {
                cipher = try? LinkCrypto.sessionCipher(
                    privateKey: privateKey,
                    peerPublicKey: serverPublic,
                    token: token
                )
            }
            pendingToken = nil
            pairingCipher = nil
            pendingCode = nil
            needsCode = false
            let name = currentMacName ?? "Mac"
            publish {
                self.pairingError = nil
                self.hasPairedMac = true
                self.phase = .connecting(name)
            }
        case "ready":
            ready = true
            attemptedThisRound.removeAll()
            if let id = currentMacID {
                macLastConnected[id] = Date().timeIntervalSince1970
                UserDefaults.standard.set(macLastConnected, forKey: "imic.macLastConnected")
                rememberTarget(id: id, name: currentMacName ?? "Mac")
            }
            needsCode = false
            bleFallbackWork?.cancel()
            bleFallbackWork = nil
            IMicLog.write("iphone.link", "ready mac=\(currentMacName ?? "-") transport=\(usingBLE ? "ble" : "tcp")")
            handshakeWork?.cancel()
            reconnectAttempts = 0
            let name = currentMacName ?? "Mac"
            let transport: Transport = usingBLE ? .bluetooth : .network
            publish {
                self.phase = .ready(name)
                self.transport = transport
                self.pairing = false
                self.pairingError = nil
                self.hasPairedMac = true
            }
            deliver { self.onReady?(name) }
        case "input.state":
            guard ready, let revision = message.seq else { return }
            remoteGestureRevision = revision
            remoteGestureReady = message.status == "ready"
            let available = remoteGestureReady
            publish { self.gestureReady = available; self.gestureRevision = revision }
        case "input.result":
            guard let revision = message.seq, revision == pendingClearRevision else { return }
            pendingClearRevision = nil
            publish { self.clearPending = false }
            deliver { self.onInputResult?(message) }
        case "state":
            IMicLog.write("iphone.link", "state=\(message.phase ?? "?") session=\(message.session ?? -1)")
            if let phase = message.phase {
                deliver { self.onRemoteState?(phase) }
            }
        case "settings", "polish.saved":
            guard ready else { return }
            let features = message.features ?? 0
            let supported = features & IMicLink.polishPreferencesFeature != 0
                && features & IMicLink.polishModesFeature != 0
            supportsPolishPreferences = supported
            let preferences = supported ? message.polish : nil
            let pending = pendingPolishPreferences
            let confirmed = message.t == "polish.saved" && pending != nil
            if confirmed || !supported { pendingPolishPreferences = nil }
            let stillSaving = pendingPolishPreferences != nil
            publish {
                self.gestureSupported = features & IMicLink.gestureControlFeature != 0
                if !self.gestureSupported { self.gestureReady = false }
                self.polishPreferencesSupported = supported
                self.polishOutputSupported = supported && features & IMicLink.polishOutputFeature != 0
                self.polishPreferences = preferences
                if confirmed || !supported { self.polishPreferencesSaving = false }
                if confirmed {
                    self.polishPreferencesError = preferences == pending
                        ? nil : L10n.text("Your Mac confirmed different values. Showing the preferences actually saved on your Mac.")
                } else if !supported, pending != nil {
                    self.polishPreferencesError = L10n.text("This Mac no longer supports changing polish preferences from your phone. Update iMic on your Mac.")
                } else if !stillSaving {
                    self.polishPreferencesError = nil
                }
            }
            IMicLog.write("iphone.link", "settings features=\(features) polishSaved=\(confirmed)")
            deliver { self.onSettings?(features) }
        case "audio.need":
            if let rawSession = message.session, let rawFrom = message.seq,
               rawSession >= 0, rawSession <= 65_535, rawFrom >= 0 {
                IMicLog.write("iphone.link", "audio.need session=\(rawSession) from=\(rawFrom)")
                let session = UInt16(rawSession)
                let from = UInt32(clamping: rawFrom)
                deliver { self.onAudioNeed?(session, from) }
            } else {
                IMicLog.write("iphone.link", "audio.need invalid")
            }
        case "result", "failure":
            IMicLog.write("iphone.link", "\(message.t) session=\(message.session ?? -1) chars=\(message.text?.count ?? 0) code=\(message.code ?? "-")")
            if message.session == activeLinkSession { activeLinkSession = nil }
            deliver { self.onResult?(message) }
        case "ping":
            sendSealed(.pong(message.ts ?? 0))
        case "pong":
            guard let probe = foregroundProbe, message.ts == probe.stamp else { return }
            foregroundProbeWork?.cancel()
            foregroundProbeWork = nil
            foregroundProbe = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - probe.started
            let name = currentMacName ?? "Mac"
            let gestures = remoteGestureReady
            IMicLog.write("iphone.link", "foreground alive latency_ms=\(Int(elapsed * 1000))")
            publish { self.phase = .ready(name); self.gestureReady = gestures }
            deliver { self.onReady?(name) }
        default:
            break
        }
    }

    private func handleServerError(_ message: LinkMessage) {
        // Known codes are shown in this iPhone’s language, never the Mac’s language.
        let code = message.code ?? "unknown"
        let text = LinkStatusText.text(code: message.code, message: message.message, fallback: L10n.text("Connection error"))
        if code == "pair_code" || code == "pair_locked" {
            // 清掉已被拒绝的码：握手超时重连后不能自动重复提交，否则一次输错会持续消耗 Mac 的全局尝试次数。
            pendingCode = nil
            pairingCipher = nil
            pendingToken = nil
            let name = currentMacName ?? "Mac"
            let error = code == "pair_locked" ? text : L10n.text("Incorrect pairing code. Please retry.")
            publish {
                self.pairing = true
                self.pairingError = error
                self.phase = .needsCode(name)
            }
            return
        }
        if code == "auth" {
            if let macID = currentMacID {
                TokenStore.delete(for: macID)
            }
            forcePair = true
            reconnectAfterReset()
            return
        }
        fail(text)
    }

    private func reconnectAfterReset() {
        let skipPairing = !manualSelection && directMac == nil
        if skipPairing, let id = currentMacID {
            attemptedThisRound.insert(id)
            rejectedPairingIDs.insert(id)
        }
        handshakeWork?.cancel()
        closeConnectionLocked()
        needsCode = false
        let epoch = currentEpoch()
        publish {
            self.pairing = false
            self.pairingError = nil
            self.phase = .searching
            self.refreshRememberedPublished()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentEpoch() == epoch else { return }
            self.reconnectWork = nil
            if skipPairing {
                self.continueAfterLossLocked(reason: "配对信息已失效")
            } else if let mac = self.lastMac, !self.forceBLE {
                self.connectLocked(to: mac)
            } else {
                self.startBLELocked()
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func connectionLost(generation: Int, reason: String) {
        guard generation == connectionGeneration else { return }
        if foregroundProbe != nil { restartForegroundLocked(reason: reason); return }
        invalidateEpoch()
        failPendingWrites()
        let notifyLoss = ready || activeLinkSession != nil
        ready = false
        activeLinkSession = nil
        if directMac == nil, !manualSelection, let id = currentMacID { attemptedThisRound.insert(id) }
        IMicLog.write("iphone.link", "connection lost ready=\(notifyLoss) reason=\(reason)")
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        guard running else { return }
        needsCode = false
        let epoch = currentEpoch()
        // Deliver loss against the old session before selecting a new transport epoch.
        publish {
            self.phase = .searching
            self.transport = nil
            self.pairing = false
            if notifyLoss { self.onLost?() }
            self.queue.async {
                guard self.running, self.currentEpoch() == epoch else { return }
                self.continueAfterLossLocked(reason: reason)
            }
        }
    }

    private var hasConnectedNetwork: Bool {
        guard let connection else { return false }
        if case .ready = connection.state { return true }
        return false
    }

    private func scheduleBLEFallback(after delay: TimeInterval) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--debug-no-ble-fallback") { return }
        #endif
        guard running, !usingBLE, !hasConnectedNetwork else { return }
        bleFallbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, !self.ready, !self.usingBLE,
                  !self.hasConnectedNetwork, self.connection == nil else { return }
            self.startBLELocked()
        }
        bleFallbackWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startBLELocked() {
        guard running, !ready, !usingBLE else { return }
        // 蓝牙只接受本机有令牌的身份；手动等待期间绝不跳到其他 Mac。
        guard connection == nil || forceBLE else { return }
        let candidates = knownPairedCandidatesLocked().filter {
            !attemptedThisRound.contains($0.id) && (!manualSelection || $0.id == preferredMacID)
        }
        let accepted = MacSelection.orderedPaired(candidates, preferredID: preferredMacID)
            .filter { UUID(uuidString: $0) != nil }
        guard !accepted.isEmpty else {
            if forceBLE { publish { self.phase = .failed(L10n.text("Pair with your Mac on the same Wi-Fi before using Bluetooth")) } }
            return
        }
        bleFallbackWork?.cancel()
        bleFallbackWork = nil
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        serverPublic = nil
        invalidateEpoch()
        failPendingWrites()
        usingBLE = true
        bleSelectedMacID = nil
        let ble = BLELinkClient()
        bleClient = ble
        ble.onConnected = { [weak self, weak ble] macID in
            guard let self, let ble else { return }
            self.queue.async { [weak self] in self?.bleConnected(ble, macID: macID) }
        }
        ble.onData = { [weak self, weak ble] data in
            guard let self, let ble else { return }
            self.queue.async { [weak self] in self?.bleReceived(ble, data: data) }
        }
        ble.onLost = { [weak self, weak ble] in
            guard let self, let ble else { return }
            self.queue.async { [weak self] in self?.bleLost(ble) }
        }
        IMicLog.write("iphone.link", "start BLE fallback")
        let name = currentMacName ?? L10n.text("Bluetooth Mac")
        publish { self.phase = .connecting(name); self.transport = nil }
        ble.start(acceptedMacIDs: accepted)
    }

    private func bleConnected(_ ble: BLELinkClient, macID: String) {
        guard running, usingBLE, bleClient === ble else { return }
        privateKey = LinkCrypto.makePrivateKey()
        decoder.reset()
        serverPublic = nil
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        forcePair = false
        guard TokenStore.load(for: macID) != nil,
              !manualSelection || preferredMacID == macID else { bleLost(ble); return }
        currentMacID = macID
        bleSelectedMacID = macID
        currentMacName = knownNames[macID] ?? "Mac"
        automaticTargetWasPaired = !manualSelection
        IMicLog.write("iphone.link", "BLE connected; send hello mac=\(currentMacID ?? "-")")
        let name = currentMacName ?? "Mac"
        publish {
            self.phase = .connecting(name)
            self.selectedMacID = macID
            self.selectedMacName = name
        }
        sendHello()
        let work = DispatchWorkItem { [weak self, weak ble] in
            guard let self, let ble, self.bleClient === ble, !self.ready, !self.needsCode else { return }
            self.bleLost(ble)
        }
        handshakeWork = work
        queue.asyncAfter(deadline: .now() + IMicLink.handshakeTimeout, execute: work)
    }

    private func bleReceived(_ ble: BLELinkClient, data: Data) {
        guard usingBLE, bleClient === ble else { return }
        do {
            for frame in try decoder.append(data) {
                try handle(frame)
                guard usingBLE, bleClient === ble else { return }
            }
        } catch {
            IMicLog.write("iphone.link", "BLE frame error=\(String(describing: error))")
            bleLost(ble)
        }
    }

    private func bleLost(_ ble: BLELinkClient) {
        guard usingBLE, bleClient === ble else { return }
        if foregroundProbe != nil { restartForegroundLocked(reason: "蓝牙前台连接失效"); return }
        IMicLog.write("iphone.link", "BLE lost")
        let notifyLoss = ready || activeLinkSession != nil
        if !manualSelection, let id = bleSelectedMacID { attemptedThisRound.insert(id) }
        closeConnectionLocked()
        let epoch = currentEpoch()
        publish {
            self.phase = .searching
            self.transport = nil
            if notifyLoss { self.onLost?() }
            self.queue.async {
                guard self.running, self.currentEpoch() == epoch else { return }
                self.continueAfterLossLocked(reason: "蓝牙断开")
                self.scheduleBLEFallback(after: 3)
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        reconnectWork?.cancel()
        reconnectWork = nil
        guard running else { return }
        reconnectAttempts += 1
        let delay = min(8, pow(1.6, Double(reconnectAttempts - 1)))
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, !self.ready else { return }
            self.reconnectWork = nil
            self.attemptedThisRound.removeAll()
            if self.forceBLE {
                self.startBLELocked()
            } else if let mac = self.directMac {
                self.connectLocked(to: mac)
            } else {
                if self.browser == nil { self.startBrowserLocked() }
                self.autoConnect(self.discoveredMacs)
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        scheduleBLEFallback(after: delay + 2)
    }

    private func closeConnectionLocked() {
        foregroundRestartEpoch = nil
        foregroundProbeWork?.cancel()
        foregroundProbeWork = nil
        foregroundProbe = nil
        invalidateEpoch()
        failPendingWrites()
        reconnectWork?.cancel()
        reconnectWork = nil
        bleFallbackWork?.cancel()
        bleFallbackWork = nil
        handshakeWork?.cancel()
        waitingWork?.cancel()
        waitingWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        activeLinkSession = nil
        decoder.reset()
        cipher = nil
        pairingCipher = nil
        pendingToken = nil
        bleClient?.stop()
        bleClient = nil
        bleSelectedMacID = nil
        usingBLE = false
    }

    private func fail(_ message: String) {
        // Server-side handshake errors are candidate failures too, not live sockets
        // that can keep blocking selection until their old timeout fires.
        if usingBLE, let ble = bleClient {
            bleLost(ble)
        } else if connection != nil {
            connectionLost(generation: connectionGeneration, reason: message)
        } else {
            if directMac == nil, !manualSelection, let id = currentMacID { attemptedThisRound.insert(id) }
            publish {
                self.phase = .failed(message)
                self.pairing = false
            }
            continueAfterLossLocked(reason: message)
        }
    }

    // MARK: - Pairing

    /// 用户输入六位配对码。连接未就绪时会记住并在连上后自动提交。
    func submitCode(_ raw: String) {
        let code = PairingCode.normalize(raw)
        guard code.count == 6 else {
            publish { self.pairingError = L10n.text("Enter the 6-digit pairing code") }
            return
        }
        queue.async {
            self.pendingCode = code
            if self.connection == nil, !self.usingBLE {
                if let mac = self.lastMac { self.connectLocked(to: mac) }
                return
            }
            self.submit(code)
        }
    }

    private func submit(_ code: String) {
        guard let serverPublic = serverPublic else { return }
        do {
            let pairCipher = try LinkCrypto.pairingCipher(
                privateKey: privateKey,
                peerPublicKey: serverPublic,
                code: code
            )
            pairingCipher = pairCipher
            cipher = pairCipher
            var generator = SystemRandomNumberGenerator()
            let token = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
            pendingToken = token
            publish {
                self.pairing = true
                self.pairingError = nil
                self.phase = .connecting(self.currentMacName ?? "Mac")
            }
            sendSealed(.pair(
                deviceID: deviceID,
                deviceName: deviceName,
                token: token.base64EncodedString()
            ))
        } catch {
            publish { self.pairingError = L10n.text("Invalid pairing code format") }
        }
    }

    // MARK: - Audio / control

    func beginSession(_ session: UInt16) {
        guard permitsSend("audio.start") else { return }
        IMicLog.write("iphone.link", "send audio.start session=\(session)")
        enqueue(.audioStart(session: Int(session)))
    }

    func sendAudio(_ pcm: Data, session: UInt16, seq: UInt32) {
        guard permitsSend("audio") else { return }
        let epoch = currentEpoch()
        queue.async {
            guard epoch == self.currentEpoch() else { return }
            guard self.ready, let cipher = self.cipher, !pcm.isEmpty else {
                IMicLog.write("iphone.link", "drop audio session=\(session) seq=\(seq) bytes=\(pcm.count) ready=\(self.ready) cipher=\(self.cipher != nil)")
                return
            }
            let packet = AudioPacket(session: session, seq: seq, pcm: pcm)
            guard let sealed = try? cipher.seal(packet.encoded()) else {
                IMicLog.write("iphone.link", "seal failed session=\(session) seq=\(seq)")
                return
            }
            if seq % 25 == 0 {
                IMicLog.write("iphone.link", "send audio session=\(session) seq=\(seq) bytes=\(pcm.count)")
            }
            IMicLog.write("iphone.content", "send kind=audio")
            self.sendFrame(LinkFrame(kind: .sealedAudio, payload: sealed))
        }
    }

    func endSession(_ session: UInt16, samples: Int, frames: Int, completion: ((Bool) -> Void)? = nil) {
        guard permitsSend("audio.end") else { completion?(false); return }
        guard IMicLink.isValidAudioEnd(samples: samples, frames: frames) else {
            IMicLog.write("iphone.link", "invalid audio.end samples=\(samples) frames=\(frames)")
            DispatchQueue.main.async { completion?(false) }
            return
        }
        IMicLog.write("iphone.link", "send audio.end session=\(session) samples=\(samples) frames=\(frames)")
        let epoch = currentEpoch()
        enqueue(.audioEnd(session: Int(session), samples: samples, frames: frames)) { [weak self] success in
            DispatchQueue.main.async {
                completion?(success && self?.currentEpoch() == epoch)
            }
        }
    }

    func cancelSession(_ session: UInt16) {
        guard permitsSend("audio.cancel") else { return }
        IMicLog.write("iphone.link", "send audio.cancel session=\(session)")
        enqueue(.audioCancel(session: Int(session)))
    }

    @discardableResult
    func sendInput(_ action: String) -> Bool {
        guard permitsSend("input") else { return false }
        guard phase.isReady, gestureSupported, gestureReady, !clearPending,
              let revision = gestureRevision else { return false }
        if action == "clear" { clearPending = true }
        if isPreview {
            #if DEBUG
            LinkClient.demoInputObserver?(action)
            #endif
            if action == "clear" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.clearPending = false
                    self.onInputResult?(.inputResult(revision: revision, applied: true))
                }
            }
            return true
        }
        IMicLog.write("iphone.link", "send input=\(action) revision=\(revision)")
        enqueue(.input(action, revision: revision))
        return true
    }

    func sendPreview(_ text: String) {
        guard permitsSend("preview") else { return }
        enqueue(.preview(text))
    }

    @MainActor
    @discardableResult
    func updatePolishPreferences(_ preferences: LinkPolishPreferences) -> Bool {
        guard permitsSend("polish.settings") else { return false }
        guard phase.isReady, polishPreferencesSupported, polishPreferences != nil,
              !polishPreferencesSaving else {
            polishPreferencesError = L10n.text("Connect to a Mac that supports polish preferences and wait for the current save to finish.")
            return false
        }
        let epoch = currentEpoch()
        polishPreferencesSaving = true
        polishPreferencesError = nil
        #if DEBUG
        if isPreview {
            // Isolated UI fixture: no network command and no persistent settings.
            let arguments = ProcessInfo.processInfo.arguments
            let delay = arguments.contains("--debug-polish-save-slow") ? 5.0 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, epoch == self.currentEpoch() else { return }
                if arguments.contains("--debug-polish-save-failure") {
                    self.polishPreferencesError = L10n.text("Preview: Your Mac did not confirm. This selection was not saved.")
                } else {
                    self.polishPreferences = preferences
                }
                self.polishPreferencesSaving = false
            }
            return true
        }
        #endif
        queue.async {
            guard epoch == self.currentEpoch(), self.ready, self.supportsPolishPreferences else {
                self.publish {
                    self.polishPreferencesSaving = false
                    self.polishPreferencesError = L10n.text("Connection changed. Reconnect to confirm whether changes were saved.")
                }
                return
            }
            self.polishSaveGeneration &+= 1
            let generation = self.polishSaveGeneration
            self.pendingPolishPreferences = preferences
            self.sendSealed(.polishSettings(preferences, features: IMicLink.polishOutputFeature | IMicLink.polishModesFeature)) { [weak self] success in
                guard let self, !success, epoch == self.currentEpoch(),
                      generation == self.polishSaveGeneration, self.pendingPolishPreferences != nil else { return }
                self.pendingPolishPreferences = nil
                self.publish {
                    self.polishPreferencesSaving = false
                    self.polishPreferencesError = L10n.text("Send incomplete. Reconnect to confirm whether changes were saved.")
                }
            }
        }
        return true
    }

    private func enqueue(_ message: LinkMessage, completion: ((Bool) -> Void)? = nil) {
        let epoch = currentEpoch()
        queue.async {
            guard epoch == self.currentEpoch(), self.ready else {
                IMicLog.write("iphone.link", "drop \(message.t) ready=false or stale target")
                completion?(false)
                if message.t == "input", message.action == "clear", let revision = message.seq {
                    self.publish { self.clearPending = false }
                    self.deliver { self.onInputResult?(.inputResult(revision: revision, applied: false, message: L10n.text("Connection changed. The text field was not cleared."))) }
                }
                return
            }
            if message.t == "input" {
                guard self.remoteGestureReady, self.remoteGestureRevision == message.seq,
                      self.activeLinkSession == nil else {
                    if message.action == "clear", let revision = message.seq {
                        self.publish { self.clearPending = false }
                        self.deliver { self.onInputResult?(.inputResult(revision: revision, applied: false, message: L10n.text("Your Mac is still processing. Please retry shortly."))) }
                    }
                    return
                }
                if message.action == "clear" { self.pendingClearRevision = message.seq }
            }
            if message.t == "audio.start" {
                self.activeLinkSession = message.session
            } else if message.t == "audio.cancel", message.session == self.activeLinkSession {
                self.activeLinkSession = nil
            }
            self.sendSealed(message, completion: completion)
        }
    }

    private func sendPlain(_ message: LinkMessage) {
        guard let data = try? message.encoded() else { return }
        sendFrame(LinkFrame(kind: .json, payload: data))
    }

    private func sendSealed(_ message: LinkMessage, completion: ((Bool) -> Void)? = nil) {
        guard let cipher = cipher, let data = try? message.encoded(),
              let sealed = try? cipher.seal(data) else {
            completion?(false)
            return
        }
        if ["audio.start", "audio.end", "audio.cancel", "input", "preview", "polish.settings"].contains(message.t) {
            IMicLog.write("iphone.content", "send kind=\(message.t)")
        }
        sendFrame(LinkFrame(kind: .sealedJSON, payload: sealed),
                  replacingPreview: message.t == "preview", completion: completion)
    }

    private func sendFrame(_ frame: LinkFrame, replacingPreview: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let epoch = currentEpoch()
        let generation = connectionGeneration
        let writeID = completion.map { _ in UUID() }
        if let completion, let writeID { pendingWrites[writeID] = completion }
        let finish: (Bool) -> Void = { [weak self] success in
            guard let self, let writeID else { return }
            self.queue.async {
                let valid = success && epoch == self.currentEpoch() && generation == self.connectionGeneration
                self.pendingWrites.removeValue(forKey: writeID)?(valid)
            }
        }
        if usingBLE, let ble = bleClient {
            ble.send(LinkWire.encode(frame), replacingPreview: replacingPreview,
                     completion: completion == nil ? nil : finish)
            return
        }
        guard let connection = connection else {
            IMicLog.write("iphone.link", "send frame without connection kind=\(frame.kind.rawValue)")
            if let writeID { pendingWrites.removeValue(forKey: writeID)?(false) }
            return
        }
        connection.send(content: LinkWire.encode(frame), completion: .contentProcessed { [weak self] error in
            finish(error == nil)
            guard error != nil, let self else { return }
            IMicLog.write("iphone.link", "send error kind=\(frame.kind.rawValue): \(String(describing: error))")
            self.queue.async {
                if self.connection === connection {
                    self.connectionLost(generation: generation, reason: "发送失败")
                }
            }
        })
    }

    // MARK: - Helpers

    private func currentEpoch() -> UInt64 {
        epochLock.lock()
        defer { epochLock.unlock() }
        return transportEpoch
    }

    private func invalidateEpoch() {
        epochLock.lock()
        transportEpoch &+= 1
        epochLock.unlock()
        let hadPendingSave = pendingPolishPreferences != nil
        pendingPolishPreferences = nil
        supportsPolishPreferences = false
        remoteGestureRevision = nil
        remoteGestureReady = false
        pendingClearRevision = nil
        publish {
            self.gestureRevision = nil
            self.gestureReady = false
            self.gestureSupported = false
            self.clearPending = false
            self.polishPreferences = nil
            self.polishPreferencesSupported = false
            self.polishOutputSupported = false
            self.polishPreferencesSaving = false
            self.polishPreferencesError = hadPendingSave ? L10n.text("Disconnected. Reconnect to confirm whether changes were saved.") : nil
        }
    }

    private func failPendingWrites() {
        let callbacks = Array(pendingWrites.values)
        pendingWrites.removeAll()
        callbacks.forEach { $0(false) }
    }

    private func publish(_ block: @escaping () -> Void) {
        let epoch = currentEpoch()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentEpoch() == epoch else { return }
            block()
        }
    }

    private func deliver(_ block: @escaping () -> Void) { publish(block) }

    private func rememberTarget(id: String, name: String) {
        preferredMacID = id
        knownNames[id] = name
        UserDefaults.standard.set(id, forKey: "imic.preferredMacID")
        UserDefaults.standard.set(knownNames, forKey: "imic.macNames")
        let snapshot = knownNames
        let manual = manualSelection
        publish {
            self.isManualSelection = manual
            self.selectedMacID = id
            self.selectedMacName = name
            self.rememberedMacs = snapshot.map { RememberedMac(id: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.refreshRememberedPublished()
            self.pairing = false
            self.pairingError = nil
        }
    }

    private func refreshRememberedPublished() {
        pairedMacIDs = Set(rememberedMacs.map(\.id).filter { TokenStore.load(for: $0) != nil })
        hasPairedMac = selectedMacID.map { pairedMacIDs.contains($0) } ?? false
    }

    private static func readable(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return L10n.text("Your Mac refused the connection")
            case .ENETUNREACH, .EHOSTUNREACH: return L10n.text("Network unreachable")
            case .ETIMEDOUT: return L10n.text("Connection timed out")
            default: return L10n.text("Network error")
            }
        case .dns: return L10n.text("Cannot resolve your Mac's address")
        case .tls: return L10n.text("Encrypted handshake failed")
        default: return L10n.text("Connection failed")
        }
    }
}

extension LinkClient.Phase {
    var macNameIsConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// 已经配对过的设备允许「先录、后连」，把 20ms 帧暂存起来。
    var allowsBufferedRecording: Bool {
        switch self {
        case .ready, .searching, .connecting, .failed, .idle: return true
        case .needsCode: return false
        }
    }
}

enum Keychain {
    private static let service = "com.drafffffff.imic.link"

    /// 先更新、不存在再新增，避免「删除成功、新增失败」时丢掉旧令牌。返回是否写入成功。
    @discardableResult
    static func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(update) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            IMicLog.write("iphone.keychain", "save failed status=\(status)")
        }
        return status == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 生产环境只使用钥匙串。模拟器构建未签名时 Keychain 返回 errSecMissingEntitlement，
/// 因此仅在模拟器追加一个受数据保护的应用容器文件，保证本地联调可重复。
enum TokenStore {
    @discardableResult
    static func save(_ data: Data, for macID: String) -> Bool {
        let saved = Keychain.save(data, account: "token:\(macID)")
        #if targetEnvironment(simulator)
        return FileToken.save(data, for: macID) || saved
        #else
        return saved
        #endif
    }

    static func load(for macID: String) -> Data? {
        if let data = Keychain.load(account: "token:\(macID)") {
            return data
        }
        #if targetEnvironment(simulator)
        return FileToken.load(for: macID)
        #else
        return nil
        #endif
    }

    static func delete(for macID: String) {
        Keychain.delete(account: "token:\(macID)")
        #if targetEnvironment(simulator)
        FileToken.delete(for: macID)
        #endif
    }
}

#if targetEnvironment(simulator)
private enum FileToken {
    static func directory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }

    static func url(for macID: String) -> URL? {
        guard let directory = try? directory() else { return nil }
        let digest = SHA256.hash(data: Data(macID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("token-\(digest).bin")
    }

    static func save(_ data: Data, for macID: String) -> Bool {
        guard let url = url(for: macID) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func load(for macID: String) -> Data? {
        guard let url = url(for: macID),
              let data = try? Data(contentsOf: url),
              data.count == 32 else { return nil }
        return data
    }

    static func delete(for macID: String) {
        guard let url = url(for: macID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
