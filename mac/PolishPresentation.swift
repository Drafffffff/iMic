import Foundation
import CoreGraphics

enum SweepLineLayout {
    static let lineDuration: TimeInterval = 0.32

    /// OCR may split one visual line into several observations. Merge only
    /// vertically overlapping fragments, then use top-to-bottom reading order.
    static func rows(in regions: [CGRect]) -> [CGRect] {
        let sorted = regions.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
            .sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        var result: [CGRect] = []
        for rect in sorted {
            if let last = result.last,
               max(0, min(last.maxY, rect.maxY)-max(last.minY, rect.minY)) >= min(last.height, rect.height)*0.65 {
                result[result.count-1] = last.union(rect)
            } else { result.append(rect) }
        }
        return result
    }

    static func duration(lineCount: Int) -> TimeInterval {
        lineDuration + min(0.12, Double(max(0, lineCount-1))*0.04)
    }

    static func delay(row: Int, lineCount: Int) -> TimeInterval {
        guard lineCount > 1 else { return 0 }
        return (duration(lineCount: lineCount)-lineDuration)*Double(row)/Double(lineCount-1)
    }
}

/// AX document bounds can exceed the window after a long dictation. Capture
/// only their intersection with the visible scroll containers and window.
enum TextViewport {
    static func visible(content: CGRect, window: CGRect, clips: [CGRect]) -> CGRect? {
        let rect = clips.reduce(content.intersection(window)) { $0.intersection($1) }
        return !rect.isNull && !rect.isInfinite && rect.width > 10 && rect.height > 8 ? rect : nil
    }
}

/// Visual fallback only: approximate reflow using the two transcripts and the
/// observed line pitch/advance. It is not a caret or text-delivery assertion.
enum PolishEndpointEstimate {
    static func units(in text: String) -> Double {
        text.reduce(0) { total, character in
            if character == "\n" || character == "\r" { return total }
            if character.isWhitespace { return total + 0.35 }
            return total + (character.unicodeScalars.allSatisfy { $0.isASCII } ? 0.5 : 1)
        }
    }

    static func endpoint(original: String, final: String, rows: [CGRect], field: CGRect, visibleUnits: Double = 0, referenceField: CGRect? = nil) -> CGPoint? {
        estimate(original: original, final: final, rows: rows, field: field, visibleUnits: visibleUnits, referenceField: referenceField)?.endpoint
    }

    static func layout(original: String, final: String, rows: [CGRect], field: CGRect, visibleUnits: Double = 0, referenceField: CGRect? = nil) -> [CGRect] {
        estimate(original: original, final: final, rows: rows, field: field, visibleUnits: visibleUnits, referenceField: referenceField)?.rows ?? []
    }

    private static func estimate(original: String, final: String, rows: [CGRect], field: CGRect, visibleUnits: Double, referenceField: CGRect?) -> (rows: [CGRect], endpoint: CGPoint)? {
        // Auto-growing composers often keep the bottom fixed and move upward.
        // Rebase the original OCR rows before estimating the new line positions.
        let rows = rows.map { $0.offsetBy(dx: field.minX-(referenceField?.minX ?? field.minX),
                                         dy: field.minY-(referenceField?.minY ?? field.minY)) }
        guard let first = rows.first, field.width > 4, field.height > 4, !final.isEmpty else { return nil }
        let originalUnits = units(in: original)
        guard originalUnits > 0 else { return nil }
        let observed = visibleUnits > 0 ? visibleUnits : originalUnits
        let advance = min(first.height*1.5, max(2, rows.reduce(0) { $0+$1.width } / observed))
        let left = rows.count > 1 ? rows.map(\.minX).min()! : field.minX+min(12, max(0, first.minX-field.minX))
        let rightInset = min(16, max(0, field.maxX-(rows.map(\.maxX).max() ?? field.maxX)))
        let right = max(left+advance, field.maxX-rightInset)
        let pitches = zip(rows, rows.dropFirst()).map { $1.midY-$0.midY }.filter { $0 > 2 }.sorted()
        let pitch = pitches.isEmpty ? max(18, first.height*1.25) : pitches[pitches.count/2]
        let scrolled = originalUnits > observed*1.2
        var x = scrolled ? left : first.minX
        var row: CGFloat = 0
        var startX = x
        var lines: [CGRect] = []
        func appendLine() {
            let y = (scrolled ? field.minY : first.minY)+row*pitch
            lines.append(CGRect(x: startX, y: y, width: max(1, x-startX), height: first.height))
        }
        for character in final {
            if character == "\n" { appendLine(); x = left; startX = left; row += 1; continue }
            let width = units(in: String(character))*advance
            if x+width > right+0.5, x > left+0.5 { appendLine(); x = left; startX = left; row += 1 }
            x += width
        }
        appendLine()
        // If the result exceeds the viewport, editors keep its tail visible.
        // Shift the complete layout first, then clip; never discard the new tail
        // while leaving the endpoint clamped onto an unrelated old line.
        let overflow = max(0, (lines.last?.maxY ?? field.minY)-field.maxY)
        lines = lines.compactMap {
            let visible = $0.offsetBy(dx: 0, dy: -overflow).intersection(field)
            return !visible.isNull && visible.width > 0 && visible.height > 2 ? visible : nil
        }
        guard let last = lines.last else { return nil }
        return (lines, CGPoint(x: min(field.maxX-1, max(field.minX+1, x)), y: last.midY))
    }
}

/// The result and visual timelines are independent. Only the writing transition
/// releases a final result; release particles can never trigger another write.
struct PolishEffectLifecycle {
    enum Phase: Hashable { case idle, locating, sweeping, holding, skipped, writing, releasing, finished, cancelled }
    private(set) var phase: Phase = .idle
    var blocksGestures: Bool { [.locating, .sweeping, .holding, .writing, .releasing].contains(phase) }
    private(set) var hasResult = false

    mutating func beginPreparation() { self = Self(); phase = .locating }
    mutating func visualPrepared() -> Bool {
        guard phase == .locating else { return false }
        phase = .sweeping; return true
    }
    mutating func sweepFinished() {
        if phase == .sweeping { phase = .holding }
    }
    mutating func selectResult() -> Bool {
        guard !hasResult, phase != .cancelled, phase != .finished else { return false }
        hasResult = true; return true
    }
    mutating func skipVisual() {
        guard [.idle, .locating, .sweeping, .holding].contains(phase) else { return }
        phase = .skipped
    }
    mutating func beginWriting() -> Bool {
        guard hasResult, [.idle, .holding, .skipped].contains(phase) else { return false }
        phase = .writing; return true
    }
    mutating func beginRelease() -> Bool {
        guard phase == .writing else { return false }
        phase = .releasing; return true
    }
    mutating func finish() { phase = .finished }
    mutating func cancel() { phase = .cancelled }
}

/// Exactly one terminal choice per utterance, including a hard deadline fallback.
struct PolishFinalChoice {
    enum Source { case polished, original }
    private(set) var source: Source?

    mutating func settle(raw: String, polished: String?) -> String? {
        guard source == nil else { return nil }
        let clean = polished?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        source = clean.isEmpty ? .original : .polished
        return clean.isEmpty ? raw : clean
    }
}

/// OCR is a visual hint only. No result from this matcher authorizes a text edit.
enum TextRegionMatcher {
    struct Span: Equatable {
        let fragment: Int
        let range: NSRange
    }
    private struct Token {
        let character: Character
        let fragment: Int
        let range: NSRange
    }

    private static func tokens(_ fragments: [String]) -> [Token] {
        var result: [Token] = []
        for (fragment, text) in fragments.enumerated() {
            var offset = 0
            for character in text {
                let length = String(character).utf16.count
                let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                for unit in folded where unit.unicodeScalars.contains(where: {
                    CharacterSet.alphanumerics.contains($0) || CharacterSet.symbols.contains($0)
                }) {
                    result.append(Token(character: unit, fragment: fragment, range: NSRange(location: offset, length: length)))
                }
                offset += length
            }
        }
        return result
    }

    static func match(expected: String, fragments: [String], cancelled: () -> Bool = { false }) -> [Span]? {
        // Bound CPU/memory independently of the maximum ten-minute recording.
        let pattern = Array(tokens([expected]).suffix(1_200))
        let source = Array(tokens(fragments).suffix(4_000))
        let m = pattern.count, n = source.count
        guard m >= 6, n >= 6, !cancelled() else { return nil }
        let width = n + 1
        var trace = [UInt8](repeating: 0, count: (m + 1) * width)
        var previous = [Int](repeating: 0, count: width)
        var current = previous
        var columnBest = previous
        var best = 0, bestI = 0, bestJ = 0
        for i in 1...m {
            if cancelled() { return nil }
            current[0] = 0
            for j in 1...n {
                let diagonal = previous[j - 1] + (pattern[i - 1].character == source[j - 1].character ? 3 : -4)
                let up = previous[j] - 3, left = current[j - 1] - 3
                let score = max(0, diagonal, up, left)
                current[j] = score
                trace[i * width + j] = score == 0 ? 0 : score == diagonal ? 1 : score == up ? 2 : 3
                columnBest[j] = max(columnBest[j], score)
                if score > best { best = score; bestI = i; bestJ = j }
            }
            swap(&previous, &current)
        }
        var i = bestI, j = bestJ, matches = 0
        while i > 0, j > 0 {
            let step = trace[i * width + j]
            if step == 0 { break }
            if step == 1 {
                if pattern[i - 1].character == source[j - 1].character { matches += 1 }
                i -= 1; j -= 1
            } else if step == 2 { i -= 1 } else { j -= 1 }
        }
        let consumed = max(bestI - i, bestJ - j)
        guard consumed >= 6, Double(matches) / Double(consumed) >= 0.9 else { return nil }
        let full = Double(bestI - i) / Double(m) >= 0.85
        let visibleSuffix = bestI == m && bestJ >= n - 2 && matches >= 24
        guard full || visibleSuffix else { return nil }
        // Two equally plausible occurrences: skip rather than highlight old draft.
        let competing = (1...n).filter { $0 <= j || $0 > bestJ + 3 }.map { columnBest[$0] }.max() ?? 0
        guard Double(competing) < Double(best) * 0.94 else { return nil }
        var spans: [Span] = []
        for token in source[j..<bestJ] {
            if let last = spans.last, last.fragment == token.fragment {
                spans[spans.count - 1] = Span(fragment: last.fragment, range: NSUnionRange(last.range, token.range))
            } else {
                spans.append(Span(fragment: token.fragment, range: token.range))
            }
        }
        return spans.isEmpty ? nil : spans
    }
}
