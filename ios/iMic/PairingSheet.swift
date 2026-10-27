import SwiftUI
import UIKit

struct PairingSheet: View {
    private enum UtilitySheet: String, Identifiable {
        case waveforms

        var id: String { rawValue }
    }

    @EnvironmentObject private var link: LinkClient
    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var code = ""
    @State private var submittedCode = ""
    @State private var showForget = false
    @State private var utilitySheet: UtilitySheet?
    @FocusState private var codeFocused: Bool
    var embedded = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ZStack {
                    Theme.ink.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        Hairline()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                content
                                    .padding(.top, 8)
                                    .padding(.bottom, 24)
                                Hairline()
                                PolishPreferencesSection()
                                    .padding(.vertical, 24)
                                Hairline()
                                DisplayPreferencesSection()
                                    .padding(.vertical, 24)
                                Hairline()
                                footer
                                    .padding(.top, 12)
                            }
                            .padding(.bottom, 18)
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 18)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
                .modifier(PhosphorNativeGlass())
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Theme.ink)
            }
        }
        .onAppear {
            if case .needsCode = link.phase {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if utilitySheet == nil { codeFocused = true }
                }
            }
        }
        .onChange(of: link.phase) { _, phase in
            switch phase {
            case .ready:
                Haptics.shared.play(.pairingSuccess)
                codeFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if !embedded, utilitySheet == nil { dismiss() }
                }
            case .needsCode:
                code = ""
                submittedCode = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if utilitySheet == nil { codeFocused = true }
                }
            default:
                break
            }
        }
        .onChange(of: code) { oldValue, value in
            let digits = PairingCode.normalize(value)
            if digits.count > oldValue.count {
                Haptics.shared.play(.codeDigit)
            }
            if digits != value { code = digits }
            guard digits.count == 6, digits != submittedCode else { return }
            submittedCode = digits
            codeFocused = false
            link.submitCode(digits)
        }
        .onChange(of: link.pairingError) { _, error in
            guard error != nil else { return }
            Haptics.shared.play(.pairingFailed)
            code = ""
            submittedCode = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if utilitySheet == nil { codeFocused = true }
            }
        }
        .confirmationDialog("断开并忘记这台 Mac？", isPresented: $showForget, titleVisibility: .visible) {
            Button("断开并忘记", role: .destructive) {
                Haptics.shared.play(.tap)
                link.forgetMac()
                dismiss()
            }
            Button("取消", role: .cancel) {
                Haptics.shared.play(.tap)
            }
        } message: {
            Text("下次连接需要重新输入配对码。")
        }
        .sheet(item: $utilitySheet) { sheet in
            switch sheet {
            case .waveforms:
                WaveformLibraryView()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PixelText(text: "SETTINGS", cell: 2.3, color: Theme.ivory, tracking: 1.6)
            Rectangle().fill(Theme.orange).frame(width: 4, height: 20)
            Spacer()
            Button {
                Haptics.shared.play(.tap)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch link.phase {
        case .ready(let name):
            connected(name: name)
        case .needsCode(let name):
            codeEntry(name: name)
        case .connecting(let name):
            linking(name: name)
        case .failed(let message):
            failure(message)
        case .searching, .idle:
            discovery
        }
    }

    private func connected(name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前连接设备")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                Spacer()
                HUDLabel(text: "LINK / ENCRYPTED")
            }
            HStack(spacing: 12) {
                Rectangle().fill(Theme.orange).frame(width: 4, height: 4)
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ivory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    Haptics.shared.play(.warning)
                    showForget = true
                } label: {
                    Text("忘记")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private func codeEntry(name: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配对到 \(name)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.orange)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("在 Mac 的 iMic 窗口里找到 6 位配对码。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            ZStack {
                HStack(spacing: 7) {
                    ForEach(0..<6, id: \.self) { index in
                        let characters = Array(code)
                        let value = index < characters.count ? String(characters[index]) : ""
                        Text(value)
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.ivory)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Theme.panel)
                            .overlay(
                                Rectangle().stroke(
                                    index == characters.count ? Theme.orange : Theme.line,
                                    lineWidth: index == characters.count ? 1.5 : 1
                                )
                            )
                    }
                }
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .opacity(0.02)
                    .accessibilityLabel("六位配对码")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.shared.play(.selection)
                codeFocused = true
            }

            if let error = link.pairingError {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.orange)
            } else if link.pairing {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.orange).scaleEffect(0.7)
                    MetaLabel(text: "VERIFYING", color: Theme.muted)
                }
            } else {
                MetaLabel(text: "输入满 6 位后自动连接", color: Theme.muted)
            }

            HStack(spacing: 8) {
                Rectangle().fill(Theme.orange.opacity(0.5)).frame(width: 3, height: 3)
                Text("配对码每 10 分钟轮换。配对成功后，iMic 自动记住这台 Mac。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func linking(name: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.orange).scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 4) {
                Text("正在连接 \(name)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ivory)
                    .lineLimit(2)
                    .truncationMode(.middle)
                MetaLabel(text: "BONJOUR · CURVE25519", color: Theme.muted)
            }
        }
        .padding(.vertical, 20)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Haptics.shared.play(.tap)
                link.retry()
            } label: {
                PixelText(text: "RETRY", cell: 2.4, color: Theme.ink, tracking: 2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.orange)
            }
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MetaLabel(text: "NEARBY MACS", color: Theme.orange)
                Spacer()
                if link.macs.isEmpty {
                    MetaLabel(text: "SEARCHING", color: Theme.muted)
                } else {
                    MetaLabel(text: "\(link.macs.count) FOUND", color: Theme.muted)
                }
            }
            if link.macs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.orange).scaleEffect(0.7)
                    Text("确保 iPhone 与 Mac 在同一 Wi-Fi，且已允许「本地网络」。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                Button {
                    Haptics.shared.play(.tap)
                    link.retry()
                } label: {
                    Text("重新搜索")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.orange)
                }
            } else {
                ForEach(link.macs) { mac in
                    Button {
                        Haptics.shared.play(.selection)
                        link.connect(to: mac)
                    } label: {
                        HStack(spacing: 10) {
                            Rectangle().fill(Theme.orange).frame(width: 4, height: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.ivory)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                MetaLabel(text: link.pairedMacIDs.contains(mac.id) ? "已配对" : "需要配对", color: Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.orange)
                        }
                        .padding(12)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                }
                Text("点击 Mac 后，按窗口里的配对码确认。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                codeFocused = false
                utilitySheet = .waveforms
            } label: {
                HStack {
                    Text("波形复看").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ivory)
                    Spacer()
                    MetaLabel(text: "LOCAL · 24H", color: Theme.muted)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            Hairline()
            HStack {
                MetaLabel(text: "SAME WI-FI · LOCAL NETWORK")
                Spacer()
                Button {
                    Haptics.shared.play(.tap)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("系统权限")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}
