// Appended to a temporary copy of LinkClient.swift by the test script, so private
// queue state can be driven without shipping test hooks or mocking authentication.
extension LinkClient {
    func selectionTestDiscover(_ macs: [DiscoveredMac], begin: Bool = false, expired: Bool = false) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if begin {
                    self.running = true
                    self.closeConnectionLocked()
                    self.resetSelectionLocked()
                    self.beginDiscoveryGraceLocked()
                    self.publish { self.phase = .searching }
                }
                self.browser?.cancel()
                self.browser = nil
                self.discoveredMacs = macs
                if expired {
                    self.graceWork?.cancel()
                    self.graceWork = nil
                    self.graceDeadline = ProcessInfo.processInfo.systemUptime
                }
                self.autoConnect(macs)
                continuation.resume()
            }
        }
    }

    func selectionTestHasBrowser() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.browser != nil) }
        }
    }

    func selectionTestRetryState() async -> (Set<String>, Int, Bool) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.attemptedThisRound, self.reconnectAttempts,
                                                self.reconnectWork != nil && self.connection == nil))
            }
        }
    }

    func selectionTestStop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.running = false
                self.browser?.cancel()
                self.browser = nil
                self.graceWork?.cancel()
                self.graceWork = nil
                self.closeConnectionLocked()
                continuation.resume()
            }
        }
    }
}
