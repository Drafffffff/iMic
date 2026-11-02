import SwiftUI

@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let completedKey = "imic.onboarding.completedVersion"
    static let stepKey = "imic.onboarding.step"
    static let tutorialKey = "imic.tutorial.completedVersion"
    private static let actionKey = "imic.onboarding.action"
    private static let replayKey = "imic.onboarding.replay"
    private static let deferredKey = "imic.onboarding.connectLater"

    enum Action: String, CaseIterable {
        case hold, release, send, more, delete, cursor, clear, cancel
        var bar: Bool { self == .hold || self == .release || self == .cancel }
        var prompt: String {
            switch self {
            case .hold: return L10n.text("Hold the bar and speak")
            case .release: return L10n.text("Release to send")
            case .send: return L10n.text("Pull the string to send")
            case .more: return L10n.text("More gestures")
            case .delete: return L10n.text("Pull up to delete##onboarding")
            case .cursor: return L10n.text("Slide sideways to move the cursor")
            case .clear: return L10n.text("Pull to the top to clear")
            case .cancel: return L10n.text("Hold, then slide up to cancel")
            }
        }
        var progress: String {
            switch self {
            case .hold: return "1 / 3"
            case .release: return "2 / 3"
            case .send, .more: return "3 / 3"
            case .delete: return "1 / 4"
            case .cursor: return "2 / 4"
            case .clear: return "3 / 4"
            case .cancel: return "4 / 4"
            }
        }
    }
    @Published var presented = false
    @Published private(set) var step: OnboardingStep = .welcome
    @Published private(set) var action: Action = .hold
    @Published private(set) var replay = false
    @Published private(set) var celebrating = false
    @Published private(set) var connectionDeferred = UserDefaults.standard.bool(forKey: deferredKey)
    private let defaults = UserDefaults.standard
    private(set) var preview: String?
    private var bypass = false
    var unfinished: Bool { !bypass && defaults.integer(forKey: Self.completedKey) < OnboardingPolicy.version }
    var localHome: Bool { presented && (step == .welcome || step == .practice) }
    var coaching: Bool { presented && (step == .practice || step == .ready) }

    init(link: LinkClient) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-reset-onboarding") {
            try? FileManager.default.removeItem(at: IMicLog.fileURL)
            [Self.completedKey, Self.stepKey, Self.tutorialKey, Self.actionKey, Self.replayKey, Self.deferredKey].forEach { defaults.removeObject(forKey: $0) }
        }
        if args.contains("--debug-reset-onboarding") { connectionDeferred = false }
        preview = args.first { $0.hasPrefix("--ui-preview=onboarding-") }.map { String($0.dropFirst("--ui-preview=onboarding-".count)) }
        if preview == nil, args.contains(where: { $0.hasPrefix("--ui-preview=") || $0.hasPrefix("--debug-host=") }) { bypass = true; return }
        #endif
        if let preview {
            presented = true
            switch preview {
            case "welcome": step = .welcome
            case "ready", "complete": step = .ready; celebrating = preview == "complete"
            case "hold", "release", "send", "more", "delete", "cursor", "clear", "cancel":
                step = .practice; action = Action(rawValue: preview) ?? .hold
            default: step = .link
            }
        } else {
            replay = defaults.bool(forKey: Self.replayKey)
            let saved = (defaults.object(forKey: Self.stepKey) as? Int).flatMap(OnboardingStep.init(rawValue:))
            switch OnboardingPolicy.decide(completedVersion: defaults.integer(forKey: Self.completedKey), savedStep: saved,
                hasPairedMac: link.hasPairedMac || !link.pairedMacIDs.isEmpty) {
            case .skip: break
            case .skipAndMarkComplete: defaults.set(OnboardingPolicy.version, forKey: Self.completedKey)
            case .show(let saved):
                step = saved == .mac || saved == .pair ? .link : saved
                presented = true
                replay = defaults.bool(forKey: Self.replayKey)
                action = Action(rawValue: defaults.string(forKey: Self.actionKey) ?? "") ?? .hold
                // A held finger cannot survive process death; repeat the hold safely.
                if action == .release { action = .hold }
            }
            if replay, saved == .practice { step = .practice; presented = true }
        }
        link.startDeferred = localHome || connectionDeferred
    }
    func go(_ step: OnboardingStep) {
        if step == .link || step == .ready { connectNow() }
        self.step = step; presented = true
        if preview == nil { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }
    func startPractice(replay: Bool = false) {
        self.replay = replay
        if preview == nil { defaults.set(replay, forKey: Self.replayKey) }
        setAction(.hold); go(.practice)
    }
    func setAction(_ action: Action) {
        self.action = action
        if preview == nil { defaults.set(action.rawValue, forKey: Self.actionKey) }
    }
    func performed(_ event: String) {
        guard presented, step == .practice else { return }
        switch (action, event) {
        case (.hold, "hold"): setAction(.release)
        case (.release, "release"): setAction(.send)
        case (.hold, "short"), (.release, "cancel"), (.release, "short"), (.release, "interrupt"): setAction(.hold)
        case (.send, "return"): setAction(.more)
        case (.delete, "delete"): setAction(.cursor)
        case (.cursor, "left"), (.cursor, "right"): setAction(.clear)
        case (.clear, "clear"): setAction(.cancel)
        case (.cancel, "cancel"): finishPractice()
        default: break
        }
    }
    func skip() {
        if step == .ready { complete(); return }
        switch action {
        case .hold, .release: setAction(.send)
        case .send: setAction(.more)
        case .more, .cancel: finishPractice()
        case .delete: setAction(.cursor)
        case .cursor: setAction(.clear)
        case .clear: setAction(.cancel)
        }
    }
    func finishPractice() {
        defaults.set(1, forKey: Self.tutorialKey)
        if replay { complete() } else { go(.link) }
    }
    func resume() { go(.link) }
    func connectNow() {
        connectionDeferred = false
        if preview == nil { defaults.removeObject(forKey: Self.deferredKey) }
    }
    func connectLater() {
        connectionDeferred = true
        if preview == nil { defaults.set(true, forKey: Self.deferredKey) }
        complete()
    }
    func complete() {
        if preview == nil {
            defaults.set(OnboardingPolicy.version, forKey: Self.completedKey)
            [Self.stepKey, Self.actionKey, Self.replayKey].forEach { defaults.removeObject(forKey: $0) }
        }
        presented = false; replay = false; celebrating = false
    }
    func receivedFirstResult(pasted: Bool) {
        guard presented, step == .ready, pasted, !celebrating else { return }
        celebrating = true
    }
}
