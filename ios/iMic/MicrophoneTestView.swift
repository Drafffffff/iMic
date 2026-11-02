import SwiftUI
import UIKit

@MainActor
final class MicrophoneTestModel: ObservableObject {
    @Published var diagnostics = CaptureDiagnostics()
    @Published var message: String?
    @Published var copied = false
    @Published var rebuilding = false
    @Published var starting = false
    @Published var processing = MicrophoneTestProcessing()
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
        capture.start(rebuildFirst: rebuildFirst, voiceProcessingOverride: processing.enabled, microphoneTest: true, onChunk: { _ in }, onFailure: { [weak self] message in
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

    func toggleProcessing(capture: AudioCapture) async {
        processing.toggle()
        await start(capture: capture)
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
        UIPasteboard.general.string = diagnostics.report + "\nrequestedVPIO=\(processing.enabled ? "on" : "off")\nstatus=\(message ?? "ok")"
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
                    processingPanel
                    Hairline()
                    inputDetails
                    testActions
                }
                .padding(24)
            }
            .accessibilityIdentifier("microphone-test-scroll")
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
                .accessibilityIdentifier("close-mic-test")
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
            Text(levelStatus).font(.callout).foregroundStyle(Theme.ivory)
                .accessibilityIdentifier("mic-test-level-state")
            Text(String(format: "RMS %.5f   PEAK %.5f", model.diagnostics.meter.rms, model.diagnostics.meter.peak))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }

    private var processingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 32) {
                detail("VPIO", model.diagnostics.voiceProcessing ? L10n.text("On") : L10n.text("Off"))
                detail("MODE", model.diagnostics.mode.replacingOccurrences(of: "AVAudioSessionMode", with: ""))
            }
            Button(model.processing.enabled ? L10n.text("Test without VPIO") : L10n.text("Test with VPIO")) {
                active = true
                Task { await model.toggleProcessing(capture: session.microphoneTestCapture()) }
            }
            .foregroundStyle(Theme.orange).frame(minHeight: 44)
            .disabled(model.starting || model.rebuilding)
            .accessibilityIdentifier("mic-test-vpio-toggle")
            .accessibilityValue(model.processing.enabled ? "on" : "off")
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(Theme.orange)
                    .accessibilityIdentifier("mic-test-message")
            }
            Text(L10n.text("Temporary comparison only. Your saved voice processing setting is unchanged."))
                .font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var levelStatus: String {
        switch model.diagnostics.level {
        case .normal: return L10n.text("Normal input level")
        case .lowLevel: return L10n.text("Almost silent")
        case .allZero: return L10n.text("All zero")
        case .unavailable: return L10n.text("Waiting for input")
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

    private var recoveryStatus: String {
        switch model.diagnostics.recoveryResult {
        case .none: return L10n.text("Not attempted")
        case .rebuilding: return L10n.text("Rebuilding audio route…")
        case .awaitingSignal: return L10n.text("Route rebuilt. Speak to check the level.")
        case .lowLevel: return L10n.text("Almost silent")
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
