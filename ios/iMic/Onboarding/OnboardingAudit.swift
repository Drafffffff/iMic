#if DEBUG
import SwiftUI
import AVFoundation
import Speech

/// Explicit UI-test probe, absent from Release. Reads the same local log and OS permission states.
struct OnboardingAudit: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var connection: LinkClient
    @State private var result: String?
    @State private var clipboard: String?
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--debug-onboarding-audit") {
            VStack(alignment: .leading) {
                Button(L10n.text("Check practice isolation")) {
                    let log = (try? String(contentsOf: IMicLog.fileURL, encoding: .utf8)) ?? ""
                    let interval = session.practiceActive ? (log.components(separatedBy: "[iphone.practice] active=true").last ?? log) : log
                    let lines = interval.split(separator: "\n")
                    let link = lines.filter { $0.contains("[iphone.link]") }.count
                    let sends = lines.filter { $0.contains("[iphone.content] send kind=") }.count
                    let captureStarts = lines.filter {
                        $0.contains("[iphone.audio]") && ($0.contains("start requested generation=") || $0.contains("silent-capture retry="))
                    }.count
                    let mic = AVAudioSession.sharedInstance().recordPermission == .undetermined ? "undetermined" : "determined"
                    let speech = SFSpeechRecognizer.authorizationStatus() == .notDetermined ? "undetermined" : "determined"
                    result = "link=\(link) send=\(sends) mic=\(mic) speech=\(speech) practice=\(session.practiceActive) phase=\(session.phase) text=\(session.transcript.count) deferred=\(connection.startDeferred) idle=\(connection.phase == .idle) captureStarts=\(captureStarts)"
                    if ProcessInfo.processInfo.arguments.contains("--ui-preview=onboarding-mac") {
                        clipboard = UIPasteboard.general.url?.absoluteString
                    }
                }.accessibilityIdentifier("onboarding.auditCheck")
                if let result { Text(result).accessibilityIdentifier("onboarding.audit") }
                if let clipboard { Text(clipboard) }
            }.font(.caption2)
        }
    }
}
#endif
