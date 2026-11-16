import SwiftUI

struct WaveformLibraryView: View {
    @ObservedObject private var store = WaveformTraceStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MetaLabel(text: "LOCAL VISUALIZATION · NO AUDIO", color: Theme.orange)
                    Text(L10n.text("Only waveforms are kept, without audio or recognized text. The last 3 sessions, up to 60 seconds each, are automatically cleared after 24 hours."))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    if let error = store.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.orange)
                        Button(L10n.text("Reload")) { store.reload() }.tint(Theme.orange)
                    }
                    if store.isLoading && store.traces.isEmpty {
                        ProgressView().tint(Theme.orange).frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else if store.traces.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            MetaLabel(text: "NO WAVEFORMS")
                            Text(L10n.text("No waveforms yet. Hold the bar on the home screen to speak and release normally to keep a waveform. Canceled recordings are not saved."))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.ivory)
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(store.traces) { trace in
                            VStack(alignment: .leading, spacing: 10) {
                                Hairline()
                                NavigationLink {
                                    WaveformReplayView(trace: trace, exportURL: store.fileURL(for: trace))
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            MetaLabel(text: trace.source.label, color: trace.source == .microphone ? Theme.orange : Theme.muted)
                                            Spacer()
                                            Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(Theme.orange)
                                        }
                                        Text(trace.source.explanation)
                                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ivory)
                                        Text(trace.createdAt.formatted(date: .abbreviated, time: .standard))
                                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                        MetaLabel(text: String(format: "%.2f S · %d FRAMES", locale: L10n.locale, trace.duration, trace.frames.count))
                                        MetaLabel(text: String(format: "RMS AVG %.1f dBFS", locale: L10n.locale, trace.meanDB))
                                        MetaLabel(text: String(format: "MIN %.1f · MAX %.1f dBFS", locale: L10n.locale, trace.minimumDB, trace.maximumDB))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                HStack {
                                    ShareLink(item: store.fileURL(for: trace)) {
                                        Label(L10n.text("Export JSON"), systemImage: "square.and.arrow.up")
                                    }
                                    Spacer()
                                    Button(L10n.text("Delete"), role: .destructive) { store.delete(trace) }
                                }
                                .font(.system(size: 12)).tint(Theme.muted)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(22)
            }
            .background(Theme.ink)
            .navigationTitle(L10n.text("Waveform replay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("Close")) { dismiss() }.tint(Theme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("Clear##bce23772"), role: .destructive) { showClear = true }
                        .tint(Theme.orange).disabled(store.traces.isEmpty)
                }
            }
            .confirmationDialog(L10n.text("Clear all local waveforms?"), isPresented: $showClear, titleVisibility: .visible) {
                Button(L10n.text("Clear waveforms"), role: .destructive) { store.clear() }
                Button(L10n.text("Cancel"), role: .cancel) { }
            } message: {
                Text(L10n.text("Deletes only the visualization cache. Connections and recognition results are unaffected."))
            }
            .task { store.reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.reload() }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct WaveformReplayView: View {
    let trace: WaveformTrace
    let exportURL: URL?
    @StateObject private var playback: WaveformPlayback
    @Environment(\.scenePhase) private var scenePhase

    init(trace: WaveformTrace, exportURL: URL? = nil) {
        self.trace = trace
        self.exportURL = exportURL
        _playback = StateObject(wrappedValue: WaveformPlayback(trace: trace))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    MetaLabel(text: trace.source.label, color: Theme.orange)
                    Spacer()
                    MetaLabel(text: "VISUAL ONLY")
                }
                Text(trace.source.explanation)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ivory)
                Text(trace.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                TorusView(store: playback.spectrum)
                    .frame(height: 270)
                    .frame(maxWidth: .infinity)
                HStack {
                    MetaLabel(text: String(format: "%.2f / %.2f S", locale: L10n.locale, playback.elapsed, trace.duration), color: Theme.ivory)
                    Spacer()
                    MetaLabel(text: String(format: "RMS %.1f dBFS", locale: L10n.locale, playback.rmsDB), color: Theme.orange)
                }
                ProgressView(value: min(playback.elapsed, trace.duration), total: max(0.001, trace.duration))
                    .tint(Theme.orange)
                    .accessibilityLabel(L10n.text("Replay progress"))
                HStack(spacing: 16) {
                    Button {
                        if playback.isPlaying { playback.pause() } else { playback.play() }
                    } label: {
                        Label(playback.isPlaying ? L10n.text("Pause") : L10n.text("Play"), systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .foregroundStyle(Theme.ink).background(Theme.orange)
                    }
                    .buttonStyle(.plain)
                    Button { playback.replay() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 48, height: 48)
                            .overlay(Rectangle().stroke(Theme.line))
                    }
                    .accessibilityLabel(L10n.text("Replay from start"))
                    .tint(Theme.ivory)
                }
                Toggle(L10n.text("Loop replay"), isOn: $playback.loops)
                    .font(.system(size: 13)).tint(Theme.orange).foregroundStyle(Theme.muted)
                Hairline()
                MetaLabel(text: String(format: "RMS AVG %.1f dBFS", locale: L10n.locale, trace.meanDB))
                MetaLabel(text: String(format: "MIN %.1f · MAX %.1f dBFS", locale: L10n.locale, trace.minimumDB, trace.maximumDB))
                Text(L10n.text("Uses the original sample intervals to drive the same display. RMS is raw digital loudness (dBFS), not calibrated sound pressure. Replay does not play sound, connect to the network, type text, or start the microphone."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(L10n.text("Export waveform JSON"), systemImage: "square.and.arrow.up")
                    }
                    .font(.system(size: 13)).tint(Theme.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.ink)
        .navigationTitle(L10n.text("Waveform replay"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { playback.play() }
        .onDisappear { playback.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
    }
}

@MainActor
private final class WaveformPlayback: ObservableObject {
    let spectrum = SpectrumStore()
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var rmsDB: Double = -160
    @Published private(set) var isPlaying = false
    @Published var loops = false
    private let trace: WaveformTrace
    private var task: Task<Void, Never>?
    private var nextFrame = 0
    private var generation = UUID()
    private var startedAt: Double = 0
    private var startedOffset: Double = 0

    init(trace: WaveformTrace) {
        self.trace = trace
        if let first = trace.frames.first { rmsDB = first.rmsDB }
    }

    deinit { task?.cancel() }

    func play() {
        guard !isPlaying, !trace.frames.isEmpty else { return }
        if elapsed >= trace.duration { reset() }
        isPlaying = true
        generation = UUID()
        let current = generation
        startedAt = ProcessInfo.processInfo.systemUptime
        startedOffset = elapsed
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                let target = self.nextFrame < self.trace.frames.count
                    ? self.trace.frames[self.nextFrame].time : self.trace.duration
                let position = self.startedOffset + ProcessInfo.processInfo.systemUptime - self.startedAt
                let delay = max(0, target - position)
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled, self.generation == current else { return }
                self.elapsed = target
                if self.nextFrame < self.trace.frames.count {
                    let frame = self.trace.frames[self.nextFrame]
                    self.spectrum.update(frame.bands.map { CGFloat($0) }, level: CGFloat(frame.level))
                    self.rmsDB = frame.rmsDB
                    self.nextFrame += 1
                } else if self.loops {
                    self.reset()
                    self.startedAt = ProcessInfo.processInfo.systemUptime
                    self.startedOffset = 0
                } else {
                    self.isPlaying = false
                    self.task = nil
                    return
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        elapsed = min(trace.duration, startedOffset + ProcessInfo.processInfo.systemUptime - startedAt)
        isPlaying = false
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func replay() {
        pause()
        reset()
        play()
    }

    private func reset() {
        elapsed = 0
        nextFrame = 0
        spectrum.reset()
    }
}

#if DEBUG
struct WaveformDebugReplayRoot: View {
    let selection: String
    @ObservedObject private var store = WaveformTraceStore.shared
    @State private var imported: WaveformTrace?
    @State private var loadError: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let trace = imported ?? (selection == "latest" ? store.traces.first : nil) {
                    WaveformReplayView(trace: trace, exportURL: selection == "latest" ? store.fileURL(for: trace) : URL(fileURLWithPath: selection))
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        MetaLabel(text: "WAVEFORM REPLAY", color: Theme.orange)
                        if loading || (selection == "latest" && store.isLoading) {
                            ProgressView().tint(Theme.orange)
                        } else {
                            Text(loadError ?? store.errorMessage ?? L10n.text("No waveform cache. Complete a real recording first, or provide the path to an exported JSON file."))
                                .font(.system(size: 14)).foregroundStyle(Theme.ivory)
                        }
                    }
                    .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Theme.ink)
        }
        .preferredColorScheme(.dark)
        .task {
            if selection == "latest" {
                store.reload()
            } else {
                do { imported = try await WaveformTraceStore.readDebugTrace(at: URL(fileURLWithPath: selection)) }
                catch { loadError = L10n.text("Cannot read waveform JSON: %@", L10n.argument(error.localizedDescription)) }
            }
            loading = false
        }
    }
}
#endif
