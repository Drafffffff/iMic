import SwiftUI

/// 设置页内直接编辑；展示与提交均使用 Mac 确认的唯一偏好状态。
@MainActor
struct PolishPreferencesSection: View {
    @EnvironmentObject private var link: LinkClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // A transient, visibly unconfirmed selection prevents native switches from
    // snapping back while awaiting ACK. It is never persisted or replayed.
    @State private var requestedPreferences: LinkPolishPreferences?
    @State private var requestedMacID: String?

    private var displayedPreferences: LinkPolishPreferences? {
        if link.polishPreferencesSaving, requestedMacID == link.selectedMacID,
           let requestedPreferences { return requestedPreferences }
        return link.polishPreferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        PixelText(text: "POLISH", cell: 2.1, color: Theme.ivory, tracking: 1.5)
                        Text("AI 润色与转换")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ivory)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    if displayedPreferences != nil {
                        Toggle("启用 AI 润色", isOn: Binding(
                            get: { displayedPreferences?.enabled ?? false },
                            set: { enabled in update { $0.enabled = enabled } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        // iOS 27 的原生开关绘制比旧的布局宽度更宽，
                        // 保留固有尺寸和独立留白，避免滚动容器切掉右端。
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 76, minHeight: 44, alignment: .trailing)
                        .tint(Theme.orange)
                        .disabled(!isAvailable || link.polishPreferencesSaving)
                        .accessibilityHint("保存到当前连接的 Mac，等待 Mac 确认后生效")
                    }
                }

                connectionStatus
            }

            if let error = link.polishPreferencesError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("更改未获确认，\(error)")
            }

            if let preferences = displayedPreferences {
                preferencesEditor(preferences)
                    .disabled(!isAvailable || link.polishPreferencesSaving)
                    .opacity(isAvailable ? 1 : 0.6)
            }

            Text("转换服务、API Key 与模型请在 Mac 配置。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: link.polishPreferencesSaving) { _, saving in
            if !saving { clearRequest() }
        }
        .onChange(of: link.selectedMacID) { _, _ in clearRequest() }
        .onChange(of: link.phase) { _, phase in
            if !phase.isReady { clearRequest() }
        }
    }

    private var connectionStatus: some View {
        let status = statusDescription
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    if isWaiting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.orange)
                    } else {
                        Rectangle()
                            .fill(isAvailable ? Theme.orange : Theme.muted)
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(width: 12, height: 16)
                .accessibilityHidden(true)
                Text(status.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: status.title)
            }
            .frame(height: 16, alignment: .leading)
            // Saving occupies the same single row as confirmation. Details only
            // expand for an actual connection or confirmation problem.
            if !isAvailable || link.polishPreferencesError != nil {
                Text(status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func preferencesEditor(_ preferences: LinkPolishPreferences) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("MODE", title: "转换模式")
                optionsGrid(PolishMode.allCases, selected: preferences.options.mode, title: { $0.title }) { mode in
                    update { $0.options.mode = mode }
                }
                optionDetail(preferences.options.mode.detail)
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("TONE", title: "表达语气")
                optionsGrid(PolishTone.allCases, selected: preferences.options.tone, title: { $0.title }) { tone in
                    update { $0.options.tone = tone }
                }
                .disabled(preferences.options.isCommand)
                .opacity(preferences.options.isCommand ? 0.45 : 1)
                if preferences.options.isCommand {
                    optionDetail("终端命令专注操作，不叠加语气；切回文字模式后恢复选择。")
                } else {
                    optionDetail(preferences.options.tone.detail)
                    Text("例如：\(preferences.options.tone.example)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.ivory.opacity(0.035))
                        .accessibilityIdentifier("polish-tone-example")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("LANGUAGE", title: "输出语言")
                optionsGrid(PolishOutput.languages, selected: preferences.options.output, title: { $0.title }) { output in
                    update { $0.options.output = output }
                }
                .disabled(preferences.options.isCommand)
                .opacity(preferences.options.isCommand ? 0.45 : 1)
                optionDetail(preferences.options.isCommand
                    ? "命令语法固定为 zsh，不受输出语言影响；语言选择会保留。"
                    : "用所选语言呈现模式和语气，原文已是该语言也会转换。")
            }
            Text(link.polishPreferencesSaving ? "正在提交以上选择，等待 Mac 确认后生效。"
                 : (preferences.enabled ? preferences.options.summary : "当前未启用；模式、语气与语言已保存在 Mac。"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
                .accessibilityIdentifier("polish-summary")
        }
    }

    private func optionsGrid<Value: Hashable>(_ values: [Value], selected: Value,
        title: @escaping (Value) -> String, select: @escaping (Value) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(values, id: \.self) { value in
                Button { select(value) } label: {
                    optionLabel(title(value), selected: selected == value)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(value))
                .accessibilityValue(selected == value ? "已选择" : "未选择")
                .accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }
    }

    private func optionDetail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func optionLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Theme.orange : Theme.ivory)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .background(selected ? Theme.orange.opacity(0.06) : .clear)
            .overlay(Rectangle().stroke(selected ? Theme.orange.opacity(0.8) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func sectionHeading(_ technical: String, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ivory)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            PixelText(text: technical, cell: 1.1, color: Theme.muted, tracking: 0.8)
                .accessibilityHidden(true)
        }
    }

    private var isAvailable: Bool {
        link.phase.isReady && link.polishPreferencesSupported
            && link.polishPreferences != nil
    }

    private var canEdit: Bool {
        isAvailable && !link.polishPreferencesSaving
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
                return ("请先完成配对", "在上方输入 Mac 上显示的六位配对码。")
            default:
                return ("尚未连接 Mac", "请先在上方连接 Mac；上次确认的偏好仅供查看。")
            }
        }
        guard link.polishPreferencesSupported else {
            return ("这台 Mac 暂不支持手机设置", "请更新 Mac 端 iMic，以支持模式、语气和输出语言设置。")
        }
        if link.polishPreferencesSaving {
            return ("等待 Mac 确认 · 尚未保存", "")
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
        requestedMacID = link.selectedMacID
        requestedPreferences = preferences
        if link.updatePolishPreferences(preferences) {
            Haptics.shared.play(.selection)
        } else { clearRequest() }
    }

    private func clearRequest() {
        requestedPreferences = nil
        requestedMacID = nil
    }
}
