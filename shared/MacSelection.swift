import Foundation

public struct MacCandidate: Equatable {
    public let id: String
    public let paired: Bool
    public let lastConnected: Double?

    public init(id: String, paired: Bool, lastConnected: Double? = nil) {
        self.id = id
        self.paired = paired
        self.lastConnected = lastConnected
    }
}

/// Device policy only; no transport, token storage or protocol responsibilities.
public enum MacSelection {
    public static let preferredGrace: TimeInterval = 1.5

    /// Stable priority for LAN selection and the BLE allowlist. Unpaired IDs never enter it.
    public static func orderedPaired(_ candidates: [MacCandidate], preferredID: String?) -> [String] {
        candidates.filter(\.paired).sorted {
            if ($0.id == preferredID) != ($1.id == preferredID) { return $0.id == preferredID }
            let left = $0.lastConnected ?? -.infinity
            let right = $1.lastConnected ?? -.infinity
            return left == right ? $0.id < $1.id : left > right
        }.map(\.id)
    }

    /// Restore a successful identity independently of discovery arrival order.
    /// Old builds overwrote preferred on a click; authenticated timestamps are a
    /// better migration source when the two disagree. A missing token does not
    /// authorize changing targets: the user must explicitly pair again.
    public static func restoredTarget(_ candidates: [MacCandidate], successfulID: String?, legacyPreferredID: String?) -> String? {
        if let successfulID, !successfulID.isEmpty { return successfulID }
        if let recent = candidates.filter({ $0.lastConnected?.isFinite == true }).sorted(by: {
            if $0.lastConnected != $1.lastConnected { return $0.lastConnected! > $1.lastConnected! }
            if ($0.id == legacyPreferredID) != ($1.id == legacyPreferredID) { return $0.id == legacyPreferredID }
            return $0.id < $1.id
        }).first { return recent.id }
        if let legacyPreferredID, !legacyPreferredID.isEmpty { return legacyPreferredID }
        let paired = candidates.filter(\.paired)
        return paired.count == 1 ? paired[0].id : nil
    }

    /// An unavailable or failed selected Mac stays selected. Discovery and retry
    /// must never redirect voice or editing commands to another computer.
    public static func choose(discovered: [MacCandidate], preferredID: String?,
                              graceExpired: Bool, hasAnyPairedMac: Bool,
                              excluded: Set<String> = [], manualSelection: Bool = false,
                              preferredIsPaired: Bool = true) -> String? {
        if let preferredID {
            return discovered.first {
                $0.id == preferredID && !excluded.contains($0.id) && (manualSelection || $0.paired)
            }?.id
        }
        // Preserve first-install discovery. Established users without an
        // unambiguous remembered target choose explicitly rather than racing Bonjour.
        if !manualSelection, !hasAnyPairedMac, discovered.count == 1, let only = discovered.first,
           !excluded.contains(only.id) { return only.id }
        return nil
    }

    public static func bluetoothTargets(_ candidates: [MacCandidate], preferredID: String?, excluded: Set<String>) -> [String] {
        guard let preferredID, !excluded.contains(preferredID),
              candidates.contains(where: { $0.id == preferredID && $0.paired }) else { return [] }
        return [preferredID]
    }
}
