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
                        Text(L10n.text("AI polish and conversion"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ivory)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 8)
                    if displayedPreferences != nil {
                        Toggle(L10n.text("Enable AI polish"), isOn: Binding(
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
                        .accessibilityHint(L10n.text("Saved to your connected Mac. Takes effect after your Mac confirms."))
                    }
                }

                connectionStatus
            }

            if let error = link.polishPreferencesError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.text("Change not confirmed, %@", L10n.argument(error)))
            }

            if let preferences = displayedPreferences {
                preferencesEditor(preferences)
                    .disabled(!isAvailable || link.polishPreferencesSaving)
                    .opacity(isAvailable ? 1 : 0.6)
            }

            Text(L10n.text("Configure the service, API Key, and model on your Mac."))
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
                sectionHeading("MODE", title: L10n.text("Conversion mode"))
                optionsGrid(PolishMode.allCases, selected: preferences.options.mode, title: { $0.title }) { mode in
                    update { $0.options.mode = mode }
                }
                optionDetail(preferences.options.mode.detail)
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("TONE", title: L10n.text("Tone"))
                optionsGrid(PolishTone.allCases, selected: preferences.options.tone, title: { $0.title }) { tone in
                    update { $0.options.tone = tone }
                }
                .disabled(preferences.options.isCommand)
                .opacity(preferences.options.isCommand ? 0.45 : 1)
                if preferences.options.isCommand {
                    optionDetail(L10n.text("Terminal commands focus on actions and ignore tone. Your choice is kept for text modes."))
                } else {
                    optionDetail(preferences.options.tone.detail)
                    Text(L10n.text("Example: %@", L10n.argument(preferences.options.tone.example)))
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
                sectionHeading("LANGUAGE", title: L10n.text("Output language"))
                optionsGrid(PolishOutput.languages, selected: preferences.options.output, title: { $0.title }) { output in
                    update { $0.options.output = output }
                }
                .disabled(preferences.options.isCommand)
                .opacity(preferences.options.isCommand ? 0.45 : 1)
                optionDetail(preferences.options.isCommand
                    ? L10n.text("Commands always use zsh syntax, regardless of output language. Your language choice is kept.")
                    : L10n.text("Apply the mode and tone in your selected language, even if the source is already in that language."))
            }
            Text(link.polishPreferencesSaving ? L10n.text("Submitting these choices. They take effect after your Mac confirms.")
                 : (preferences.enabled ? preferences.options.summary : L10n.text("Currently disabled. Your mode, tone, and language are saved on your Mac.")))
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
                .accessibilityValue(selected == value ? L10n.text("Selected") : L10n.text("Not selected"))
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
                return (L10n.text("Connecting to your Mac"), L10n.text("Your Mac's actual preferences will load once connected. Offline changes are not saved."))
            case .needsCode:
                return (L10n.text("Complete pairing first"), L10n.text("Enter the six-digit pairing code shown on your Mac above."))
            default:
                return (L10n.text("No Mac connected"), L10n.text("Connect to your Mac above. Previously confirmed preferences are shown for reference."))
            }
        }
        guard link.polishPreferencesSupported else {
            return (L10n.text("This Mac does not support phone settings yet"), L10n.text("Update iMic on your Mac to set mode, tone, and output language from your phone."))
        }
        if link.polishPreferencesSaving {
            return (L10n.text("Waiting for your Mac · Not saved yet"), "")
        }
        guard link.polishPreferences != nil else {
            return (link.polishPreferencesError == nil ? L10n.text("Reading Mac preferences") : L10n.text("Mac preferences not loaded"),
                    L10n.text("Changes are unavailable until preferences load. Phone defaults never replace your Mac's settings here."))
        }
        if link.polishPreferencesError != nil {
            return (L10n.text("This change was not confirmed"), L10n.text("Below are the last preferences confirmed by your Mac, rather than the unsaved changes."))
        }
        return (L10n.text("Confirmed by your Mac"), L10n.text("Below are your Mac's saved preferences. Wait for a new confirmation after each change."))
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
