import SwiftUI
import UIKit

/// PixelText is decorative by default; the parent supplies an accessible heading.
struct GuideTitle: View {
    let text: String
    var cell: CGFloat = 3
    var color: Color = Theme.orange
    var body: some View {
        HStack { PixelText(text: text, cell: cell, color: color) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits([.isHeader, .isStaticText])
    }
}

struct GuideButton: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: "arrow.right")
            }.foregroundStyle(Theme.ivory).padding(18)
                .background(Theme.panelRaised)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.orange).frame(width: 3) }
                .overlay(Rectangle().stroke(Theme.line))
        }.buttonStyle(.plain)
    }
}

struct MacDownloadView: View {
    @State var expanded = true
    @State private var copied = false
    @State private var activity: NSUserActivity?
    var installed: (() -> Void)? = nil
    var practice: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Is iMic installed on your Mac?")).font(.title3.weight(.semibold))
            Text(L10n.text("iMic needs its Mac companion. Your Mac handles recognition and types text into the active app."))
            if let installed, !expanded { GuideButton(title: L10n.text("It's installed"), action: installed) }
            if !expanded {
                GuideButton(title: L10n.text("Send the download link to my Mac")) { expanded = true }
            } else {
                MetaLabel(text: "01 / HANDOFF", color: Theme.orange)
                Text(L10n.text("If your Mac and iPhone use the same Apple ID, a Safari icon will appear on the left of your Mac's Dock. Click it to open the download page."))
                ShareLink(item: OnboardingLinks.download) {
                    Label(L10n.text("Share link"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                Button {
                    UIPasteboard.general.url = OnboardingLinks.download
                    copied = true
                    Haptics.shared.play(.copy)
                } label: {
                    Label(L10n.text("Copy link"), systemImage: "doc.on.doc").frame(minHeight: 44)
                }
                if copied {
                    Text(L10n.text("Copied. Paste on your Mac with Universal Clipboard enabled."))
                        .foregroundStyle(Theme.orange).accessibilityIdentifier("download.copied")
                }
                Hairline()
                Text(L10n.text("1. Download and open iMic on your Mac (macOS 13 or later)\n\n2. Follow the Mac setup guide to enter your Model Studio (Bailian) API Key\n\n3. Return here to continue"))
                Text(L10n.text("Create your own Alibaba Cloud API Key. Recognition incurs a small usage fee."))
                    .font(.footnote).foregroundStyle(Theme.muted)
                if let installed { GuideButton(title: L10n.text("It's installed on my Mac. Continue"), action: installed) }
            }
            if let practice { Button(L10n.text("Explore how it works"), action: practice).frame(minHeight: 44) }
        }
        .onAppear {
            let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            next.webpageURL = OnboardingLinks.download
            next.title = L10n.text("Get iMic for Mac")
            next.isEligibleForHandoff = true
            next.becomeCurrent()
            activity = next
        }
        .onDisappear { activity?.invalidate(); activity = nil }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var searching = false
    @State private var timedOut = false
    @State private var searchGeneration = 0
    @State private var openedSettings = false
    @State private var connectedName: String?
    @State private var practiceInteracting = false
    @State private var requestingPermissions = false

    private var label: String { ["WELCOME", "MAC", "LINK", "PAIR", "PRACTICE", "READY"][onboarding.step.rawValue] }
    var body: some View {
        ZStack {
            TechBackground()
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    if onboarding.step != .welcome {
                        Button { back() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.text("Back"))
                    }
                    Spacer()
                    MetaLabel(text: "IMIC / FIRST CONNECTION")
                }
                HStack(spacing: 5) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                        Rectangle().fill(step == onboarding.step ? Theme.orange : Theme.line).frame(height: 2)
                    }
                }.accessibilityLabel(L10n.text("Setup progress, step %@ of 6", L10n.argument(onboarding.step.rawValue + 1)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        GuideTitle(text: label, cell: 2.8, color: Theme.orange)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboarding.title")
                        content
                        #if DEBUG
                        OnboardingAudit()
                        #endif
                    }.padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden).scrollDisabled(practiceInteracting)
            }.padding(.horizontal, 24).padding(.top, 8)
        }
        .foregroundStyle(Theme.ivory).tint(Theme.orange).font(.body)
        .preferredColorScheme(.dark).interactiveDismissDisabled()
        .onAppear { enteredStep() }
        .onChange(of: onboarding.step) { _, _ in enteredStep() }
        .onChange(of: link.macs.map(\.id)) { _, _ in advanceToPair() }
        .onChange(of: link.phase) { _, _ in advanceToPair() }
        .onChange(of: scenePhase) { _, phase in
            guard searching else { return }
            if phase == .active {
                if openedSettings { openedSettings = false; link.retry() }
                else { link.activate() }
            } else if phase == .background {
                link.enterBackground()
            }
        }
        .task(id: searchGeneration) {
            guard searching else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, searching, link.macs.isEmpty else { return }
            timedOut = true
        }
        .task(id: connectedName) {
            guard connectedName != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, link.phase.isReady, onboarding.step == .pair else { return }
            onboarding.go(onboarding.tutorialComplete ? .ready : .practice)
        }
    }
    @ViewBuilder private var content: some View {
        switch onboarding.step {
        case .welcome:
            GuideTitle(text: "iMic", cell: 5, color: Theme.ivory).accessibilityLabel("iMic")
            Text(L10n.text("Use your iPhone as a microphone. Release when done to type straight into your Mac."))
            WelcomeWaveform().frame(height: 210)
            Label(L10n.text("Hold to speak, release to type"), systemImage: "mic")
            Label(L10n.text("String gestures: Return, delete, move cursor"), systemImage: "waveform")
            Label(L10n.text("Direct encrypted connection. Your Key stays on your Mac."), systemImage: "lock")
            GuideButton(title: L10n.text("Get started")) { onboarding.go(.mac) }
        case .mac:
            MacDownloadView(expanded: onboarding.preview == "mac-download",
                installed: { onboarding.go(.link) }, practice: { onboarding.practiceFromMac() })
        case .link:
            if link.localNetworkDenied {
                GuideTitle(text: "LOCAL NETWORK OFF", cell: 1.65, color: Theme.orange)
                Text(L10n.text("Local Network access is off, so iMic cannot find your Mac. Enable Local Network in Settings → iMic."))
                GuideButton(title: L10n.text("Open Settings"), action: settings)
            } else if searching {
                ProgressView().tint(Theme.orange).accessibilityLabel(L10n.text("Looking for a Mac"))
                Text(L10n.text("Searching… Keep iMic open on your Mac."))
            } else {
                Text(L10n.text("iMic will look for your Mac on the same Wi-Fi. Choose Allow when asked for Local Network access."))
                VStack(spacing: 18) {
                    GuideTitle(text: "LOCAL NETWORK", cell: 1.7, color: Theme.ivory)
                    Text(L10n.text("Allow iMic to find and connect to\ndevices on your local network?")).multilineTextAlignment(.center)
                    HStack { Text(L10n.text("Don't Allow")).foregroundStyle(Theme.muted); Spacer(); Text(L10n.text("Allow")).foregroundStyle(Theme.orange) }
                    MetaLabel(text: "PERMISSION / ILLUSTRATION")
                }.padding(24).background(Theme.panel).overlay(Rectangle().stroke(Theme.line))
                    .accessibilityLabel(L10n.text("Permission illustration: choose Allow in the system dialog"))
                GuideButton(title: L10n.text("Find my Mac")) { startSearch() }
            }
            if timedOut { troubleshooting }
            Button(L10n.text("Connect later")) { onboarding.presented = false }.frame(minHeight: 44)
        case .pair:
            if let connectedName {
                Text(L10n.text("✓ Connected to %@", L10n.argument(connectedName))).foregroundStyle(Theme.orange)
            } else {
                if link.macs.count > 1 {
                    Text(L10n.text("Choose the Mac to pair with"))
                }
                PairingSheet(embedded: true)
                if link.macs.isEmpty { Text(L10n.text("Looking for a Mac…")); if timedOut { troubleshooting } }
                Button(L10n.text("Connect later")) { onboarding.presented = false }.frame(minHeight: 44)
            }
        case .practice:
            PracticeView(preview: onboarding.preview, onInteractionChanged: { practiceInteracting = $0 }) { onboarding.finishPractice() }
        case .ready:
            Text(L10n.text("Click any text field on your Mac, such as Notes. Then hold the bar below and say something."))
            Text(L10n.text("Tap Start using iMic to request Microphone access (required), then Speech Recognition access (optional, for live preview on your phone)."))
                .font(.footnote).foregroundStyle(Theme.muted)
            GuideButton(title: L10n.text("Start using iMic")) {
                guard !requestingPermissions else { return }
                requestingPermissions = true
                Task {
                    await session.prepareFirstUsePermissions()
                    onboarding.complete()
                    link.startDeferred = false
                    link.start()
                    requestingPermissions = false
                }
            }.disabled(requestingPermissions)
            Button(L10n.text("Having trouble on your Mac?")) { openURL(OnboardingLinks.home) }.frame(minHeight: 44)
        }
    }
    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 16) {
            MetaLabel(text: "CHECK CONNECTION", color: Theme.orange)
            Text(L10n.text("1. Is iMic open on your Mac? Look for the microphone icon in the menu bar."))
            Text(L10n.text("2. Are your iPhone and Mac on the same Wi-Fi?"))
            Text(L10n.text("3. Guest, office, and hotel networks often block connections between devices. Try a personal hotspot."))
            Text(L10n.text("4. Is a VPN or proxy enabled?"))
            Text(L10n.text("5. Is your Mac's firewall blocking incoming connections to iMic?"))
            Text(L10n.text("6. Have you allowed Local Network access?"))
            Button(L10n.text("Open Settings"), action: settings).frame(minHeight: 44)
        }.font(.callout).accessibilityIdentifier("onboarding.troubleshooting")
    }
    private func settings() {
        openedSettings = true
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
    private func startSearch() {
        onboarding.searchRequested = true
        searching = true; timedOut = false; searchGeneration += 1
        link.startDeferred = false
        link.start()
        advanceToPair()
    }
    private func enteredStep() {
        connectedName = nil
        if onboarding.step == .link || onboarding.step == .pair {
            if onboarding.preview != nil {
                searching = onboarding.preview != "link"
                timedOut = onboarding.preview == "search-timeout"
            } else if onboarding.step == .pair || onboarding.searchRequested {
                startSearch()
            }
            advanceToPair()
        }
    }
    private func advanceToPair() {
        guard searching || onboarding.step == .pair else { return }
        guard onboarding.step == .link || onboarding.step == .pair else { return }
        if link.phase.isReady {
            if onboarding.step != .pair { onboarding.go(.pair) }
            if connectedName == nil { Haptics.shared.play(.pairingSuccess); connectedName = link.phase.macName }
        } else if !link.macs.isEmpty || link.phase.macName != nil {
            if onboarding.step != .pair { onboarding.go(.pair) }
            if link.macs.count == 1, case .searching = link.phase { link.connect(to: link.macs[0]) }
        }
    }
    private func back() {
        if onboarding.step == .practice, onboarding.practiceReturnsToMac { onboarding.go(.mac) }
        else { onboarding.go(OnboardingStep(rawValue: max(0, onboarding.step.rawValue - 1)) ?? .welcome) }
    }
}

private struct WelcomeWaveform: View {
    @StateObject private var spectrum = SpectrumStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TorusView(store: spectrum, instrumentHUD: true, channelLabel: "PREVIEW")
            .accessibilityLabel(L10n.text("iMic phosphor waveform demo"))
            .onAppear { spectrum.configureAmbientMotion(enabled: true, reducedMotion: reduceMotion); spectrum.setVisible(true) }
            .onDisappear { spectrum.setVisible(false) }
            .onChange(of: reduceMotion) { _, value in spectrum.configureAmbientMotion(enabled: true, reducedMotion: value) }
    }
}

struct GuideSettingsSection: View {
    @State private var destination: Destination?
    @State private var practiceInteracting = false
    var onPresentationChanged: (Bool) -> Void = { _ in }
    private enum Destination: String, Identifiable { case practice, download; var id: String { rawValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideTitle(text: "GUIDE", cell: 1.6, color: Theme.orange).accessibilityLabel(L10n.text("How to use iMic"))
            Text(L10n.text("How to use iMic")).font(.headline)
            Button(L10n.text("Practice gestures again")) { destination = .practice }.frame(minHeight: 44)
            Button(L10n.text("Get the Mac app")) { destination = .download }.frame(minHeight: 44)
        }
        .onChange(of: destination) { _, value in onPresentationChanged(value != nil) }
        .sheet(item: $destination) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if item == .practice {
                            PracticeView(onInteractionChanged: { practiceInteracting = $0 }) { destination = nil }
                        } else {
                            GuideTitle(text: "MAC", cell: 3, color: Theme.orange)
                            MacDownloadView()
                        }
                    }.padding(24)
                }.scrollDisabled(practiceInteracting).background(Theme.ink).foregroundStyle(Theme.ivory)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Close")) { destination = nil } } }
            }.preferredColorScheme(.dark)
        }
    }
}
