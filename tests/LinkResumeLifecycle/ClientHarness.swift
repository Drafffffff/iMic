// Appended only to a temporary source by test-ios-foreground-lifecycle.sh.
// No test entrypoints are compiled into the App. Auth and framing stay real.
extension LinkClient {
    func resumeTestStart(_ mac: DiscoveredMac) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = true
                self.manualSelection = true
                self.connectLocked(to: mac)
                continuation.resume()
            }
        }
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

}
