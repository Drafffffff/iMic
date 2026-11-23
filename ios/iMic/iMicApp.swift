import SwiftUI
import UIKit

@main
struct iMicApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--waveform-replay=") }) {
                WaveformDebugReplayRoot(selection: String(argument.dropFirst("--waveform-replay=".count)))
            } else if ProcessInfo.processInfo.arguments.contains("--ui-preview=sounds") {
                SoundPreviewRoot()
            } else {
                LiveApplicationView()
            }
            #else
            LiveApplicationView()
            #endif
        }
    }
}

private struct LiveApplicationView: View {
    @StateObject private var link: LinkClient
    @StateObject private var session: SessionModel

    init() {
        let link = LinkClient()
        _link = StateObject(wrappedValue: link)
        _session = StateObject(wrappedValue: SessionModel(link: link))
    }

    var body: some View {
        HomeView()
            .environmentObject(link)
            .environmentObject(session)
            .preferredColorScheme(.dark)
            .background {
                IdleScreenObserver(busy: session.phase == .listening || session.phase == .transcribing || session.isUploading,
                                   onActivity: { session.spectrumStore.wake() })
            }
    }
}
