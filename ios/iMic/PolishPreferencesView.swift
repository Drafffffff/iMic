import SwiftUI

@MainActor
struct PolishPreferencesView: View {
    @EnvironmentObject private var link: LinkClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    destination
                    connectionStatus

                    if let error = link.polishPreferencesError {
                        VStack(alignment: .leading, spacing: 8) {
                            MetaLabel(text: "NOT CONFIRMED", color: Theme.orange)
                            Text(error)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(link.polishPreferences == nil
                                 ? "尚未取得 Mac 确认的偏好，暂时无法修改。"
                                 : "下方保留 Mac 上次确认的值。连接可用时，可再次调整以重新提交。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if let preferences = link.polishPreferences {
                        preferencesEditor(preferences)
                            .disabled(!canEdit)
                            .opacity(canEdit ? 1 : 0.6)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Hairline()
                            Text("尚未获取这台 Mac 的润色偏好，因此暂不显示开关与选项。连接并读取成功后，才可修改。")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Hairline()
                        MetaLabel(text: "CONFIGURED ON MAC")
                        Text("这里只修改当前连接 Mac 的润色开关、强度与场景。API Key、服务来源与地址仍由 Mac 配置，不会传到 iPhone。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .background(Theme.ink)
            .navigationTitle("AI 润色偏好")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        Haptics.shared.play(.tap)
                        dismiss()
                    }
                    .tint(Theme.muted)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText(text: "POLISH", cell: 3.4, color: Theme.ivory, tracking: 2)
            Text("每次调整都会发送到 Mac；收到 Mac 回显，才表示已经保存。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetaLabel(text: "TARGET MAC")
            Text(targetName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ivory)
                .fixedSize(horizontal: false, vertical: true)
            if !link.phase.isReady {
                Text("当前未连接，不能保存更改。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目标 Mac，\(targetName)\(link.phase.isReady ? "，已连接" : "，未连接")")
    }

    private var connectionStatus: some View {
        let status = statusDescription
        return VStack(alignment: .leading, spacing: 9) {
            Hairline()
            HStack(spacing: 10) {
                if isWaiting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.orange)
                        .accessibilityHidden(true)
                } else {
                    Rectangle()
                        .fill(canEdit ? Theme.orange : Theme.muted)
                        .frame(width: 4, height: 14)
                        .accessibilityHidden(true)
                }
                Text(status.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ivory)
            }
            Text(status.detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func preferencesEditor(_ preferences: LinkPolishPreferences) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("ENABLE", title: "AI 润色")
                Toggle(isOn: Binding(
                    get: { preferences.enabled },
                    set: { enabled in update { $0.enabled = enabled } }
                )) {
                    Text("启用 AI 润色")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ivory)
                }
                .tint(Theme.orange)
                .accessibilityHint("保存到当前连接的 Mac，等待 Mac 确认后生效")
                Text("关闭时保留识别原文；强度和场景仍会保存在 Mac。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Hairline()
                sectionHeading("STRENGTH", title: "润色强度")
                HStack(spacing: 8) {
                    ForEach(PolishStrength.allCases, id: \.self) { strength in
                        let selected = preferences.options.strength == strength
                        Button {
                            update { $0.options.strength = strength }
                        } label: {
                            Text(strength.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(selected ? Theme.orange : Theme.ivory)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .padding(.horizontal, 6)
                                .overlay(Rectangle().stroke(selected ? Theme.orange : Theme.line, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("润色强度，\(strength.title)")
                        .accessibilityValue(selected ? "已选择" : "未选择")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Hairline()
                sectionHeading("SCENARIO", title: "使用场景")
                VStack(spacing: 0) {
                    ForEach(PolishScenario.allCases, id: \.self) { scenario in
                        let selected = preferences.options.scenario == scenario
                        Button {
                            update { $0.options.scenario = scenario }
                        } label: {
                            HStack(spacing: 16) {
                                Text(scenario.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(selected ? Theme.orange : Theme.ivory)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(selected ? Theme.orange : Theme.muted)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 48)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("使用场景，\(scenario.title)")
                        .accessibilityValue(selected ? "已选择" : "未选择")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        Hairline()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                MetaLabel(text: "LAST CONFIRMED", color: Theme.muted)
                Text(preferences.options.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                if !preferences.enabled {
                    Text("当前未启用；以上规则将在开启 AI 润色后使用。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionHeading(_ technical: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            PixelText(text: technical, cell: 1.7, color: Theme.muted, tracking: 1.5)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ivory)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var targetName: String {
        switch link.phase {
        case .ready(let name), .needsCode(let name), .connecting(let name):
            return name
        default:
            return link.selectedMacName ?? "尚未选择 Mac"
        }
    }

    private var canEdit: Bool {
        link.phase.isReady && link.polishPreferencesSupported
            && link.polishPreferences != nil && !link.polishPreferencesSaving
    }

    private var isWaiting: Bool {
        link.phase.isReady && link.polishPreferencesSupported
            && (link.polishPreferencesSaving
                || (link.polishPreferences == nil && link.polishPreferencesError == nil))
    }

    private var statusDescription: (title: String, detail: String) {
        guard link.phase.isReady else {
            switch link.phase {
            case .connecting:
                return ("正在连接 Mac", "连接完成后会读取 Mac 的真实偏好。离线时不会保存更改。")
            case .needsCode:
                return ("请先完成配对", "关闭本页，在连接页输入 Mac 上显示的六位配对码。")
            default:
                return ("尚未连接 Mac", "请先在连接页选择并连接 Mac。已确认的值仅供查看，不代表当前在线状态。")
            }
        }
        guard link.polishPreferencesSupported else {
            return ("这台 Mac 暂不支持手机设置", "请更新 Mac 端 iMic；当前无法从 iPhone 读取或修改润色偏好。")
        }
        if link.polishPreferencesSaving {
            return ("等待 Mac 确认", "正在保存到当前 Mac，控件暂时不可编辑。下方保留上次确认的值，收到回显后更新。")
        }
        guard link.polishPreferences != nil else {
            return (link.polishPreferencesError == nil ? "正在读取 Mac 偏好" : "尚未获取 Mac 偏好",
                    "读取成功前不可修改；这里不会用手机默认值代替 Mac 的设置。")
        }
        if link.polishPreferencesError != nil {
            return ("本次更改未获确认", "下方是 Mac 上次确认的偏好，而非未保存的更改。")
        }
        return ("已由 Mac 确认", "下方为当前 Mac 已保存的偏好。每次调整后，请等待新的确认。")
    }

    private func update(_ change: (inout LinkPolishPreferences) -> Void) {
        guard canEdit, let confirmed = link.polishPreferences else { return }
        var preferences = confirmed
        change(&preferences)
        guard preferences != confirmed else { return }
        if link.updatePolishPreferences(preferences) {
            Haptics.shared.play(.selection)
        }
    }
}
