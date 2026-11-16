import ApplicationServices
import Foundation

/// Line geometry through the text-marker API that WebKit and Chromium (Chrome,
/// Safari web content, Electron apps) implement. Their `AXBoundsForRange` often
/// answers with an empty rectangle, while marker ranges carry real layout.
///
/// iMic types at the caret, so the transcript ends at the selection marker. The
/// walk goes backwards line by line from there, measures each line, and accepts
/// the result only if the covered string is the transcript (or its visible tail).
/// Visual hint only; never permission to edit.
enum TextMarkerGeometry {
    struct Layout {
        let rows: [CGRect]
        let visibleUnits: Double
        let paragraphEnds: Set<Int>
    }

    static func layout(element: AXUIElement, text: String, field: CGRect, deadline: TimeInterval) -> Layout? {
        guard !text.isEmpty, let caret = caretMarker(element) else { return nil }
        let expected = normalized(text)
        var remaining = (expected as NSString).length
        var end = caret
        var collected = ""                   // covered text, in document order
        var rows: [(rect: CGRect, endsParagraph: Bool)] = []
        var visibleUnits = 0.0
        var tailChecked = false
        var lines = 0
        while remaining > 0, lines < 200 {
            lines += 1
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let previous = marker(element, "AXPreviousTextMarkerForTextMarker", end),
                  let line = parameter(element, "AXLineTextMarkerRangeForTextMarker", previous),
                  CFGetTypeID(line) == AXTextMarkerRangeGetTypeID(),
                  let lineStartRaw = AXTextMarkerRangeCopyStartMarker(line as! AXTextMarkerRange) as AXTextMarker?,
                  let full = range(lineStartRaw, end), let lineLength = length(element, full), lineLength > 0
            else { return nil }
            var start = lineStartRaw
            var segmentLength = lineLength
            if lineLength > remaining {
                // The transcript starts inside this line: step back only what remains.
                var cursor = end
                for _ in 0..<remaining {
                    guard let step = marker(element, "AXPreviousTextMarkerForTextMarker", cursor) else { return nil }
                    cursor = step
                }
                start = cursor
                segmentLength = remaining
            }
            guard let segment = range(start, end),
                  let raw = parameter(element, "AXStringForTextMarkerRange", segment) as? String else { return nil }
            let string = normalized(raw)
            collected = string+collected
            remaining -= segmentLength
            let trimmed = string.trimmingCharacters(in: .newlines)
            if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let bounds = bounds(element, segment), bounds.width > 1, bounds.height > 1 else { return nil }
                let visible = bounds.intersection(field)
                if !tailChecked {
                    tailChecked = true
                    guard visible.width > 1, visible.height >= bounds.height*0.8 else { return nil }
                }
                if visible.width > 1, visible.height > 1 {
                    rows.append((visible, string.hasSuffix("\n") || rows.isEmpty))
                    visibleUnits += PolishEndpointEstimate.units(in: trimmed)
                } else if bounds.maxY <= field.minY+1 {
                    break   // the rest of the transcript is scrolled above the viewport
                }
            }
            end = start
            if remaining > 0, rows.count >= 64 { break }
        }
        // The covered text must be the transcript itself (or its visible tail).
        guard tailChecked, !rows.isEmpty, !collected.isEmpty,
              expected.hasSuffix(collected) || collected.hasSuffix(expected) else { return nil }
        let ordered = Array(rows.reversed())
        return Layout(rows: ordered.map(\.rect), visibleUnits: visibleUnits,
                      paragraphEnds: Set(ordered.indices.filter { ordered[$0].endsParagraph }))
    }

    /// The editor's caret as a screen point (end of the character before it).
    static func caretPoint(element: AXUIElement) -> CGPoint? {
        guard let caret = caretMarker(element),
              let previous = marker(element, "AXPreviousTextMarkerForTextMarker", caret),
              let span = range(previous, caret), let rect = bounds(element, span), rect.height > 1 else { return nil }
        return CGPoint(x: rect.maxX, y: rect.midY)
    }

    /// Line breaks and spaces differ between editors' AX strings and what was typed.
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r", "\u{2028}", "\u{2029}": result.append("\n")
            case "\u{00A0}", "\u{202F}": result.append(" ")
            case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{FFFC}": continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - AX plumbing

    private static func caretMarker(_ element: AXUIElement) -> AXTextMarker? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyEndMarker(value as! AXTextMarkerRange)
    }

    private static func parameter(_ element: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &value) == .success ? value : nil
    }

    private static func marker(_ element: AXUIElement, _ name: String, _ input: AXTextMarker) -> AXTextMarker? {
        guard let value = parameter(element, name, input), CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    private static func range(_ start: AXTextMarker, _ end: AXTextMarker) -> AXTextMarkerRange? {
        AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
    }

    private static func length(_ element: AXUIElement, _ range: AXTextMarkerRange) -> Int? {
        (parameter(element, "AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue
    }

    private static func bounds(_ element: AXUIElement, _ range: AXTextMarkerRange) -> CGRect? {
        guard let value = parameter(element, "AXBoundsForTextMarkerRange", range),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
}
