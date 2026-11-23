import SwiftUI
import UIKit

/// The website replaces the former in-app tutorial: it explains setup and hosts the Mac download.
enum SiteLinks {
    static var home: URL { URL(string: "https://drafffffff.github.io/iMic/" + (L10n.isChinese ? "" : "en/"))! }
    static var download: URL { URL(string: "?from=ios#download", relativeTo: home)!.absoluteURL }
    /// Short, typeable form shown on screen.
    static let display = "drafffffff.github.io/iMic"
}

struct MacDownloadView: View {
    @State private var copied = false
    @State private var activity: NSUserActivity?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InstrumentIdentity()
            Hairline()
            Text(L10n.text("Open this address on your Mac to download VoxChord for Mac")).modifier(InstrumentHint(color: Theme.ivory))
            Text(SiteLinks.display).font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.orange).textSelection(.enabled).accessibilityIdentifier("download.address")
            Text(L10n.text("Return here after installing")).modifier(InstrumentHint())
            ShareLink(item: SiteLinks.download) {
                HStack { Text(L10n.text("Share link")).modifier(InstrumentHint(color: Theme.ivory)); Spacer(); HUDLabel(text: "SHARE ›") }.frame(minHeight: 44).contentShape(Rectangle()).overlay(alignment: .bottom) { Hairline() }
            }
            Button {
                UIPasteboard.general.url = SiteLinks.download
                copied = true; Haptics.shared.play(.copy)
            } label: {
                HStack { Text(copied ? L10n.text("Copied") : L10n.text("Copy link")).modifier(InstrumentHint(color: Theme.ivory)); Spacer(); HUDLabel(text: "COPY ›") }.frame(minHeight: 44).contentShape(Rectangle()).overlay(alignment: .bottom) { Hairline() }
            }.accessibilityIdentifier("download.copy")
            Text(L10n.text("Open the Safari Handoff icon on your Mac"))
                .modifier(InstrumentHint())
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.ivory).tint(Theme.orange)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationBackground(Theme.ink)
        .onAppear {
            let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            next.webpageURL = SiteLinks.download; next.title = L10n.text("Get VoxChord for Mac")
            next.isEligibleForHandoff = true; next.becomeCurrent(); activity = next
        }
        .onDisappear { activity?.invalidate(); activity = nil }
    }
}

/// Settings › GUIDE: the website is the manual; the Mac download stays one tap away.
struct GuideSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @State private var download = false
    var onPresentationChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText(text: "GUIDE", cell: 1.6, color: Theme.orange)
                .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("How to use VoxChord"))
                .accessibilityAddTraits(.isHeader)
            Button { openURL(SiteLinks.home) } label: {
                HStack {
                    Text(L10n.text("Open the website"))
                    Spacer()
                    Text(SiteLinks.display).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }.frame(minHeight: 44).contentShape(Rectangle()).accessibilityIdentifier("guide.website")
            Button(L10n.text("Get the Mac app")) { download = true }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .onChange(of: download) { _, value in onPresentationChanged(value) }
        .sheet(isPresented: $download) { MacDownloadView() }
    }
}
