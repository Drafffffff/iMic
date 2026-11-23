import Foundation

/// 本地自定义词库：词条只保存在 Mac 上，识别时作为百炼即时热词发送，
/// 润色时作为专有名词表保护写法。规则与百炼热词限制保持一致，在本地先拦截。
public struct VocabularyEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var term: String
    /// 百炼普通热词权重 1…5，默认 4。超级热词（50）第一版不开放。
    public var weight: Int
    /// nil 表示所有模式；否则只在当前选择的润色模式属于其中时生效。
    public var modes: [PolishMode]?
    public var enabled: Bool

    public init(id: UUID = UUID(), term: String, weight: Int = Vocabulary.defaultWeight,
                modes: [PolishMode]? = nil, enabled: Bool = true) {
        self.id = id
        self.term = Vocabulary.normalize(term)
        self.weight = Vocabulary.clampWeight(weight)
        self.modes = modes.flatMap { $0.isEmpty ? nil : Vocabulary.ordered($0) }
        self.enabled = enabled
    }

    public func applies(to mode: PolishMode) -> Bool {
        enabled && (modes?.contains(mode) ?? true)
    }
}

public enum VocabularyIssue: Equatable, Sendable {
    case empty
    /// 换行、制表符等控制字符。
    case invalidCharacters
    /// 含非 ASCII 字符时超过 15 个字符。
    case tooLong
    /// 纯 ASCII 时按空格切分超过 7 段。
    case tooManyWords
    case duplicate
    case limit
}

public enum Vocabulary {
    public static let defaultWeight = 4
    public static let weights = 1...5
    /// 百炼 Qwen-Audio-ASR 每次请求最多 2000 个热词。
    public static let maxEnabled = 2000
    public static let maxNonASCIICharacters = 15
    public static let maxASCIIWords = 7

    public static func clampWeight(_ weight: Int) -> Int { min(weights.upperBound, max(weights.lowerBound, weight)) }

    /// 去掉首尾空白，内部连续空白合并为一个空格（不跨行，换行在校验中拒绝）。
    public static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"[ \u00A0\u3000]+"#, with: " ", options: .regularExpression)
    }

    /// 去重键：忽略大小写与全半角宽度差异。
    public static func key(_ term: String) -> String {
        normalize(term).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    public static func issue(for raw: String) -> VocabularyIssue? {
        let term = normalize(raw)
        if term.isEmpty { return .empty }
        if term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return .invalidCharacters
        }
        if term.unicodeScalars.allSatisfy(\.isASCII) {
            return term.split(separator: " ").count > maxASCIIWords ? .tooManyWords : nil
        }
        return term.count > maxNonASCIICharacters ? .tooLong : nil
    }

    /// 校验加入 entries 的新词条（编辑时传入被编辑条目的 id 以排除自身）。
    public static func issue(adding raw: String, to entries: [VocabularyEntry], replacing id: UUID? = nil, enabled: Bool = true) -> VocabularyIssue? {
        if let issue = issue(for: raw) { return issue }
        let key = key(raw)
        if entries.contains(where: { $0.id != id && Self.key($0.term) == key }) { return .duplicate }
        let others = entries.filter { $0.id != id && $0.enabled }.count
        if enabled, others >= maxEnabled { return .limit }
        return nil
    }

    static func ordered(_ modes: [PolishMode]) -> [PolishMode] {
        PolishMode.allCases.filter(modes.contains)
    }

    /// 本轮生效的词条：启用、合规、适用当前模式、去重，按列表顺序截取前 2000 个（确定性，不交给服务端随机挑）。
    public static func active(_ entries: [VocabularyEntry], mode: PolishMode) -> [VocabularyEntry] {
        var seen = Set<String>()
        var result: [VocabularyEntry] = []
        for entry in entries where entry.applies(to: mode) && issue(for: entry.term) == nil {
            guard seen.insert(key(entry.term)).inserted else { continue }
            result.append(entry)
            if result.count == maxEnabled { break }
        }
        return result
    }

    /// run-task `parameters.vocabulary`：`{"词": 权重}`。空词库返回空字典，调用方不写该字段。
    public static func hotwords(_ entries: [VocabularyEntry], mode: PolishMode) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in active(entries, mode: mode) { result[entry.term] = clampWeight(entry.weight) }
        return result
    }

    /// 润色阶段的专有名词表：只含写法，不含权重。
    public static func glossary(_ entries: [VocabularyEntry], mode: PolishMode) -> [String] {
        active(entries, mode: mode).map(\.term)
    }

    // MARK: - 纯文本导入导出
    //
    // 每行一个词条：`词条[<Tab>权重[<Tab>模式,模式]]`。
    // 权重缺省为 4；模式缺省或写 `all` 表示全部模式，模式名用 PolishMode 的 rawValue
    // （agent、terminal、classical、waffle、dubbed）。以 # 开头的行和空行忽略。
    // 只认 Tab 分隔，因为英文词条本身可以含空格和逗号。

    public struct ImportResult: Equatable, Sendable {
        public var entries: [VocabularyEntry]
        public var skipped: Int
    }

    /// 解析文本并与 existing 合并后得到的新增条目；重复、不合规、超过上限的行计入 skipped。
    public static func parse(_ text: String, existing: [VocabularyEntry] = []) -> ImportResult {
        var accepted: [VocabularyEntry] = []
        var skipped = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.components(separatedBy: "\t")
            let term = normalize(columns[0])
            var weight = defaultWeight
            if columns.count > 1, !columns[1].trimmingCharacters(in: .whitespaces).isEmpty {
                guard let value = Int(columns[1].trimmingCharacters(in: .whitespaces)), weights.contains(value) else {
                    skipped += 1; continue
                }
                weight = value
            }
            var modes: [PolishMode]?
            if columns.count > 2 {
                let names = columns[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
                if !(names.isEmpty || names == ["all"]) {
                    let parsed = names.compactMap(PolishMode.init(rawValue:))
                    guard parsed.count == names.count else { skipped += 1; continue }
                    modes = parsed
                }
            }
            guard issue(adding: term, to: existing + accepted) == nil else { skipped += 1; continue }
            accepted.append(VocabularyEntry(term: term, weight: weight, modes: modes))
        }
        return ImportResult(entries: accepted, skipped: skipped)
    }

    public static func export(_ entries: [VocabularyEntry]) -> String {
        var lines = ["# VoxChord vocabulary · term<TAB>weight(1-5)<TAB>modes(all | agent,terminal,classical,waffle,dubbed)"]
        for entry in entries {
            let modes = entry.modes.map { $0.map(\.rawValue).joined(separator: ",") } ?? "all"
            lines.append("\(entry.term)\t\(entry.weight)\t\(modes)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 词库文件：`vocabulary.json`，目录 0700、文件 0600，原子写入。只记录条目数，不在日志中写词条。
public final class VocabularyStore {
    public static let didChange = Notification.Name("VoxChordVocabularyDidChange")

    private struct Stored: Codable {
        var version: Int
        var entries: [VocabularyEntry]
    }

    public let fileURL: URL?
    public private(set) var entries: [VocabularyEntry]

    /// 持久化到 directory/vocabulary.json。
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("vocabulary.json")
        entries = Self.load(fileURL!)
    }

    /// 仅内存（无界面测试与预览），不写盘。
    public init(entries: [VocabularyEntry]) {
        fileURL = nil
        self.entries = entries
    }

    static func load(_ url: URL) -> [VocabularyEntry] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 else { return [] }
        return stored.entries
    }

    public func replaceAll(_ newEntries: [VocabularyEntry]) throws {
        let previous = entries
        entries = newEntries
        do { try save() } catch { entries = previous; throw error }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func update(_ change: (inout [VocabularyEntry]) -> Void) throws {
        var copy = entries
        change(&copy)
        try replaceAll(copy)
    }

    private func save() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Stored(version: 1, entries: entries))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
