import SwiftUI

/// 两个入口共用同一套会话保护与手动选机逻辑；各页面独立持有弹窗状态。
@MainActor
final class MacSwitchCoordinator: ObservableObject {
    @Published var showingConfirmation = false
    private var selection: (() -> Void)?

    func request(_ mac: RememberedMac, link: LinkClient, session: SessionModel,
                 selected: @escaping (_ id: String, _ paired: Bool) -> Void = { _, _ in }) {
        guard mac.id != link.selectedMacID || !link.phase.isReady else { return }
        let action = {
            let paired = link.pairedMacIDs.contains(mac.id)
            session.cancelForDeviceSwitch()
            Haptics.shared.play(.selection)
            if let nearby = link.macs.first(where: { $0.id == mac.id }) {
                link.connect(to: nearby)
            } else {
                link.selectRememberedMac(mac)
            }
            selected(mac.id, paired)
        }
        if session.phase == .listening || session.phase == .transcribing || session.isUploading {
            selection = action
            showingConfirmation = true
        } else {
            cancel()
            action()
        }
    }

    func confirm() {
        let action = selection
        cancel()
        action?()
    }

    func cancel() {
        showingConfirmation = false
        selection = nil
    }
}

private struct MacSwitchConfirmation: ViewModifier {
    @ObservedObject var coordinator: MacSwitchCoordinator

    func body(content: Content) -> some View {
        content.confirmationDialog("取消当前语音并切换 Mac？",
            isPresented: $coordinator.showingConfirmation, titleVisibility: .visible) {
            Button("取消语音并切换", role: .destructive) { coordinator.confirm() }
            Button("继续当前语音", role: .cancel) { coordinator.cancel() }
        } message: {
            Text("当前录音或识别会停止，不会把尚未发送的内容交给另一台 Mac。已完成的识别结果会保留。")
        }
    }
}

extension View {
    func macSwitchConfirmation(_ coordinator: MacSwitchCoordinator) -> some View {
        modifier(MacSwitchConfirmation(coordinator: coordinator))
    }
}

/// 仅用于菜单显示排序，复用配对与最近连接排序；不改变自动连接策略。
struct QuickMacTarget: Identifiable {
    let id: String
    let name: String
    let online: Bool
    let current: Bool
    let connected: Bool
    let bluetooth: Bool

    var status: String { connected && bluetooth ? "蓝牙" : online ? "局域网" : "离线" }
    var accessibilityLabel: String {
        "\(name)，已配对，\(connected && bluetooth ? "蓝牙已连接" : online ? "局域网可用" : "离线")\(current ? "，当前目标" : "")"
    }

    static func paired(in link: LinkClient) -> [QuickMacTarget] {
        var names = Dictionary(link.rememberedMacs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for mac in link.macs { names[mac.id] = mac.name }
        let onlineIDs = Set(link.macs.map(\.id))
        let connectedID = link.phase.isReady ? link.selectedMacID : nil
        let ids = names.keys.filter { link.pairedMacIDs.contains($0) }
        func ordered(_ candidates: [String]) -> [String] {
            MacSelection.orderedPaired(candidates.map {
                MacCandidate(id: $0, paired: true, lastConnected: link.macConnectionDates[$0])
            }, preferredID: connectedID)
        }
        let online = ids.filter { onlineIDs.contains($0) || $0 == connectedID }
        let offline = ids.filter { !onlineIDs.contains($0) && $0 != connectedID }
        return (ordered(online) + ordered(offline)).map { id in
            QuickMacTarget(id: id, name: names[id] ?? "Mac", online: onlineIDs.contains(id) || id == connectedID,
                current: id == link.selectedMacID, connected: id == connectedID,
                bluetooth: id == connectedID && link.transport == .bluetooth)
        }
    }
}

/// 设备页的可取消返回意图：计时只在同一目标持续 connecting 时有效。
@MainActor
final class MacSwitchReturn: ObservableObject {
    private var targetID: String?
    private var paired = false
    private var task: Task<Void, Never>?

    func begin(id: String, paired: Bool, link: LinkClient, returned: @escaping () -> Void) {
        cancel()
        targetID = id
        self.paired = paired
        update(link: link, returned: returned)
    }

    func update(link: LinkClient, returned: @escaping () -> Void) {
        task?.cancel()
        task = nil
        guard let id = targetID, link.selectedMacID == id else { return }
        if link.phase.isReady {
            cancel()
            returned()
        } else if case .connecting = link.phase, paired {
            task = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                guard let self, !Task.isCancelled, self.targetID == id, link.selectedMacID == id,
                      case .connecting = link.phase else { return }
                self.cancel()
                returned()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        targetID = nil
    }
}
