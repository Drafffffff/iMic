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

    /// `preferredIsPaired` also describes an offline preferred ID, whose token cannot
    /// be inferred from `discovered`. A manual choice explicitly permits pairing it.
    public static func choose(discovered: [MacCandidate], preferredID: String?,
                              graceExpired: Bool, hasAnyPairedMac: Bool,
                              excluded: Set<String> = [], manualSelection: Bool = false,
                              preferredIsPaired: Bool = true) -> String? {
        if manualSelection {
            return discovered.first { $0.id == preferredID && !excluded.contains($0.id) }?.id
        }
        let paired = orderedPaired(discovered.filter { !excluded.contains($0.id) }, preferredID: preferredID)
        if let preferredID, paired.first == preferredID { return preferredID }
        if let preferredID, preferredIsPaired, !graceExpired, !excluded.contains(preferredID),
           !discovered.contains(where: { $0.id == preferredID && !$0.paired }) {
            return nil
        }
        if let first = paired.first { return first }
        if !hasAnyPairedMac, discovered.count == 1, let only = discovered.first,
           !excluded.contains(only.id) { return only.id }
        return nil
    }
}
