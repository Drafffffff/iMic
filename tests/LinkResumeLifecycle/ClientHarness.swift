// Appended only to a temporary source by test-ios-foreground-lifecycle.sh.
// No test entrypoints are compiled into the App. Auth and framing stay real.
extension LinkClient {
    func resumeTestStart(_ mac: DiscoveredMac) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = true
                continuation.resume()
            }
        }
        // Use the real manual-selection entrypoint, including selected identity.
        connect(to: mac)
    }
    func resumeTestStop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                self.browser?.cancel(); self.browser = nil
                self.graceWork?.cancel(); self.graceWork = nil
                self.closeConnectionLocked()
                continuation.resume()
            }
        }
    }
    private func passiveTestBrowser() -> NWBrowser {
        NWBrowser(for: .bonjourWithTXTRecord(type: IMicLink.serviceType, domain: nil), using: .tcp)
    }
    func resumeTestInstallPassiveBrowser() async -> NWBrowser {
        await withCheckedContinuation { continuation in
            queue.async {
                self.browser?.cancel()
                let browser = self.passiveTestBrowser()
                self.browser = browser
                continuation.resume(returning: browser)
            }
        }
    }
    func resumeTestBrowserIs(_ expected: NWBrowser) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.browser === expected) }
        }
    }
    func resumeTestOldBrowserRetry() async -> (old: NWBrowser, replacement: NWBrowser) {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = true
                // Never select a real LAN computer during this isolated delegate test.
                self.manualSelection = true
                self.preferredMacID = UUID().uuidString
                self.startBrowserLocked()
                let old = self.browser!
                let callback = old.stateUpdateHandler!
                old.stateUpdateHandler = nil; old.browseResultsChangedHandler = nil
                old.cancel()
                callback(.failed(.posix(.ENETDOWN)))
                let replacement = self.passiveTestBrowser()
                self.browser = replacement
                continuation.resume(returning: (old, replacement))
            }
        }
    }
    func resumeTestFailBrowserWhileReady() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.startBrowserLocked()
                let browser = self.browser!
                let callback = browser.stateUpdateHandler!
                browser.stateUpdateHandler = nil; browser.browseResultsChangedHandler = nil
                browser.cancel()
                callback(.failed(.posix(.ENETDOWN)))
                continuation.resume()
            }
        }
    }
    /// Called from main: deliberately keep publication queued until the transition
    /// has finished, as happens while UIKit is resuming its scene.
    @MainActor func resumeTestRestartBeforeMainPublication() -> Bool {
        queue.sync {
            self.running = true
            self.browser?.cancel()
            self.browser = self.passiveTestBrowser()
            self.restartForegroundLocked(reason: "isolated main-thread handoff")
            return self.browser == nil
        }
    }

    @MainActor func resumeTestConnectionLossHandoffBlocksAutoConnect(_ mac: DiscoveredMac) -> Bool {
        queue.sync {
            self.running = true
            self.manualSelection = true
            self.preferredMacID = mac.id
            self.currentMacID = mac.id
            self.discoveredMacs = [mac]
            self.ready = true
            self.activeLinkSession = 512
            self.backgroundAt = ProcessInfo.processInfo.systemUptime - 5
            let generation = self.connectionGeneration
            self.connectionLost(generation: generation, reason: "isolated loss handoff")
            let epochBefore = self.currentEpoch()
            let blocked = !self.autoConnect([mac]) && self.currentEpoch() == epochBefore
            return blocked && self.foregroundRestartEpoch == epochBefore
        }
    }

    func resumeTestBackgroundCleared() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.backgroundAt == nil) }
        }
    }

    func resumeTestAgeLastReceive(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.lastReceiveAt = ProcessInfo.processInfo.systemUptime - seconds
                continuation.resume()
            }
        }
    }

    func resumeTestBeginBLEProbe(startedOffset: TimeInterval = 0, initialTimeout: TimeInterval = 1.5) async -> BLELinkClient {
        await withCheckedContinuation { continuation in
            queue.async {
                let ble = BLELinkClient()
                self.usingBLE = true
                self.bleClient = ble
                self.ready = true
                ble.onWriteProgress = { [weak self, weak ble] in
                    guard let self, let ble else { return }
                    self.queue.async { [weak self] in self?.bleWriteProgressed(ble) }
                }
                let started = ProcessInfo.processInfo.systemUptime - startedOffset
                let stamp = 1234.5
                self.foregroundProbe = (stamp: stamp, started: started, pingDispatched: false)
                self.scheduleForegroundProbeTimeoutLocked(stamp: stamp, epoch: self.currentEpoch(), after: initialTimeout)
                continuation.resume(returning: ble)
            }
        }
    }

    func resumeTestBLEProbeState() async -> (ready: Bool, probing: Bool) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.ready, self.foregroundProbe != nil))
            }
        }
    }

    func resumeTestDeliverSealedDuringProbe() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.handleSealed(.state(session: 1, phase: "idle"))
                continuation.resume()
            }
        }
    }

}
