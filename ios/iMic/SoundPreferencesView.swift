import SwiftUI

struct SoundPreferencesSection: View {
    @AppStorage(SoundDesign.preferenceKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                PixelText(text: "SOUND", cell: 2.1, color: Theme.ivory, tracking: 1.5)
                Text(L10n.text("Interface sounds")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ivory)
            }
            HStack(spacing: 8) {
                option(on: true, label: "ON", title: L10n.text("On"))
                option(on: false, label: "OFF", title: L10n.text("Off"))
            }
            Text(L10n.text("Play short sounds for submit, launch, connection, and errors. Follows the Silent switch and Ringtone and Alerts volume. Silent while recording to keep sounds out of recognition."))
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            SoundCueList()
            #endif
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func option(on: Bool, label: String, title: String) -> some View {
        let selected = enabled == on
        return Button {
            Haptics.shared.play(.tap)
            enabled = on
            IMicLog.write("iphone.sound", "preference enabled=\(on)")
            if on { SoundDesign.shared.play(.connected) }
        } label: {
            VStack(spacing: 9) {
                PixelText(text: label, cell: 1.3, color: selected ? Theme.orange : Theme.muted, tracking: 0.7)
                Text(title).font(.system(size: 11)).foregroundStyle(selected ? Theme.ivory : Theme.muted)
            }.frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle())
                .overlay(Rectangle().stroke(selected ? Theme.orange.opacity(0.8) : Theme.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("Interface sounds: %@", L10n.argument(title)))
            .accessibilityValue(selected ? L10n.text("Selected") : L10n.text("Not selected"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if DEBUG
/// 调试试听：逐个播放全部音色（忽略开关）。只存在于 Debug 构建。
struct SoundCueList: View {
    @State private var playing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PixelText(text: "AUDITION", cell: 1.5, color: Theme.muted, tracking: 1)
                Spacer()
                Button {
                    playAll()
                } label: {
                    PixelText(text: "PLAY ALL", cell: 1.4, color: Theme.orange, tracking: 0.8)
                        .frame(minWidth: 72, minHeight: 32)
                        .overlay(Rectangle().stroke(Theme.orange.opacity(0.6), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("Play all sounds in order"))
            }
            ForEach(SoundFamily.allCases, id: \.self) { family in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        PixelText(text: family.rawValue, cell: 1.2, color: Theme.muted, tracking: 0.8)
                        Text(family.title).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    ForEach(SoundCue.allCases.filter { $0.family == family }) { cue in
                        ForEach(0..<cue.variantCount, id: \.self) { variant in
                            row(cue, variant: variant)
                        }
                    }
                }
            }
        }
    }

    private func row(_ cue: SoundCue, variant: Int) -> some View {
        let key = cue.key(variant)
        let patch = cue.patch(variant)
        return Button {
            playing = key
            SoundDesign.shared.audition(cue, variant: variant)
        } label: {
            HStack(spacing: 10) {
                PixelText(text: cue.variantCount > 1 ? "\(cue.label) \(variant + 1)" : cue.label,
                          cell: 1.3, color: playing == key ? Theme.orange : Theme.ivory, tracking: 0.7)
                    .frame(width: 92, alignment: .leading)
                Text(cue.title).font(.system(size: 12)).foregroundStyle(Theme.ivory)
                Spacer()
                Text("\(Int((patch.duration * 1000).rounded()))ms \(Int(patch.peakDB))dB")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }.frame(minHeight: 36).padding(.horizontal, 10).contentShape(Rectangle())
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("Preview %@", L10n.argument(cue.title)))
            .accessibilityIdentifier("sound.\(key)")
    }

    private func playAll() {
        let items = SoundCue.allCases.flatMap { cue in (0..<cue.variantCount).map { (cue, $0) } }
        for (index, item) in items.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.45) {
                playing = item.0.key(item.1)
                SoundDesign.shared.audition(item.0, variant: item.1)
            }
        }
    }
}

/// `--ui-preview=sounds`：独立的试听页面，不连接 Mac、不打开麦克风。
struct SoundPreviewRoot: View {
    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SoundPreferencesSection()
                }.padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { SoundDesign.shared.warmUp() }
    }
}
#endif
