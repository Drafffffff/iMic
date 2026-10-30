#if DEBUG
import SwiftUI
import AVFoundation
import Speech

/// Explicit UI-test probe, absent from Release. Reads the same local log and OS permission states.
struct OnboardingAudit: View {
    @State private var result: String?
    @State private var clipboard: String?
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--debug-onboarding-audit") {
            VStack(alignment: .leading) {
                Button("检查练习隔离") {
                    let log = (try? String(contentsOf: IMicLog.fileURL, encoding: .utf8)) ?? ""
                    let lines = log.split(separator: "\n")
                    let link = lines.filter { $0.contains("[iphone.link]") }.count
                    let sends = lines.filter { $0.contains("[iphone.content] send kind=") }.count
                    let mic = AVAudioSession.sharedInstance().recordPermission == .undetermined ? "undetermined" : "determined"
                    let speech = SFSpeechRecognizer.authorizationStatus() == .notDetermined ? "undetermined" : "determined"
                    result = "link=\(link) send=\(sends) mic=\(mic) speech=\(speech) tutorial=\(UserDefaults.standard.integer(forKey: OnboardingCoordinator.tutorialKey))"
                    if ProcessInfo.processInfo.arguments.contains("--ui-preview=onboarding-mac") {
                        clipboard = UIPasteboard.general.url?.absoluteString
                    }
                }
                if let result { Text(result).accessibilityIdentifier("onboarding.audit") }
                if let clipboard { Text(clipboard) }
            }.font(.caption2)
        }
    }
}
#endif
