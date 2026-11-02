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
            InstrumentIdentity()
            Hairline()
            Text(L10n.text("Return here after installing")).modifier(InstrumentHint(color: Theme.ivory))
            ShareLink(item: OnboardingLinks.download) {
                HStack { Text(L10n.text("Share link")).modifier(InstrumentHint(color: Theme.ivory)); Spacer(); HUDLabel(text: "SHARE ›") }.frame(minHeight: 44).overlay(alignment: .bottom) { Hairline() }
            }
            Button {
                UIPasteboard.general.url = OnboardingLinks.download
                copied = true; Haptics.shared.play(.copy)
            } label: {
                HStack { Text(copied ? L10n.text("Copied") : L10n.text("Copy link")).modifier(InstrumentHint(color: Theme.ivory)); Spacer(); HUDLabel(text: "COPY ›") }.frame(minHeight: 44).overlay(alignment: .bottom) { Hairline() }
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
            next.webpageURL = OnboardingLinks.download; next.title = L10n.text("Get iMic for Mac")
            next.isEligibleForHandoff = true; next.becomeCurrent(); activity = next
        }
        .onDisappear { activity?.invalidate(); activity = nil }
    }
}

/// Only target decoration lives above the compositor. All teaching copy is Home's status.
struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var session: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let source: CGRect
    let torus: CGRect
    let size: CGSize
    let topInset: CGFloat

    private var moreVisible: Bool { onboarding.step == .practice && onboarding.action == .more }
    private var target: CGRect {
        onboarding.step == .welcome || onboarding.step == .ready || onboarding.action.bar ? source.insetBy(dx: -4, dy: -4) : torus
    }
    var body: some View {
        ZStack {
            if moreVisible { more }
            else if !onboarding.celebrating {
                HUDTarget(store: session.spectrumStore, target: target)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if onboarding.step == .practice {
                    CoachTouch(action: onboarding.action, source: source, torus: torus, reduceMotion: reduceMotion)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            #if DEBUG
            OnboardingAudit().position(x: size.width / 2, y: 100)
            #endif
        }
        .task(id: onboarding.action) {
            if voiceOver { UIAccessibility.post(notification: .announcement, argument: onboarding.action.prompt) }
        }
        .task(id: onboarding.celebrating) {
            guard onboarding.celebrating, onboarding.preview != "complete" else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { onboarding.complete() }
        }
    }
    private var more: some View {
        let height = source.minY + 100 - topInset
        let top = topInset + height * 0.145 + 110
        let panelHeight = min(240, max(0, torus.minY - top - 10))
        return VStack(alignment: .leading, spacing: 0) {
            HUDLabel(text: "MORE / GESTURES").frame(height: 12, alignment: .leading)
            ScrollView {
                VStack(spacing: 0) {
                    gestureRow(.delete, symbol: .up)
                    gestureRow(.cursor, symbol: .sideways)
                    gestureRow(.clear, symbol: .clear)
                    gestureRow(.cancel, symbol: .cancel)
                }
            }.scrollIndicators(.hidden)
            Button { onboarding.finishPractice() } label: {
                HStack { HUDLabel(text: "LATER"); Spacer(); HUDLabel(text: "›") }.frame(minHeight: 44)
            }.accessibilityIdentifier("onboarding.later")
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 4)
        .frame(width: source.width, height: panelHeight)
        .background(Theme.ink).overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.morePanel")
        .position(x: source.midX, y: top + panelHeight / 2)
    }
    private func gestureRow(_ action: OnboardingCoordinator.Action, symbol: PixelSymbol.Kind) -> some View {
        Button { onboarding.setAction(action) } label: {
            HStack(spacing: 12) {
                PixelSymbol(kind: symbol, color: Theme.muted).frame(width: 12, height: 12)
                Text(action.prompt).modifier(InstrumentHint(color: Theme.ivory))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HUDLabel(text: "TRY ›", color: Theme.orange)
            }.frame(minHeight: 44).contentShape(Rectangle())
                .overlay(alignment: .bottom) { Hairline() }
        }.accessibilityIdentifier(action == .delete ? "onboarding.more" : "onboarding.try." + action.rawValue)
    }
}

private struct HUDTarget: View {
    @ObservedObject var store: SpectrumStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: CGRect
    var body: some View {
        Canvas { context, _ in
            let opacity = reduceMotion ? 1 : 0.8 + 0.2 * sin(CACurrentMediaTime() * 2 * .pi / 1.6)
            var brackets = Path()
            for (x, y, dx, dy) in [(target.minX, target.minY, 1.0, 1.0),
                                   (target.maxX, target.minY, -1.0, 1.0),
                                   (target.minX, target.maxY, 1.0, -1.0),
                                   (target.maxX, target.maxY, -1.0, -1.0)] {
                brackets.move(to: CGPoint(x: x + dx * 9, y: y))
                brackets.addLine(to: CGPoint(x: x, y: y))
                brackets.addLine(to: CGPoint(x: x, y: y + dy * 9))
            }
            context.stroke(brackets, with: .color(Theme.ivory.opacity(opacity)), lineWidth: 0.7)
        }
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
        ZStack {
            if reduceMotion {
                PixelSymbol(kind: action == .cursor ? .sideways : .up, color: Theme.ivory)
                    .rotationEffect(.degrees(action == .send ? 180 : 0)).frame(width: 9, height: 9)
                    .position(x: start.x + 48, y: start.y)
            } else {
                Rectangle().fill(Theme.ivory).frame(width: 4, height: 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.ivory.opacity(0.4)).frame(width: 2, height: 12).offset(y: 12)
                    }
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
