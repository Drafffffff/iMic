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
                    Text(L10n.text("Choose the Mac that receives your voice"))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                currentTarget
                if needsPairing {
                    PairingSheet(embedded: true)
                        .id(link.selectedMacID)
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(L10n.text("Nearby Macs"), suffix: "\(link.macs.count)")
                    if link.macs.isEmpty {
                        Text(L10n.text("No Mac found. Open iMic on your computer. Connect over the same Wi-Fi or nearby Bluetooth."))
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
                        sectionTitle(L10n.text("Remembered Macs"), suffix: L10n.text("Not found on the local network"))
                        ForEach(otherRemembered) { mac in
                            deviceRow(id: mac.id, name: mac.name, nearby: false)
                        }
                    }
                }
                Text(L10n.text("Switching keeps your pairings. iMic will reconnect only to the selected Mac and will not switch to another computer automatically."))
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
        .navigationTitle(L10n.text("Connect to a computer"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.orange)
        .confirmationDialog(L10n.text("Cancel this voice session and switch Macs?"), isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button(L10n.text("Cancel session and switch"), role: .destructive) {
                if let mac = pendingSelection { performSelection(mac) }
                pendingSelection = nil
            }
            Button(L10n.text("Continue this session"), role: .cancel) { pendingSelection = nil }
        } message: {
            Text(L10n.text("Recording or recognition will stop. Unsent audio will not go to another Mac. Completed results will be kept."))
        }
    }

    private var needsPairing: Bool {
        if case .needsCode = link.phase { return true }
        return link.pairing && !link.phase.isReady
    }

    private var currentTarget: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.text("Current target"), suffix: link.phase.isReady
                         ? (link.transport == .bluetooth ? L10n.text("Bluetooth · Encrypted") : L10n.text("Local network · Encrypted")) : "")
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.orange).frame(width: 3, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(link.selectedMacName ?? link.phase.macName ?? L10n.text("No Mac selected"))
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
                Button(L10n.text("Reconnect / Search")) {
                    Haptics.shared.play(.tap)
                    link.retry()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.orange)
                .frame(minHeight: 36)
            }
            if link.phase.isReady, link.transport == .bluetooth,
               session.phase != .listening, session.phase != .transcribing {
                Button(L10n.text("Use local network")) {
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
                ? L10n.text("Bluetooth has limited bandwidth. Long recordings may keep uploading after release. Use the local network on the same Wi-Fi for faster transfers.")
                : L10n.text("Voice and keystrokes go to this Mac over the local network")
        case .connecting: return L10n.text("Connecting to the selected Mac. Retry later or choose another computer.")
        case .needsCode: return L10n.text("For your first connection, enter the 6-digit pairing code shown on your Mac")
        case .failed(let message): return message
        case .searching, .idle:
            if link.isManualSelection { return L10n.text("The selected Mac is offline or not yet found. Waiting to connect.") }
            return link.pairedMacIDs.isEmpty ? L10n.text("Searching for Macs. Choose a computer below.") : L10n.text("Looking for your paired Mac")
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
                    Text(L10n.text("%@ · %@", L10n.argument(link.pairedMacIDs.contains(id) ? L10n.text("Paired") : L10n.text("Pairing required")), L10n.argument(nearby ? L10n.text("Local network available") : L10n.text("Waiting for Wi-Fi / Bluetooth"))))
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
        .accessibilityLabel(L10n.text("%@, %@, %@", L10n.argument(name), L10n.argument(selected ? L10n.text("Current target") : L10n.text("Switch to this Mac")), L10n.argument(link.pairedMacIDs.contains(id) ? L10n.text("Paired") : L10n.text("Pairing required"))))
    }

    private func performSelection(_ mac: RememberedMac) {
        session.cancelForDeviceSwitch()
        link.selectRememberedMac(mac)
    }
}
