import Foundation

/// A ready revision is a lease for the current idle pipeline, never a timer estimate.
public struct LinkGestureLease {
    public private(set) var revision = 0
    public private(set) var ready = false
    public init() {}
    public mutating func update(ready: Bool) {
        revision += 1
        self.ready = ready
    }
    public func permits(_ revision: Int?) -> Bool { ready && revision == self.revision }
}

/// Upward movement keeps the normal delete feel, then progressively extends to the top.
public struct StringClearStretch {
    public let distance: CGFloat
    public let depth: CGFloat
    public init(distance: CGFloat, depth: CGFloat) {
        self.distance = max(100, distance)
        self.depth = max(0, depth)
    }
    public func pull(normal: CGFloat, translation: CGFloat, limit: CGFloat, origin: CGFloat = 0) -> CGFloat {
        guard translation < 0 else { return normal }
        let free = min(distance * 0.35, limit / 0.72)
        let p = min(1, max(0, (-translation - free) / max(1, distance - free)))
        let blend = p * p * (3 - 2 * p)
        return normal + (-depth - origin - normal) * blend
    }
}

/// Contact, dissolve, then a finite elastic return. Sampled on the existing display clock.
public struct StringClearFeedback {
    public struct Frame {
        public let pull: CGFloat
        public let opacity: Double
        public let zone: Double
        public let finished: Bool
    }
    public let initialPull: CGFloat
    public let depth: CGFloat
    public init(initialPull: CGFloat, depth: CGFloat) {
        self.initialPull = initialPull
        self.depth = max(0, depth)
    }
    public func frame(at elapsed: Double, reducedMotion: Bool) -> Frame {
        let t = max(0, elapsed)
        func smooth(_ p: Double) -> Double {
            let p = min(1, max(0, p))
            return p * p * (3 - 2 * p)
        }
        if t < 0.22 {
            let arrival = CGFloat(smooth(t / 0.065))
            let shake = reducedMotion ? 0 : CGFloat(sin(t * 95) * 3 * exp(-t * 24))
            return Frame(pull: initialPull + (-depth - initialPull) * arrival + shake,
                         opacity: 1 - smooth((t - 0.08) / 0.14),
                         zone: 1 - smooth((t - 0.08) / 0.18), finished: false)
        }
        guard t < 0.70 else { return Frame(pull: 0, opacity: 1, zone: 0, finished: true) }
        let r = t - 0.22
        let response = reducedMotion ? (1 + 22 * r) * exp(-22 * r)
            : exp(-16 * r) * (cos(28 * r) + 16 / 28 * sin(28 * r))
        return Frame(pull: -depth * CGFloat(response), opacity: smooth(r / 0.055),
                     zone: 1 - smooth((t - 0.08) / 0.18), finished: false)
    }
}

/// Outward-only teeth: one pulse per new distance notch, no catch-up buzz or jitter replay.
public struct StringPullRatchet {
    private var highest = 0
    private var lastPulse = -Double.infinity
    public init() {}
    public mutating func advance(distance: CGFloat, now: Double) -> Bool {
        let notch = max(0, Int((distance - 24) / 22))
        guard notch > highest else { return false }
        highest = notch
        guard now - lastPulse >= 0.045 else { return false }
        lastPulse = now
        return true
    }
}
