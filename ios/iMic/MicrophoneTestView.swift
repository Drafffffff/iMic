import SwiftUI
import UIKit

@MainActor
final class MicrophoneTestModel: ObservableObject {
    @Published var diagnostics = CaptureDiagnostics()
    @Published var message: String?
    @Published var copied = false
    private var capture: AudioCapture?
    private var generation = 0

    func start(capture: AudioCapture) async {
        stop()
        self.capture = capture
        message = nil
        copied = false
        diagnostics = CaptureDiagnostics(event: "starting")
        generation += 1
        let token = generation
        guard await AudioCapture.requestPermission(), generation == token else {
            if generation == token { message = L10n.text("Microphone access is off") }
            return
        }
        capture.start(onChunk: { _ in }, onFailure: { [weak self] message in
            self?.message = message
        }, onDiagnostics: { [weak self] diagnostics in
            self?.diagnostics = diagnostics
        }, completion: { [weak self] error in
            if error != nil { self?.message = L10n.text("Microphone failed to start") }
        })
        capture.setMonitoring(true)
    }

    func stop() {
        generation += 1
        capture?.stop()
        capture = nil
        diagnostics.running = false
    }

    func copy() {
        UIPasteboard.general.string = diagnostics.report + "\nstatus=\(message ?? "ok")"
        copied = true
    }
}

struct MicrophoneTestView: View {
    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MicrophoneTestModel()
    @State private var active = true

    private var level: Double {
        guard model.diagnostics.meter.rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(model.diagnostics.meter.rms) + 60) / 60))
    }

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Hairline()
                    Text(L10n.text("Speak normally and watch the level. Audio stays on this device and is not saved or sent."))
                        .font(.body).foregroundStyle(Theme.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                    meterPanel
                    Hairline()
                    inputDetails
                    testActions
                }
                .padding(24)
            }
        }
        .presentationDetents([.large])
        .task { await model.start(capture: session.microphoneTestCapture()) }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.stop(); active = false
        }
    }

    private var header: some View {
        HStack {
            PixelText(text: "MIC TEST", cell: 2.5, color: Theme.ivory, tracking: 1.6)
                .accessibilityElement(children: .ignore).accessibilityLabel("MIC TEST")
            Spacer()
            Button(L10n.text("Close")) { dismiss() }
                .foregroundStyle(Theme.muted).frame(minWidth: 44, minHeight: 44)
        }
    }

    private var meterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDLabel(text: "INPUT LEVEL")
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { index in
                    Rectangle().fill(Double(index) / 24 < level ? Theme.orange : Theme.line)
                        .frame(height: 40)
                }
            }
            .accessibilityLabel(L10n.text("Microphone level"))
            .accessibilityValue(String(format: "%.0f%%", level * 100))
            Text(String(format: "RMS %.5f   PEAK %.5f", model.diagnostics.meter.rms, model.diagnostics.meter.peak))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }

    private var inputDetails: some View {
        VStack(alignment: .leading, spacing: 24) {
            detail("INPUT", model.diagnostics.input.isEmpty ? "—" : model.diagnostics.input)
            detail("SAMPLE RATE", String(format: "%.0f Hz", model.diagnostics.sampleRate))
            detail("ENGINE", model.diagnostics.running ? "RUNNING" : "STOPPED")
            detail("CALLBACKS / 0.5s", String(model.diagnostics.meter.callbacks))
        }
    }

    private var testActions: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(Theme.orange)
                    .accessibilityIdentifier("mic-test-message")
            }
            Text(L10n.text("If the level stays empty, close this test and hold to record again. If it still fails, copy diagnostics and share them with the log."))
                .font(.callout).foregroundStyle(Theme.muted)
            Hairline()
            Button(model.copied ? L10n.text("Copied") : L10n.text("Copy diagnostics")) { model.copy() }
                .foregroundStyle(Theme.orange).frame(minHeight: 44)
                .accessibilityIdentifier("copy-mic-diagnostics")
            if !active {
                Button(L10n.text("Start microphone test")) {
                    active = true
                    Task { await model.start(capture: session.microphoneTestCapture()) }
                }.foregroundStyle(Theme.orange).frame(minHeight: 44)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HUDLabel(text: title)
            Text(value).font(.body).foregroundStyle(Theme.ivory)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
