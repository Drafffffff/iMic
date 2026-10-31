import SwiftUI

@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let completedKey = "imic.onboarding.completedVersion"
    static let stepKey = "imic.onboarding.step"
    static let tutorialKey = "imic.tutorial.completedVersion"
    private static let practiceOriginKey = "imic.onboarding.practiceReturnsToMac"
    @Published var presented = false
    @Published private(set) var step: OnboardingStep = .welcome
    @Published private(set) var practiceReturnsToMac = false
    private let defaults = UserDefaults.standard
    var searchRequested = false
    private(set) var preview: String? = nil
    var tutorialComplete: Bool { defaults.integer(forKey: Self.tutorialKey) >= 1 }
    private var bypass = false
    var unfinished: Bool { !bypass && defaults.integer(forKey: Self.completedKey) < OnboardingPolicy.version }

    init(link: LinkClient) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-reset-onboarding") {
            try? FileManager.default.removeItem(at: IMicLog.fileURL)
            [Self.completedKey, Self.stepKey, Self.tutorialKey, Self.practiceOriginKey].forEach { defaults.removeObject(forKey: $0) }
        }
        preview = args.first { $0.hasPrefix("--ui-preview=onboarding-") }
            .map { String($0.dropFirst("--ui-preview=onboarding-".count)) }
        // Existing UI fixtures and explicit integration clients keep their previous lifecycle.
        if preview == nil, args.contains(where: { $0.hasPrefix("--ui-preview=") || $0.hasPrefix("--debug-host=") }) { bypass = true; return }
        #else
        preview = nil
        #endif
        if let preview {
            if preview.hasPrefix("mac") { step = .mac }
            else if preview.hasPrefix("link") || preview == "search-timeout" { step = .link }
            else if preview == "pair" { step = .pair }
            else if preview.hasPrefix("practice") { step = .practice }
            else if preview == "ready" { step = .ready }
            presented = true
        } else {
            let saved = defaults.object(forKey: Self.stepKey).flatMap { ($0 as? Int).flatMap(OnboardingStep.init(rawValue:)) }
            switch OnboardingPolicy.decide(completedVersion: defaults.integer(forKey: Self.completedKey),
                                           savedStep: saved, hasPairedMac: link.hasPairedMac || !link.pairedMacIDs.isEmpty) {
            case .skip: break
            case .skipAndMarkComplete: defaults.set(OnboardingPolicy.version, forKey: Self.completedKey)
            case .show(let saved):
                step = saved; presented = true
                searchRequested = saved == .link || saved == .pair
                practiceReturnsToMac = saved == .practice && defaults.bool(forKey: Self.practiceOriginKey)
            }
        }
        link.startDeferred = presented
        if presented, preview == nil { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }

    func go(_ next: OnboardingStep) {
        step = next
        if next != .practice { practiceReturnsToMac = false }
        if preview == nil {
            defaults.set(next.rawValue, forKey: Self.stepKey)
            if next != .practice { defaults.removeObject(forKey: Self.practiceOriginKey) }
        }
    }
    func practiceFromMac() {
        practiceReturnsToMac = true
        if preview == nil { defaults.set(true, forKey: Self.practiceOriginKey) }
        go(.practice)
    }
    func finishPractice() {
        defaults.set(1, forKey: Self.tutorialKey)
        go(practiceReturnsToMac ? .mac : .ready)
        practiceReturnsToMac = false
    }
    func resume() { presented = true }
    func complete() {
        defaults.set(OnboardingPolicy.version, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
        defaults.removeObject(forKey: Self.practiceOriginKey)
        presented = false
    }
}
