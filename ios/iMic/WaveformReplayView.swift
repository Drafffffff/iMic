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
                    Text("只保留波形，不保存录音或识别文字。最近 3 次，每次最多 60 秒，24 小时后自动清理。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    if let error = store.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.orange)
                        Button("重新读取") { store.reload() }.tint(Theme.orange)
                    }
                    if store.isLoading && store.traces.isEmpty {
                        ProgressView().tint(Theme.orange).frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else if store.traces.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            MetaLabel(text: "NO WAVEFORMS")
                            Text("还没有可复看的波形。按住主页面横条说话，正常松手后会自动保留；取消的录音不会保存。")
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
                                        MetaLabel(text: String(format: "%.2f S · %d FRAMES", trace.duration, trace.frames.count))
                                        MetaLabel(text: String(format: "RMS AVG %.1f dBFS", trace.meanDB))
                                        MetaLabel(text: String(format: "MIN %.1f · MAX %.1f dBFS", trace.minimumDB, trace.maximumDB))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                HStack {
                                    ShareLink(item: store.fileURL(for: trace)) {
                                        Label("导出 JSON", systemImage: "square.and.arrow.up")
                                    }
                                    Spacer()
                                    Button("删除", role: .destructive) { store.delete(trace) }
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
            .navigationTitle("波形复看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.tint(Theme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除", role: .destructive) { showClear = true }
                        .tint(Theme.orange).disabled(store.traces.isEmpty)
                }
            }
            .confirmationDialog("清除所有本地波形？", isPresented: $showClear, titleVisibility: .visible) {
                Button("清除波形", role: .destructive) { store.clear() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("仅删除可视化缓存，不影响连接或识别结果。")
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
                    MetaLabel(text: String(format: "%.2f / %.2f S", playback.elapsed, trace.duration), color: Theme.ivory)
                    Spacer()
                    MetaLabel(text: String(format: "RMS %.1f dBFS", playback.rmsDB), color: Theme.orange)
                }
                ProgressView(value: min(playback.elapsed, trace.duration), total: max(0.001, trace.duration))
                    .tint(Theme.orange)
                    .accessibilityLabel("复看进度")
                HStack(spacing: 16) {
                    Button {
                        if playback.isPlaying { playback.pause() } else { playback.play() }
                    } label: {
                        Label(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .foregroundStyle(Theme.ink).background(Theme.orange)
                    }
                    .buttonStyle(.plain)
                    Button { playback.replay() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 48, height: 48)
                            .overlay(Rectangle().stroke(Theme.line))
                    }
                    .accessibilityLabel("从头重播")
                    .tint(Theme.ivory)
                }
                Toggle("循环复看", isOn: $playback.loops)
                    .font(.system(size: 13)).tint(Theme.orange).foregroundStyle(Theme.muted)
                Hairline()
                MetaLabel(text: String(format: "RMS AVG %.1f dBFS", trace.meanDB))
                MetaLabel(text: String(format: "MIN %.1f · MAX %.1f dBFS", trace.minimumDB, trace.maximumDB))
                Text("按原始采样间隔驱动同一主图。RMS 为原始数字响度（dBFS），不是校准声压；复看不会播放声音、联网、输入文字或启动麦克风。")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("导出波形 JSON", systemImage: "square.and.arrow.up")
                    }
                    .font(.system(size: 13)).tint(Theme.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.ink)
        .navigationTitle("波形复看")
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
                            Text(loadError ?? store.errorMessage ?? "没有波形缓存。先完成一次真实录音，或指定导出的 JSON 文件路径。")
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
                catch { loadError = "无法读取波形 JSON：\(error.localizedDescription)" }
            }
            loading = false
        }
    }
}
#endif
