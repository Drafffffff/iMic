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
            Text("Mac 上装好 iMic 了吗？").font(.title3.weight(.semibold))
            Text("iMic 需要电脑端配合。Mac 端负责识别和把文字输入到当前应用。")
            if let installed, !expanded { GuideButton(title: "已经装好了", action: installed) }
            if !expanded {
                GuideButton(title: "还没有，发送到我的 Mac") { expanded = true }
            } else {
                MetaLabel(text: "01 / HANDOFF", color: Theme.orange)
                Text("如果 Mac 和 iPhone 登录同一 Apple ID，Mac 程序坞左侧会出现一个 Safari 图标，点它即可打开下载页。")
                ShareLink(item: OnboardingLinks.download) {
                    Label("共享链接", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                Button {
                    UIPasteboard.general.url = OnboardingLinks.download
                    copied = true
                    Haptics.shared.play(.copy)
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc").frame(minHeight: 44)
                }
                if copied {
                    Text("已复制，可在 Mac 上直接粘贴（需开启通用剪贴板）")
                        .foregroundStyle(Theme.orange).accessibilityIdentifier("download.copied")
                }
                Hairline()
                Text("1. 在 Mac 上下载并打开 iMic（macOS 13 及以上）\n\n2. 按 Mac 上的设置向导填入百炼 API Key\n\n3. 回到这里继续")
                Text("百炼 API Key 由你自己在阿里云申请，识别会产生少量费用。")
                    .font(.footnote).foregroundStyle(Theme.muted)
                if let installed { GuideButton(title: "Mac 上装好了，继续", action: installed) }
            }
            if let practice { Button("先看看怎么用", action: practice).frame(minHeight: 44) }
        }
        .onAppear {
            let next = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            next.webpageURL = OnboardingLinks.download
            next.title = "获取 iMic Mac 版"
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
                            .accessibilityLabel("返回")
                    }
                    Spacer()
                    MetaLabel(text: "IMIC / FIRST CONNECTION")
                }
                HStack(spacing: 5) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                        Rectangle().fill(step == onboarding.step ? Theme.orange : Theme.line).frame(height: 2)
                    }
                }.accessibilityLabel("设置进度，第 \(onboarding.step.rawValue + 1) 步，共 6 步")
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
            Text("iPhone 当麦克风，说完松手，文字直接打进 Mac。")
            WelcomeWaveform().frame(height: 210)
            Label("按住说话，松手即输入", systemImage: "mic")
            Label("弦手势：回车、删除、移动光标", systemImage: "waveform")
            Label("局域网加密直连，Key 只存在你的 Mac", systemImage: "lock")
            GuideButton(title: "开始") { onboarding.go(.mac) }
        case .mac:
            MacDownloadView(expanded: onboarding.preview == "mac-download",
                installed: { onboarding.go(.link) }, practice: { onboarding.practiceFromMac() })
        case .link:
            if link.localNetworkDenied {
                GuideTitle(text: "LOCAL NETWORK OFF", cell: 1.65, color: Theme.orange)
                Text("本地网络权限已关闭，iMic 无法找到 Mac。请在「设置 → iMic」中打开「本地网络」。")
                GuideButton(title: "打开设置", action: settings)
            } else if searching {
                ProgressView().tint(Theme.orange).accessibilityLabel("正在寻找 Mac")
                Text("正在寻找… 请保持 Mac 上的 iMic 打开。")
            } else {
                Text("接下来 iMic 会在同一 Wi-Fi 中寻找你的 Mac，系统会询问是否允许访问本地网络，请选择「允许」。")
                VStack(spacing: 18) {
                    GuideTitle(text: "LOCAL NETWORK", cell: 1.7, color: Theme.ivory)
                    Text("允许 iMic 寻找并连接\n本地网络上的设备？").multilineTextAlignment(.center)
                    HStack { Text("不允许").foregroundStyle(Theme.muted); Spacer(); Text("允许").foregroundStyle(Theme.orange) }
                    MetaLabel(text: "PERMISSION / ILLUSTRATION")
                }.padding(24).background(Theme.panel).overlay(Rectangle().stroke(Theme.line))
                    .accessibilityLabel("权限示意图：请在系统弹窗选择允许")
                GuideButton(title: "开始寻找 Mac") { startSearch() }
            }
            if timedOut { troubleshooting }
            Button("稍后再连接") { onboarding.presented = false }.frame(minHeight: 44)
        case .pair:
            if let connectedName {
                Text("✓ 已连接 \(connectedName)").foregroundStyle(Theme.orange)
            } else {
                if link.macs.count > 1 {
                    Text("选择你要配对的 Mac")
                }
                PairingSheet(embedded: true)
                if link.macs.isEmpty { Text("正在寻找 Mac…"); if timedOut { troubleshooting } }
                Button("稍后再连接") { onboarding.presented = false }.frame(minHeight: 44)
            }
        case .practice:
            PracticeView(preview: onboarding.preview, onInteractionChanged: { practiceInteracting = $0 }) { onboarding.finishPractice() }
        case .ready:
            Text("在 Mac 上点一下任意输入框（比如备忘录），然后按住下面的横条说一句话。")
            Text("点「开始使用」后，系统会依次请求麦克风权限（必需）和语音识别权限（用于手机上的实时预览，可以拒绝）。")
                .font(.footnote).foregroundStyle(Theme.muted)
            GuideButton(title: "开始使用") {
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
            Button("在 Mac 上使用时遇到问题？") { openURL(OnboardingLinks.home) }.frame(minHeight: 44)
        }
    }
    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 16) {
            MetaLabel(text: "CHECK CONNECTION", color: Theme.orange)
            Text("1. Mac 上的 iMic 是否已打开？菜单栏能看到麦克风图标。")
            Text("2. iPhone 和 Mac 是否在同一个 Wi-Fi？")
            Text("3. 访客、公司或酒店网络常禁止设备互相访问，可以改用手机热点试试。")
            Text("4. 是否开着 VPN 或代理？")
            Text("5. Mac 的防火墙是否阻止了 iMic 的传入连接？")
            Text("6.「本地网络」权限是否已允许？")
            Button("打开设置", action: settings).frame(minHeight: 44)
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
            .accessibilityLabel("iMic 荧光波形演示")
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
            GuideTitle(text: "GUIDE", cell: 1.6, color: Theme.orange).accessibilityLabel("使用教程")
            Text("使用教程").font(.headline)
            Button("重新练习手势") { destination = .practice }.frame(minHeight: 44)
            Button("获取 Mac 版") { destination = .download }.frame(minHeight: 44)
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
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { destination = nil } } }
            }.preferredColorScheme(.dark)
        }
    }
}
