import SwiftUI

struct VoiceProcessingPreferencesSection: View {
    @AppStorage(VoiceProcessingPreference.key) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDLabel(text: "VPIO")
            Toggle(isOn: $enabled) {
                Text(L10n.text("Voice processing (recommended)"))
                    .font(.body).foregroundStyle(Theme.ivory)
            }
            .tint(Theme.orange)
            .accessibilityIdentifier("voice-processing-setting")
            Text(L10n.text("Noise reduction, echo cancellation, and automatic gain. Turning this off may prevent recording on some system versions."))
                .font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
