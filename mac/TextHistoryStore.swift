import Foundation

/// One finished (or interrupted) utterance. Stored only on this Mac.
struct TextHistoryEntry: Codable, Equatable {
    enum Outcome: String, Codable {
        /// Delivered into the target app.
        case typed
        /// Recognized but not typed (automatic input off, focus changed, no permission).
        case kept
        /// Session interrupted; whatever text was already recognized.
        case failed
    }

    struct Polish: Codable, Equatable {
        var mode: String
        var tone: String
        var output: String
        /// Polish did not finish; `final` is the original (or the safe command fallback).
        var fallback: Bool
    }

    var id: UUID
    var date: Date
    var appName: String?
    var bundleID: String?
    /// Raw cloud recognition before any polish/conversion.
    var original: String
    /// Text delivered (or that would have been delivered).
    var final: String
    /// nil: recognition only, polish was off.
    var polish: Polish?
    var outcome: Outcome

    init(id: UUID = UUID(), date: Date = Date(), appName: String?, bundleID: String?,
         original: String, final: String, polish: Polish?, outcome: Outcome) {
        self.id = id; self.date = date; self.appName = appName; self.bundleID = bundleID
        self.original = original; self.final = final; self.polish = polish; self.outcome = outcome
    }

    var hasDistinctOriginal: Bool { !original.isEmpty && original != final }
}

/// Append-only JSON Lines file in the app's support directory (0700 / 0600).
/// No network, no iCloud, no size cap: the purpose is recovering lost text.
/// A damaged line is skipped instead of discarding the rest of the history.
final class TextHistoryStore {
    static let didChange = Notification.Name("VoxChordTextHistoryDidChange")

    let fileURL: URL
    private let directory: URL
    private var cache: [TextHistoryEntry]?

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("history.jsonl")
    }

    /// ISO 8601 with milliseconds: readable in the file, and ordering survives a relaunch.
    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        let formatter = dateFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = dateFormatter()
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = formatter.date(from: text) ?? plain.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
        return decoder
    }()

    /// Newest first.
    func entries() -> [TextHistoryEntry] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    @discardableResult
    func append(_ entry: TextHistoryEntry) -> Bool {
        guard !entry.original.isEmpty || !entry.final.isEmpty,
              var line = try? Self.encoder.encode(entry) else { return false }
        line.append(0x0A)
        do {
            try prepareDirectory()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return false }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            IMicLog.write("mac.history", "append failed error=\(String(describing: error))")
            return false
        }
        if cache != nil { cache?.insert(entry, at: 0) }
        notify()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        // Re-read the file: never rewrite from a cache that may miss newer appends.
        let current = load()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        return rewrite(remaining)
    }

    @discardableResult
    func clear() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            IMicLog.write("mac.history", "clear failed error=\(String(describing: error))")
            return false
        }
        cache = []
        notify()
        return true
    }

    private func rewrite(_ newestFirst: [TextHistoryEntry]) -> Bool {
        var data = Data()
        for entry in newestFirst.reversed() {
            guard let line = try? Self.encoder.encode(entry) else { continue }
            data.append(line); data.append(0x0A)
        }
        do {
            try prepareDirectory()
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            IMicLog.write("mac.history", "rewrite failed error=\(String(describing: error))")
            return false
        }
        cache = newestFirst
        notify()
        return true
    }

    private func load() -> [TextHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var result: [TextHistoryEntry] = []
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? Self.decoder.decode(TextHistoryEntry.self, from: Data(line)) {
                result.append(entry)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { IMicLog.write("mac.history", "skipped damaged lines=\(skipped)") }
        return result.reversed()
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func notify() {
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

enum TextHistorySearch {
    /// Every whitespace-separated term must appear in the original, final text or app name.
    /// Case-, diacritic- and width-insensitive, so「ＡＢＣ」matches "abc".
    static func filter(_ entries: [TextHistoryEntry], query: String) -> [TextHistoryEntry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return entries.filter { entry in
            let haystack = [entry.final, entry.original, entry.appName ?? ""].joined(separator: "\n")
            return terms.allSatisfy { haystack.range(of: $0, options: options) != nil }
        }
    }
}
