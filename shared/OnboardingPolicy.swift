public enum OnboardingStep: Int, CaseIterable {
    case welcome, mac, link, pair, practice, ready
}

public enum OnboardingPolicy {
    public static let version = 1
    public enum Decision: Equatable {
        case skip, skipAndMarkComplete, show(OnboardingStep)
    }
    public static func decide(completedVersion: Int, savedStep: OnboardingStep?, hasPairedMac: Bool) -> Decision {
        if completedVersion >= version { return .skip }
        if let savedStep { return .show(savedStep) }
        if hasPairedMac { return .skipAndMarkComplete }
        return .show(.welcome)
    }
}
