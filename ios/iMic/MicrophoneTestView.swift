import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class MicrophoneTestModel: ObservableObject {
    @Published var diagnostics = CaptureDiagnostics()
    @Published var message: String?
    @Published var copied = false
    @Published var rebuilding = false
    @Published var starting = false
    private var capture: AudioCapture?
    private var generation = 0

    func start(capture: AudioCapture) async {
        stop()
        self.capture = capture
        starting = true
        message = nil
        copied = false
        diagnostics = CaptureDiagnostics(event: "starting")
        generation += 1
        let token = generation
        guard await AudioCapture.requestPermission(), generation == token else {
            if generation == token { message = L10n.text("Microphone access is off"); starting = false }
            return
        }
        beginCapture(capture, rebuildFirst: false)
    }

    private func beginCapture(_ capture: AudioCapture, rebuildFirst: Bool) {
        capture.start(rebuildFirst: rebuildFirst, onChunk: { _ in }, onFailure: { [weak self] message in
            self?.message = message
            self?.starting = false
        }, onDiagnostics: { [weak self] diagnostics in
            self?.diagnostics = diagnostics
            self?.rebuilding = diagnostics.recoveryResult == .rebuilding
            if diagnostics.recoveryResult == .rebuilding { self?.message = nil }
        }, completion: { [weak self] error in
            self?.starting = false
            if let error { self?.message = error is CaptureRouteError ? error.localizedDescription : L10n.text("Microphone failed to start") }
        })
        capture.setMonitoring(true)
    }

    var canRebuild: Bool { capture != nil && AudioCapture.permissionGranted && !starting && !rebuilding }

    func rebuild() {
        guard canRebuild, let capture else { return }
        if diagnostics.attempt > 0 {
            // A deliberate second button press starts a NEW test. Within that
            // test playback rebuilding consumes the only automatic retry too.
            stop()
            self.capture = capture
            starting = true
            rebuilding = true
            copied = false
            message = nil
            diagnostics = CaptureDiagnostics(event: "starting-manual-test")
            beginCapture(capture, rebuildFirst: true)
            return
        }
        rebuilding = true
        copied = false
        let token = generation
        capture.rebuildRouteForMicrophoneTest { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.rebuilding = false
        }
    }

    func stop() {
        generation += 1
        capture?.stop()
        capture = nil
        diagnostics.running = false
        rebuilding = false
        starting = false
    }

    func copy() {
        UIPasteboard.general.string = diagnostics.report + "\n\(MicDebug.describe())\nstatus=\(message ?? "ok")"
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
                    micDebugPanel
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
            detail("INPUT ROUTE", model.diagnostics.inputRoute.inputs.isEmpty
                   ? L10n.text("No input route")
                   : model.diagnostics.inputRoute.inputs.map { "\($0.type) · \($0.name)" }.joined(separator: "\n"))
            detail("AVAILABLE INPUTS", model.diagnostics.inputRoute.available.map { ports in
                ports.isEmpty ? L10n.text("No available inputs") : ports.map { "\($0.type) · \($0.name)" }.joined(separator: "\n")
            } ?? L10n.text("Input list unavailable"))
            Text(L10n.text("Route details show the last active session check. Copy diagnostics to include port IDs."))
                .font(.caption).foregroundStyle(Theme.muted)
            detail("RECOVERY / \(model.diagnostics.attempt)", recoveryStatus)
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
            Button(L10n.text("Rebuild audio route")) { model.rebuild() }
                .foregroundStyle(model.canRebuild ? Theme.orange : Theme.muted)
                .disabled(!model.canRebuild).frame(minHeight: 44)
                .accessibilityIdentifier("rebuild-audio-route")
                .accessibilityValue(String(model.diagnostics.attempt))
            Text(L10n.text("One rebuild per test, shared with automatic recovery. Rebuilding again starts a new test."))
                .font(.caption).foregroundStyle(Theme.muted)
            Text(L10n.text("If the level stays empty, rebuild the audio route. If it still fails, try playing any audio, then return and start a new test."))
                .font(.callout).foregroundStyle(Theme.muted)
            Hairline()
            Button(model.copied ? L10n.text("Copied") : L10n.text("Copy diagnostics")) { model.copy() }
                .foregroundStyle(Theme.orange).frame(minHeight: 44)
                .accessibilityIdentifier("copy-mic-diagnostics")
            if !active || (model.diagnostics.attempt > 0 && !model.diagnostics.running) {
                Button(L10n.text("Start microphone test")) {
                    active = true
                    Task { await model.start(capture: session.microphoneTestCapture()) }
                }.foregroundStyle(Theme.orange).frame(minHeight: 44)
            }
        }
    }

    @State private var debugSources: [String] = []

    private func restartWith(mode: AVAudioSession.Mode? = nil, source: String?? = nil) {
        if let mode { MicDebug.mode = mode }
        if let source { MicDebug.dataSourceName = source }
        active = true
        Task {
            await model.start(capture: session.microphoneTestCapture())
            try? await Task.sleep(nanoseconds: 600_000_000)
            debugSources = MicDebug.builtInSources()
        }
    }

    private var micDebugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HUDLabel(text: "MODE")
            HStack(spacing: 16) {
                ForEach([AVAudioSession.Mode.measurement, .default, .voiceChat], id: \.rawValue) { mode in
                    Button(mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")) { restartWith(mode: mode) }
                        .foregroundStyle(MicDebug.mode == mode ? Theme.orange : Theme.muted)
                        .frame(minHeight: 44)
                }
            }
            HUDLabel(text: "VPIO")
            HStack(spacing: 16) {
                Button("Off") { MicDebug.voiceProcessing = false; restartWith() }
                    .foregroundStyle(MicDebug.voiceProcessing ? Theme.muted : Theme.orange).frame(minHeight: 44)
                Button("On") { MicDebug.voiceProcessing = true; restartWith() }
                    .foregroundStyle(MicDebug.voiceProcessing ? Theme.orange : Theme.muted).frame(minHeight: 44)
            }
            HUDLabel(text: "MIC")
            HStack(spacing: 16) {
                Button("Auto") { restartWith(source: .some(nil)) }
                    .foregroundStyle(MicDebug.dataSourceName == nil ? Theme.orange : Theme.muted)
                    .frame(minHeight: 44)
                ForEach(debugSources, id: \.self) { name in
                    Button(name) { restartWith(source: .some(name)) }
                        .foregroundStyle(MicDebug.dataSourceName == name ? Theme.orange : Theme.muted)
                        .frame(minHeight: 44)
                }
            }
            Text(MicDebug.describe()).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .task { try? await Task.sleep(nanoseconds: 800_000_000); debugSources = MicDebug.builtInSources() }
    }

    private var recoveryStatus: String {
        switch model.diagnostics.recoveryResult {
        case .none: return L10n.text("Not attempted")
        case .rebuilding: return L10n.text("Rebuilding audio route…")
        case .awaitingSignal: return L10n.text("Route rebuilt. Speak to check the level.")
        case .signalDetected: return L10n.text("Input signal detected")
        case .failed: return L10n.text("Audio route recovery failed")
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
