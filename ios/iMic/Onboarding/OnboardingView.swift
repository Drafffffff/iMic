import SwiftUI
import UIKit

struct GuideTitle: View {
    let text: String
    var cell: CGFloat = 3
    var color: Color = Theme.orange
    var body: some View {
        PixelText(text: text, cell: cell, color: color)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Shared download actions, with a real Handoff activity and system share sheet.
struct MacDownloadView: View {
    @State private var copied = false
    @State private var activity: NSUserActivity?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GuideTitle(text: "iMic", cell: 4, color: Theme.ivory)
            Text(L10n.text("Return here after installing")).font(.body)
            ShareLink(item: OnboardingLinks.download) {
                Label(L10n.text("Share link"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }
            Button {
                UIPasteboard.general.url = OnboardingLinks.download
                copied = true; Haptics.shared.play(.copy)
            } label: {
                Label(copied ? L10n.text("Copied") : L10n.text("Copy link"), systemImage: "doc.on.doc").frame(minHeight: 44)
            }.accessibilityIdentifier("download.copy")
            Text(L10n.text("Open the Safari Handoff icon on your Mac"))
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.ivory).tint(Theme.orange)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationBackground(Theme.ink)
        .onAppear {
            let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            next.webpageURL = OnboardingLinks.download; next.title = L10n.text("Get iMic for Mac")
            next.isEligibleForHandoff = true; next.becomeCurrent(); activity = next
        }
        .onDisappear { activity?.invalidate(); activity = nil }
    }
}

/// Cutouts use the real HomeView anchors, after the Metal compositor has rendered.
struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var session: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var promptGap: CGFloat = 85
    @AccessibilityFocusState private var promptFocused: Bool
    let source: CGRect
    let torus: CGRect
    let size: CGSize
    let topInset: CGFloat

    private var focus: CGRect {
        if onboarding.step == .welcome || onboarding.celebrating || onboarding.action == .more && onboarding.step == .practice { return .zero }
        return onboarding.step == .ready || onboarding.action.bar ? source.insetBy(dx: -4, dy: -4) : torus
    }
    var body: some View {
        ZStack {
            CoachShade(hole: focus)
                .fill(.black.opacity(0.60), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            // Outside the focused component touches stop here; the cutout passes through.
            Color.clear.contentShape(CoachShade(hole: focus), eoFill: true)
                .onTapGesture { }
                .accessibilityHidden(true)
            if onboarding.step == .welcome {
                welcome
            } else if onboarding.celebrating {
                Text(L10n.text("That's it.")).font(.body).foregroundStyle(Theme.ivory)
                    .accessibilityIdentifier("onboarding.complete")
                    .position(x: size.width / 2, y: size.height * 0.40)
            } else if onboarding.action == .more && onboarding.step == .practice {
                more
            } else {
                coach
            }
            if onboarding.step != .welcome && !onboarding.celebrating {
                HStack {
                    Button(L10n.text("Skip")) { onboarding.skip() }
                        .accessibilityIdentifier("onboarding.skip").frame(minWidth: 44, minHeight: 44)
                    Spacer()
                    if onboarding.step == .practice {
                        PixelText(text: onboarding.action.progress, cell: 1.3, color: Theme.ivory)
                            .fixedSize()
                            .accessibilityHidden(false)
                            .accessibilityLabel(onboarding.action.progress)
                    }
                }
                .foregroundStyle(Theme.ivory).font(.callout)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .padding(.horizontal, 24)
                .frame(width: size.width, height: 64)
                .position(x: size.width / 2, y: topInset + 69)
            }
            #if DEBUG
            OnboardingAudit().position(x: size.width / 2, y: 100)
            #endif
        }
        .task(id: onboarding.action) {
            promptFocused = true
            if voiceOver { UIAccessibility.post(notification: .announcement, argument: onboarding.action.prompt) }
        }
        .task(id: onboarding.celebrating) {
            guard onboarding.celebrating, onboarding.preview != "complete" else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { onboarding.complete() }
        }
    }
    private var welcome: some View {
        VStack(spacing: 26) {
            Image("Wordmark").resizable().scaledToFit().frame(width: 120, height: 45).accessibilityLabel("iMic")
            Text(L10n.text("One phone. Every input.")).font(.body).multilineTextAlignment(.center)
            Button(L10n.text("Get started")) { onboarding.startPractice() }
                .font(.headline).frame(minWidth: 140, minHeight: 48)
                .foregroundStyle(Theme.ink).background(Theme.ivory)
                .accessibilityIdentifier("onboarding.start")
        }
        .foregroundStyle(Theme.ivory).padding(24)
        .position(x: size.width / 2, y: size.height * 0.43)
        .overlay(alignment: .bottom) {
            Button(L10n.text("I've used iMic before")) { onboarding.go(.link) }
                .font(.callout).foregroundStyle(Theme.ivory).frame(minHeight: 44)
                .position(x: size.width / 2, y: size.height - (dynamicType.isAccessibilitySize ? 90 : 42))
        }
    }
    private var more: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("More gestures")).font(.body)
            HStack {
                Button(L10n.text("Show me")) { onboarding.setAction(.delete) }.accessibilityIdentifier("onboarding.more")
                Spacer()
                Button(L10n.text("Later")) { onboarding.finishPractice() }.accessibilityIdentifier("onboarding.later")
            }.font(.callout).frame(minHeight: 44)
        }
        .foregroundStyle(Theme.ivory).padding(20).background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.line))
        .padding(.horizontal, 24).frame(maxWidth: 420)
        .position(x: size.width / 2, y: min(size.height - 100, source.minY - 32))
    }
    private var coach: some View {
        let bar = onboarding.step == .ready || onboarding.action.bar
        let prompt = onboarding.step == .ready
            ? L10n.text("Click your Mac's input, then hold to speak") : onboarding.action.prompt
        let promptHeight = max(44, bar ? min(promptGap * 1.8, source.minY - topInset - 140) : source.minY - torus.maxY - 32)
        return ZStack {
            ScrollView(.vertical) {
            VStack(spacing: 8) {
                Text(prompt).font(.body).foregroundStyle(Theme.ivory)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.prompt")
                    .accessibilityFocused($promptFocused)
                    .accessibilityAddTraits(.updatesFrequently)
                if onboarding.step == .ready {
                    Text(L10n.text("Microphone access is needed when you speak"))
                        .font(.footnote).foregroundStyle(Theme.ivory.opacity(0.8))
                }
                if voiceOver {
                    Button(L10n.text("Skip this step")) { onboarding.skip() }.frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, minHeight: promptHeight)
            }
            .scrollIndicators(.hidden)
            .frame(height: promptHeight)
            .position(x: size.width / 2, y: bar ? max(topInset + 120, source.minY - promptGap) : (torus.maxY + source.minY) / 2)
            if onboarding.step == .practice {
                CoachTouch(action: onboarding.action, source: source, torus: torus, reduceMotion: reduceMotion)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

private struct CoachShade: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if !hole.isEmpty { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 5, height: 5)) }
        return path
    }
}

private struct CoachTouch: View {
    let action: OnboardingCoordinator.Action
    let source: CGRect
    let torus: CGRect
    let reduceMotion: Bool
    @State private var moved = false
    @State private var visible = true
    private var start: CGPoint { action.bar ? CGPoint(x: source.midX, y: source.midY) : CGPoint(x: torus.midX, y: torus.midY) }
    private var delta: CGSize {
        switch action {
        case .send: return CGSize(width: 0, height: 100)
        case .delete: return CGSize(width: 0, height: -75)
        case .cursor: return CGSize(width: 90, height: 0)
        case .clear: return CGSize(width: 0, height: 84 - torus.midY)
        case .cancel: return CGSize(width: 0, height: -100)
        case .release: return CGSize(width: 0, height: -22)
        default: return .zero
        }
    }
    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: action == .send ? "arrow.down" : action == .cursor ? "arrow.right" : action == .hold ? "hand.tap" : "arrow.up")
                    .font(.title2).foregroundStyle(Theme.ivory.opacity(0.65))
                    .position(x: start.x + 48, y: start.y)
            } else {
                Circle().fill(Theme.ivory.opacity(0.32)).frame(width: 44, height: 44)
                    .position(x: start.x + (moved ? delta.width : 0), y: start.y + (moved ? delta.height : 0))
                    .opacity(visible ? 1 : 0)
            }
        }
        .task(id: action) {
            moved = false; visible = true
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { moved = true }
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
    }
}

struct GuideSettingsSection: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @State private var download = false
    var onPresentationChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GuideTitle(text: "GUIDE", cell: 1.6).accessibilityLabel(L10n.text("How to use iMic"))
            Button(L10n.text("Practice gestures again")) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onboarding.startPractice(replay: true) }
            }.frame(minHeight: 44)
            Button(L10n.text("Get the Mac app")) { download = true }.frame(minHeight: 44)
        }
        .onChange(of: download) { _, value in onPresentationChanged(value) }
        .sheet(isPresented: $download) { MacDownloadView() }
    }
}
