import Combine
import Foundation
import CoreGraphics

/// Visualization only: never contains PCM, recognized text or a network identifier.
struct WaveformTrace: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case microphone
        case synthetic

        var label: String { self == .microphone ? "MICROPHONE" : "SYNTHETIC" }
        var explanation: String { self == .microphone ? "真实麦克风" : "合成测试 · 非真实录音" }
    }

    struct Frame: Codable, Sendable {
        let time: Double
        let bands: [Double]
        let level: Double
        let rmsDB: Double
    }

    let version: Int
    let id: UUID
    let source: Source
    let createdAt: Date
    let duration: Double
    let frames: [Frame]

    var minimumDB: Double { frames.reduce(frames.first?.rmsDB ?? -160) { min($0, $1.rmsDB) } }
    var maximumDB: Double { frames.reduce(frames.first?.rmsDB ?? -160) { max($0, $1.rmsDB) } }
    var meanDB: Double {
        guard !frames.isEmpty else { return -160 }
        // Average in the power domain, not by averaging decibel values.
        let power = frames.reduce(0.0) { $0 + pow(10, $1.rmsDB / 10) } / Double(frames.count)
        return power > 0 ? 10 * log10(power) : -.infinity
    }

    var isValid: Bool {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite,
              duration.isFinite, duration >= 0, duration <= 60,
              !frames.isEmpty, frames.count <= 3_000 else { return false }
        var previous = -Double.infinity
        for frame in frames {
            guard frame.time.isFinite, frame.time >= 0, frame.time <= duration,
                  frame.time > previous,
                  previous < 0 || frame.time - previous >= 0.019_999,
                  frame.bands.count == 44,
                  frame.bands.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  frame.level.isFinite, (0...1).contains(frame.level),
                  frame.rmsDB == -.infinity || (frame.rmsDB.isFinite && (-200...20).contains(frame.rmsDB)) else { return false }
            previous = frame.time
        }
        return true
    }
}

@MainActor
final class WaveformTraceStore: ObservableObject {
    static let shared = WaveformTraceStore()
    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iMicWaveforms", isDirectory: true)

    @Published private(set) var traces: [WaveformTrace] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = true

    private struct Recording {
        let id = UUID()
        let source: WaveformTrace.Source
        let date = Date()
        let start = ProcessInfo.processInfo.systemUptime
        var frames: [WaveformTrace.Frame] = []
    }

    private var recording: Recording?
    private var epoch: UInt64 = 0
    private var snapshotRevision: UInt64 = 0
    private let files = WaveformTraceFiles(directory: cacheDirectory)

    init() { reload() }

    func begin(source: WaveformTrace.Source) {
        recording = Recording(source: source)
        recording?.frames.reserveCapacity(3_000)
    }

    func append(bands: [CGFloat], level: CGFloat, rmsDB: Double) {
        guard let start = recording?.start, (recording?.frames.count ?? 3_000) < 3_000,
              bands.count == 44, bands.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              level.isFinite, (0...1).contains(level),
              rmsDB == -.infinity || (rmsDB.isFinite && (-200...20).contains(rmsDB)) else { return }
        let time = ProcessInfo.processInfo.systemUptime - start
        guard time >= 0, time <= 60 else { return }
        if let lastTime = recording?.frames.last?.time, time - lastTime < 0.02 { return }
        recording?.frames.append(.init(time: time, bands: bands.map(Double.init), level: Double(level), rmsDB: rmsDB))
    }

    func finish() {
        guard let active = recording else { return }
        recording = nil
        guard !active.frames.isEmpty else { return }
        let trace = WaveformTrace(
            version: 1, id: active.id, source: active.source, createdAt: active.date,
            duration: min(60, max(active.frames.last?.time ?? 0, ProcessInfo.processInfo.systemUptime - active.start)),
            frames: active.frames
        )
        let currentEpoch = epoch
        Task {
            do { apply(try await files.save(trace, epoch: currentEpoch), epoch: currentEpoch) }
            catch { report(error, epoch: currentEpoch) }
        }
    }

    func cancel() { recording = nil }

    func reload() {
        let currentEpoch = epoch
        isLoading = true
        Task {
            do { apply(try await files.reload(epoch: currentEpoch), epoch: currentEpoch) }
            catch { report(error, epoch: currentEpoch) }
        }
    }

    func delete(_ trace: WaveformTrace) {
        let currentEpoch = epoch
        traces.removeAll { $0.id == trace.id }
        Task {
            do { apply(try await files.delete(trace.id, epoch: currentEpoch), epoch: currentEpoch) }
            catch { report(error, epoch: currentEpoch) }
        }
    }

    func clear() {
        epoch &+= 1
        let currentEpoch = epoch
        recording = nil
        traces = []
        Task {
            do { apply(try await files.clear(epoch: currentEpoch), epoch: currentEpoch) }
            catch { report(error, epoch: currentEpoch) }
        }
    }

    func fileURL(for trace: WaveformTrace) -> URL {
        Self.cacheDirectory.appendingPathComponent(trace.id.uuidString).appendingPathExtension("json")
    }

    private func apply(_ snapshot: WaveformTraceFiles.Snapshot, epoch: UInt64) {
        guard epoch == self.epoch, snapshot.revision >= snapshotRevision else { return }
        snapshotRevision = snapshot.revision
        traces = snapshot.traces
        isLoading = false
        errorMessage = nil
    }

    private func report(_ error: Error, epoch: UInt64) {
        guard epoch == self.epoch else { return }
        isLoading = false
        errorMessage = "波形缓存无法读写：\(error.localizedDescription)"
    }
}

/// File IO and JSON encoding stay off the main actor. Each recording has its own UUID;
/// epochs and tombstones prevent a delayed save from resurrecting cleared/deleted data.
private actor WaveformTraceFiles {
    struct Snapshot: Sendable {
        let revision: UInt64
        let traces: [WaveformTrace]
    }

    private let directory: URL
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var deleted: Set<UUID> = []
    private let manager = FileManager.default

    init(directory: URL) { self.directory = directory }

    func reload(epoch: UInt64) throws -> Snapshot {
        guard try accept(epoch: epoch) else { return .init(revision: revision, traces: []) }
        return try snapshot()
    }

    func save(_ trace: WaveformTrace, epoch: UInt64) throws -> Snapshot {
        guard try accept(epoch: epoch) else { return .init(revision: revision, traces: []) }
        guard !deleted.contains(trace.id), trace.isValid else { return try snapshot() }
        try prepareDirectory()
        let encoder = JSONEncoder()
        // Digital zero is truly -∞ dBFS, not an invented noise-floor sample.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = try encoder.encode(trace)
        let url = directory.appendingPathComponent(trace.id.uuidString).appendingPathExtension("json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try snapshot()
    }

    func delete(_ id: UUID, epoch: UInt64) throws -> Snapshot {
        guard try accept(epoch: epoch) else { return .init(revision: revision, traces: []) }
        deleted.insert(id)
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        return try snapshot()
    }

    func clear(epoch: UInt64) throws -> Snapshot {
        guard try accept(epoch: epoch) else { return .init(revision: revision, traces: []) }
        return try snapshot()
    }

    private func accept(epoch: UInt64) throws -> Bool {
        guard epoch >= self.epoch else { return false }
        if epoch > self.epoch {
            // The first operation in a new epoch performs the clear. A delayed
            // clear request cannot then delete a new recording in that epoch.
            if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
            deleted.removeAll()
            self.epoch = epoch
        }
        return true
    }

    private func prepareDirectory() throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func snapshot() throws -> Snapshot {
        try prepareDirectory()
        let urls = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        let now = Date()
        var records: [WaveformTrace] = []
        for url in urls where url.pathExtension == "json" {
            let trace: WaveformTrace
            do {
                trace = try Self.read(url)
            } catch is DecodingError {
                try manager.removeItem(at: url)
                continue
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {
                try manager.removeItem(at: url)
                continue
            }
            guard url.deletingPathExtension().lastPathComponent == trace.id.uuidString,
                  !deleted.contains(trace.id), now.timeIntervalSince(trace.createdAt) < 86_400,
                  now.timeIntervalSince(trace.createdAt) >= -60 else {
                try manager.removeItem(at: url)
                continue
            }
            records.append(trace)
        }
        records.sort { $0.createdAt > $1.createdAt }
        for trace in records.dropFirst(3) {
            try manager.removeItem(at: directory.appendingPathComponent(trace.id.uuidString).appendingPathExtension("json"))
        }
        revision &+= 1
        return .init(revision: revision, traces: Array(records.prefix(3)))
    }

    static func read(_ url: URL) throws -> WaveformTrace {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let bytes = resource.fileSize, bytes > 0, bytes <= 12_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let trace = try decoder.decode(WaveformTrace.self, from: Data(contentsOf: url))
        guard trace.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return trace
    }
}

#if DEBUG
extension WaveformTraceStore {
    static func readDebugTrace(at url: URL) async throws -> WaveformTrace {
        try await Task.detached(priority: .userInitiated) { try WaveformTraceFiles.read(url) }.value
    }
}
#endif
