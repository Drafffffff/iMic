import SwiftUI

/// 由主页面 NavigationStack 推入；配对码直接在列表中输入，不叠加第二个弹层。
struct DeviceSelectionView: View {
    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @State private var pendingSelection: RememberedMac?
    @State private var confirmSwitch = false

    private var nearbyIDs: Set<String> { Set(link.macs.map(\.id)) }
    private var otherRemembered: [RememberedMac] {
        link.rememberedMacs.filter { $0.id != link.selectedMacID && !nearbyIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    PixelText(text: "LINK", cell: 5, color: Theme.ivory, tracking: 3)
                    Text("选择接收语音的 Mac")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                currentTarget
                if needsPairing {
                    PairingSheet(embedded: true)
                        .id(link.selectedMacID)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("附近的 Mac", suffix: "\(link.macs.count)")
                    if link.macs.isEmpty {
                        Text("尚未发现 Mac。请打开电脑上的 iMic；同一 Wi-Fi 或附近蓝牙均可连接。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(link.macs) { mac in
                            deviceRow(id: mac.id, name: mac.name, nearby: true)
                        }
                    }
                }
                if !otherRemembered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("已记住的 Mac", suffix: "未在局域网发现")
                        ForEach(otherRemembered) { mac in
                            deviceRow(id: mac.id, name: mac.name, nearby: false)
                        }
                    }
                }
                Text("切换不会删除配对。选定后，iMic 只会重连这台 Mac，不会自动转到其他电脑。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.ink.ignoresSafeArea())
        .modifier(PhosphorNativeGlass())
        .navigationTitle("连接电脑")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.orange)
        .confirmationDialog("取消当前语音并切换 Mac？", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("取消语音并切换", role: .destructive) {
                if let mac = pendingSelection { performSelection(mac) }
                pendingSelection = nil
            }
            Button("继续当前语音", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("当前录音或识别会停止，不会把尚未发送的内容交给另一台 Mac。已完成的识别结果会保留。")
        }
    }

    private var needsPairing: Bool {
        if case .needsCode = link.phase { return true }
        return link.pairing && !link.phase.isReady
    }

    private var currentTarget: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("当前目标", suffix: link.phase.isReady
                         ? (link.transport == .bluetooth ? "蓝牙 · 加密" : "局域网 · 加密") : "")
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.orange).frame(width: 3, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(link.selectedMacName ?? link.phase.macName ?? "尚未选择 Mac")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.ivory)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(connectionStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if case .connecting = link.phase {
                    ProgressView().tint(Theme.orange)
                }
            }
            if !link.phase.isReady && !needsPairing {
                Button("重新连接 / 搜索") {
                    Haptics.shared.play(.tap)
                    link.retry()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.orange)
                .frame(minHeight: 36)
            }
            if link.phase.isReady, link.transport == .bluetooth,
               session.phase != .listening, session.phase != .transcribing {
                Button("改用局域网") {
                    Haptics.shared.play(.tap)
                    link.reconnectUsingNetwork()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.orange)
                .frame(minHeight: 36)
            }
            Hairline()
        }
    }

    private var connectionStatus: String {
        switch link.phase {
        case .ready:
            return link.transport == .bluetooth
                ? "蓝牙带宽有限，长录音松手后仍需补传。建议在同一 Wi-Fi 下改用局域网。"
                : "语音和按键通过局域网发送到这台 Mac"
        case .connecting: return "正在连接所选 Mac，可稍后重试或选择其他电脑"
        case .needsCode: return "首次连接需要输入 Mac 窗口中的 6 位配对码"
        case .failed(let message): return message
        case .searching, .idle:
            if link.isManualSelection { return "所选 Mac 离线或尚未发现，正在等待连接" }
            return link.pairedMacIDs.isEmpty ? "正在搜索 Mac，可从下方选择电脑" : "正在寻找已配对的 Mac"
        }
    }

    private func sectionTitle(_ title: String, suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.orange)
            Spacer(minLength: 8)
            Text(suffix).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func deviceRow(id: String, name: String, nearby: Bool) -> some View {
        let selected = id == link.selectedMacID
        return Button {
            guard !selected else { return }
            Haptics.shared.play(.selection)
            let mac = RememberedMac(id: id, name: name)
            if session.phase == .listening || session.phase == .transcribing {
                pendingSelection = mac
                confirmSwitch = true
            } else {
                performSelection(mac)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(selected ? Theme.orange : Theme.muted)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ivory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(link.pairedMacIDs.contains(id) ? "已配对" : "需要配对") · \(nearby ? "局域网可用" : "等待 Wi-Fi / 蓝牙")")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark" : "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.orange : Theme.muted)
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name)，\(selected ? "当前目标" : "切换到这台 Mac")，\(link.pairedMacIDs.contains(id) ? "已配对" : "需要配对")")
    }

    private func performSelection(_ mac: RememberedMac) {
        session.cancelForDeviceSwitch()
        link.selectRememberedMac(mac)
    }
}
