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

    /// Same rows with OCR jitter removed per paragraph: one shared line height
    /// (bottom edges stay put) and continuation lines snapped to the left edge.
    static func lines(in regions: [CGRect]) -> [CGRect] {
        let rows = rows(in: regions)
        var result = rows
        for paragraph in paragraphs(rows) {
            let heights = rows[paragraph].map(\.height).sorted()
            let height = heights[heights.count/2]
            let left = rows[paragraph].map(\.minX).min() ?? 0
            for index in paragraph {
                let row = rows[index]
                let x = index != paragraph.lowerBound && row.minX-left < height*0.6 ? left : row.minX
                result[index] = CGRect(x: x, y: row.maxY-height, width: row.maxX-x, height: height)
            }
            // OCR boxes reach below the glyphs; with tight line spacing the rail
            // under one line would touch the next. Keep a 6pt gap by lifting the
            // upper line's bottom, by at most a quarter of its height.
            for index in paragraph.dropLast() {
                let row = result[index], next = result[index+1]
                let lift = min(row.height*0.25, max(0, 6-(next.minY-row.maxY)))
                if lift > 0 { result[index] = CGRect(x: row.minX, y: row.minY, width: row.width, height: row.height-lift) }
            }
        }
        return result
    }

    /// Reading-order rows split where a blank-line sized gap appears.
    static func paragraphs(_ rows: [CGRect]) -> [Range<Int>] {
        guard !rows.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        for index in rows.indices.dropFirst() {
            let previous = rows[index-1], next = rows[index]
            if next.minY-previous.maxY > max(previous.height, next.height)*0.8 {
                result.append(start..<index); start = index
            }
        }
        result.append(start..<rows.count)
        return result
    }

    /// One orange endpoint per paragraph: the indices of each paragraph's last row.
    static func paragraphEnds(_ rows: [CGRect]) -> Set<Int> {
        Set(paragraphs(rows).map { $0.upperBound-1 })
    }

    /// Keyline core thickness follows the text size so rails sit like underlines.
    static func stroke(lineHeight: CGFloat) -> CGFloat {
        min(2, max(1, (lineHeight/14).rounded()))
    }

    /// Single-line fields centre their text vertically. When neither AX ranges
    /// nor OCR are usable, approximate the row from the field and transcript.
    static func singleLineEstimate(field: CGRect, text: String) -> CGRect? {
        guard field.width > 40, field.height > 12, field.height < 64, !text.isEmpty else { return nil }
        let height = min(22, field.height*0.6)
        let inset = min(10, field.width*0.05)
        let width = min(field.width-inset*2, max(height, CGFloat(PolishEndpointEstimate.units(in: text))*height*0.92))
        return CGRect(x: field.minX+inset, y: field.midY-height/2, width: width, height: height)
    }

    static func duration(lineCount: Int) -> TimeInterval {
        lineDuration + min(0.12, Double(max(0, lineCount-1))*0.04)
    }

    static func delay(row: Int, lineCount: Int) -> TimeInterval {
        guard lineCount > 1 else { return 0 }
        return (duration(lineCount: lineCount)-lineDuration)*Double(row)/Double(lineCount-1)
    }
}

/// Candidates arrive in front-to-back order. Dialogs may sit above layer zero;
/// never cross into another application's window or into menus/status overlays.
enum PolishWindowSelection {
    struct Candidate {
        let id: UInt32
        let pid: Int32
        let frame: CGRect
        let layer: Int
        let visible: Bool
    }
    static func choose(_ candidates: [Candidate], pid: Int32, preferred: CGRect? = nil) -> Candidate? {
        let eligible = candidates.filter {
            $0.pid == pid && $0.visible && (0...24).contains($0.layer)
                && $0.frame.width >= 80 && $0.frame.height >= 32
        }
        if let preferred, let exact = eligible.first(where: {
            abs($0.frame.minX-preferred.minX) < 2 && abs($0.frame.minY-preferred.minY) < 2
                && abs($0.frame.width-preferred.width) < 2 && abs($0.frame.height-preferred.height) < 2
        }) { return exact }
        return eligible.first
    }
}

/// One visual line of an editor, as reported by its AX line ranges.
enum TextLineSegment {
    /// The line's UTF-16 range without trailing line breaks, and whether a hard
    /// paragraph break ended it. Blank lines return nil: their bounds are empty
    /// in most editors and they carry no rail.
    static func visible(_ range: NSRange, in text: NSString) -> (range: NSRange, endsParagraph: Bool)? {
        var length = range.length
        var endsParagraph = false
        while length > 0 {
            let unit = text.character(at: range.location+length-1)
            if unit == 0x0A || unit == 0x0D || unit == 0x2029 { endsParagraph = true }
            else if unit != 0x2028 { break }
            length -= 1
        }
        let trimmed = NSRange(location: range.location, length: length)
        guard length > 0, !text.substring(with: trimmed).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (trimmed, endsParagraph)
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

    struct Match {
        let spans: [Span]
        let includesEnd: Bool
    }

    static func match(expected: String, fragments: [String], cancelled: () -> Bool = { false }) -> [Span]? {
        locate(expected: expected, fragments: fragments, cancelled: cancelled)?.spans
    }

    /// `fieldScoped`: the OCR image is the text field itself (AX frame), so the
    /// transcript tail may be followed by in-field chrome such as counters or
    /// placeholders. Window-wide OCR keeps requiring the tail to end the image.
    static func locate(expected: String, fragments: [String], allowClipped: Bool = false,
                       fieldScoped: Bool = false, cancelled: () -> Bool = { false }) -> Match? {
        // Bound CPU/memory independently of the maximum ten-minute recording.
        let pattern = Array(tokens([expected]).suffix(1_200))
        // Window-wide OCR also reads gutters: code editors and terminals put a
        // line number beside every line, which would interleave with the
        // transcript. Bare numbers are dropped (indices stay aligned).
        let fragments = fieldScoped ? fragments : fragments.map { fragment in
            let bare = fragment.trimmingCharacters(in: .whitespaces)
            return bare.count <= 5 && !bare.isEmpty && bare.allSatisfy(\.isNumber) ? "" : fragment
        }
        let source = Array(tokens(fragments).suffix(4_000))
        let m = pattern.count, n = source.count
        if m < 6 {
            // Window-wide OCR sees much more text; two-character words are too common there.
            return fieldScoped || m >= 3 ? exactShort(pattern, in: source, fragments: fragments) : nil
        }
        guard n >= 6, !cancelled() else { return nil }
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
        let alignedStart = j, alignedEnd = bestJ
        let full = Double(bestI - i) / Double(m) >= 0.85
        let visibleSuffix = bestI == m && (bestJ >= n - 2 || fieldScoped) && matches >= 24
        // Narrow single-line fields may show fewer than 24 characters, or a
        // middle slice. Require a strong match covering most visible OCR text;
        // retain the existing competing-occurrence rejection below.
        let coverage = Double(bestJ-j)/Double(n)
        let clipped = allowClipped && matches >= 8 && Double(matches)/Double(consumed) >= 0.94
            && coverage >= (bestI == m ? 0.65 : 0.85)
        guard full || visibleSuffix || clipped else { return nil }
        // Two equally plausible occurrences: skip rather than highlight old draft.
        let competing = (1...n).filter { $0 <= alignedStart || $0 > alignedEnd + 3 }.map { columnBest[$0] }.max() ?? 0
        guard Double(competing) < Double(best) * 0.94 else { return nil }
        // Acceptance above uses the aligned core only. Local alignment drops
        // misread characters at its ends and would shrink the rail into the
        // middle of a line, so the drawn span re-extends over unmatched
        // transcript characters: same OCR line, at most six per side.
        var back = 0
        while back < min(i, 6), j > 0, source[j-1].fragment == source[alignedStart].fragment { j -= 1; back += 1 }
        var forward = 0
        while forward < min(m-bestI, 6), bestJ < n, source[bestJ].fragment == source[alignedEnd-1].fragment { bestJ += 1; forward += 1 }
        bestI += forward
        let spans = spans(source, j..<bestJ, fragments: fragments)
        return spans.isEmpty ? nil : Match(spans: spans, includesEnd: bestI == m)
    }

    /// Short transcripts (two to five characters) cannot be aligned reliably.
    /// Inside a known field accept only a single exact occurrence.
    private static func exactShort(_ pattern: [Token], in source: [Token], fragments: [String]) -> Match? {
        let m = pattern.count
        guard m >= 2, source.count >= m else { return nil }
        let hits = (0...(source.count-m)).filter { start in
            (0..<m).allSatisfy { source[start+$0].character == pattern[$0].character }
                && source[start+m-1].fragment == source[start].fragment
        }
        guard hits.count == 1, let start = hits.first else { return nil }
        let spans = spans(source, start..<(start+m), fragments: fragments)
        return spans.isEmpty ? nil : Match(spans: spans, includesEnd: true)
    }

    /// One span per OCR line. A side with no remaining letters or digits on that
    /// line snaps to the line edge, so trailing punctuation is covered and the
    /// whole observation box can be used instead of an interpolated sub-box.
    private static func spans(_ source: [Token], _ range: Range<Int>, fragments: [String]) -> [Span] {
        var spans: [Span] = []
        for token in source[range] {
            if let last = spans.last, last.fragment == token.fragment {
                spans[spans.count - 1] = Span(fragment: last.fragment, range: NSUnionRange(last.range, token.range))
            } else {
                spans.append(Span(fragment: token.fragment, range: token.range))
            }
        }
        return spans.map { span in
            let fragmentTokens = source.filter { $0.fragment == span.fragment }
            let length = (fragments[span.fragment] as NSString).length
            let before = fragmentTokens.contains { $0.range.location < span.range.location }
            let after = fragmentTokens.contains { $0.range.location >= NSMaxRange(span.range) }
            let start = before ? span.range.location : 0
            let end = after ? NSMaxRange(span.range) : length
            return Span(fragment: span.fragment, range: NSRange(location: start, length: end-start))
        }
    }
}

/// 8-bit luminance pixels, row-major, top row first.
struct InkImage {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    func value(_ x: Int, _ y: Int) -> Int { Int(pixels[y*width+x]) }
}

/// Pixel-level correction of OCR line boxes. Vision's boxes float with the
/// glyphs on each line (punctuation stretches them), so rails drawn from them
/// sit at uneven distances below the text. The captured image shows the real
/// ink: pixels that stand out from the band's dominant background luminance.
enum InkBounds {
    /// `box` and the result are in image pixels, y down. `window` bounds the
    /// vertical search (midpoints to neighbouring rows). Horizontally the box only
    /// shrinks to its ink, except outward on a side that ends the OCR line, where
    /// a clipped trailing glyph (often 。) may be recovered.
    static func refine(_ box: CGRect, in image: InkImage, window: ClosedRange<Int>,
                       extendLeft: Bool = false, extendRight: Bool = false) -> CGRect? {
        let x0 = max(0, Int(box.minX.rounded(.down))), x1 = min(image.width-1, Int(box.maxX.rounded(.up))-1)
        let y0 = max(0, window.lowerBound), y1 = min(image.height-1, window.upperBound)
        guard x1 > x0+2, y1 > y0+2, box.height >= 4 else { return nil }
        // Background: the dominant luminance in the margins above and below the
        // OCR box (dense glyphs can outnumber background inside it), else the band.
        func dominant(_ rows: [Int]) -> (value: Int, samples: Int) {
            var histogram = [Int](repeating: 0, count: 256), samples = 0
            for y in rows { for x in stride(from: x0, through: x1, by: 2) { histogram[image.value(x, y)] += 1; samples += 1 } }
            return (histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255, samples)
        }
        let margins = (y0...y1).filter { CGFloat($0) < box.minY || CGFloat($0) >= box.maxY }
        let sampled = dominant(margins)
        let background = sampled.samples >= 40 ? sampled.value : dominant(Array(y0...y1)).value
        func ink(_ x: Int, _ y: Int) -> Bool { abs(image.value(x, y)-background) > 48 }

        // Rows carrying ink inside the box's columns, grouped with small gaps.
        let minimum = max(1, (x1-x0)/300)
        var clusters: [ClosedRange<Int>] = []
        var open: (start: Int, last: Int)?
        let gap = max(1, Int(box.height*0.15))
        for y in y0...y1 {
            var count = 0
            for x in x0...x1 where ink(x, y) { count += 1; if count >= minimum { break } }
            guard count >= minimum else { continue }
            if let current = open, y-current.last <= gap+1 { open = (current.start, y) }
            else { if let current = open { clusters.append(current.start...current.last) }; open = (y, y) }
        }
        if let current = open { clusters.append(current.start...current.last) }
        func overlap(_ band: ClosedRange<Int>) -> CGFloat {
            max(0, min(CGFloat(band.upperBound+1), box.maxY)-max(CGFloat(band.lowerBound), box.minY))
        }
        guard let band = clusters.max(by: { overlap($0) < overlap($1) }), overlap(band) > 0 else { return nil }
        let height = CGFloat(band.count)
        guard height >= box.height*0.35, height <= box.height*1.5 else { return nil }

        func columnHasInk(_ x: Int) -> Bool { band.contains { ink(x, $0) } }
        let inner = (x0...x1).filter(columnHasInk)
        guard var left = inner.first, var right = inner.last else { return nil }
        let reach = Int(height*0.9), tolerance = max(2, Int(height*0.6))
        if extendRight {
            var x = right+1
            while x < image.width, x <= x1+reach, x-right <= tolerance { if columnHasInk(x) { right = x }; x += 1 }
        }
        if extendLeft {
            var x = left-1
            while x >= 0, x >= x0-reach, left-x <= tolerance { if columnHasInk(x) { left = x }; x -= 1 }
        }
        return CGRect(x: CGFloat(left), y: CGFloat(band.lowerBound), width: CGFloat(right-left+1), height: height)
    }
}
