import AppKit
import ApplicationServices

/// A read-only AX presentation may insert line breaks when the editor wraps.
/// Match the complete emitted suffix and its anchor, never just a character count.
enum InputRangeMatcher {
    static func range(in rendered: String, location: Int, text: String, context: String) -> CFRange? {
        guard !text.isEmpty else { return nil }
        let units = rendered.utf16
        var cursor = units.endIndex
        func consume(_ expected: String, ignoringContextBreaks: Bool = false) -> Bool {
            for wanted in expected.utf16.reversed() {
                if ignoringContextBreaks, wanted == 10 || wanted == 13 { continue }
                var matched = false
                while cursor != units.startIndex {
                    let previous = units.index(before: cursor)
                    let actual = units[previous]
                    cursor = previous
                    if actual == wanted { matched = true; break }
                    if actual != 10 && actual != 13 { return false }
                }
                if !matched { return false }
            }
            return true
        }
        guard consume(text) else { return nil }
        let start = cursor
        guard consume(context, ignoringContextBreaks: true) else { return nil }
        let offset = units.distance(from: units.startIndex, to: start)
        return CFRange(location: location + offset, length: units.count - offset)
    }
}

/// Prefer verified AX ranges; keyboard compatibility is explicitly authorized for
/// unreadable/unreliable targets and stops on any external input or app switch.
final class InputTarget {
    enum InitialPreparation { case ready, collapseSelection, changed }
    enum Validation {
        case ready
        case waiting(String)
        case interrupted(String)
    }
    enum Mode: String {
        case verifiedRange = "verified_range"
        case keyboard = "keyboard_compatibility"
        case finalOnly = "final_only"
    }

    private let pid: pid_t
    private let element: AXUIElement?
    private let initialSelection: CFRange?
    private var ownedStart: Int?
    private let leadingContext: String?
    static let keyboardEventTag = Int64.random(in: 1...Int64.max)

    private(set) var mode: Mode
    var allowsStreaming: Bool { mode != .finalOnly }
    var requiresConfirmation: Bool { mode == .verifiedRange }
    private let replacesSelectionDirectly: Bool
    private var inputMonitor: Any?
    private var applicationMonitor: NSObjectProtocol?
    private var userIntervened = false

    static func capture(pid: pid_t) -> InputTarget {
        let element = focusedElement(pid: pid)
        let selection = element.flatMap(selectedRange)
        var canObserve = false
        var canReplace = false
        if let element, selection != nil {
            var names: CFArray?
            canObserve = AXUIElementCopyParameterizedAttributeNames(element, &names) == .success
                && (names as? [String])?.contains(kAXStringForRangeParameterizedAttribute) == true
            canReplace = canObserve && isSettable(kAXSelectedTextRangeAttribute, on: element)
                && isSettable(kAXSelectedTextAttribute, on: element)
        }
        // Otty exposes its rendered terminal screen, not the TUI editor cursor.
        // Its advertised range interface cannot establish an editable owned tail.
        let presentationOnly = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "io.appmakes.otty"
        return InputTarget(pid: pid, element: element, initialSelection: selection,
                           mode: canObserve && !presentationOnly ? .verifiedRange : .keyboard,
                           replacesSelectionDirectly: canReplace)
    }

    private init(pid: pid_t, element: AXUIElement?, initialSelection: CFRange?,
                 mode: Mode, replacesSelectionDirectly: Bool) {
        self.pid = pid
        self.element = element
        self.initialSelection = initialSelection
        self.mode = mode
        self.replacesSelectionDirectly = replacesSelectionDirectly
        let start = initialSelection.map { $0.location + $0.length }
        ownedStart = start
        if let start, let element {
            let count = min(32, start)
            leadingContext = Self.text(in: CFRange(location: start - count, length: count), on: element)
        } else {
            leadingContext = nil
        }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Only inspect origin metadata, never key contents. Terminal AX cursors
            // can stay parked while the application's own editor cursor moves.
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.keyboardEventTag else { return }
            self?.userIntervened = true
        }
        applicationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self?.pid else { return }
            self?.userIntervened = true
        }
        if inputMonitor == nil, mode == .keyboard || !replacesSelectionDirectly {
            self.mode = .finalOnly
        }
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let applicationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(applicationMonitor) }
    }

    func prepareInitialInsertion() -> InitialPreparation {
        guard !userIntervened else { return .changed }
        if mode == .keyboard {
            guard compatibilityFocusMatches() else { return .changed }
            // Unknown selections must be collapsed, not replaced. A known
            // collapsed selection needs no Right key (which could move a TUI cursor).
            guard let element, let range = Self.selectedRange(element) else { return .collapseSelection }
            return range.length == 0 ? .ready : .collapseSelection
        }
        guard let element else { return .collapseSelection }
        guard isFocused(element) else { return .changed }
        guard let initialSelection else { return .collapseSelection }
        guard let current = Self.selectedRange(element), Self.equal(current, initialSelection) else { return .changed }
        guard initialSelection.length > 0 else { return .ready }
        let caret = CFRange(location: initialSelection.location + initialSelection.length, length: 0)
        // Collapse an existing selection, preserving its contents instead of replacing it.
        return Self.setRange(caret, on: element) ? .ready : .collapseSelection
    }

    func validate(_ committed: String) -> Validation {
        guard !userIntervened else { return .interrupted("user_input") }
        if mode == .keyboard {
            return compatibilityFocusMatches() ? .ready : .interrupted("focus_changed")
        }
        guard let element, isFocused(element) else { return .interrupted("focus_changed") }
        guard allowsStreaming, let start = ownedStart,
              let caret = Self.selectedRange(element) else { return .waiting("range_unavailable") }
        let count = committed.utf16.count
        if caret.length == 0, caret.location == start + count,
           Self.text(in: CFRange(location: start, length: count), on: element) == committed {
            return .ready
        }
        // Read-only AX surfaces can add display-only line breaks and move their
        // offsets during wrapping/scrolling. Verify the actual span, not an
        // assumed caret = start + UTF-16 count. Editable AX fields stay exact.
        if !replacesSelectionDirectly, !committed.isEmpty, caret.length == 0,
           let leadingContext {
            let windowLength = min(caret.location, 2 * (count + leadingContext.utf16.count) + 2)
            let windowStart = caret.location - windowLength
            if let rendered = Self.text(in: CFRange(location: windowStart, length: windowLength), on: element),
               rendered.utf16.count == windowLength,
               let range = InputRangeMatcher.range(in: rendered, location: windowStart,
                                                   text: committed, context: leadingContext),
               !leadingContext.isEmpty || range.location == start {
                if ownedStart != range.location {
                    IMicLog.write("mac.input", "range rebased from=\(start) to=\(range.location) span=\(range.length) chars=\(count)")
                }
                ownedStart = range.location
                return .ready
            }
        }
        return .waiting("caret=\(caret.location):\(caret.length) expected=\(start + count) chars=\(count)")
    }

    func replaceTail(
        previous: String, next: String, revision: TextRevision,
        keyboardRevision: (Int, String) -> Bool
    ) -> Bool {
        guard revision.deleteCount > 0, revision.deleteCount <= previous.count,
              case .ready = validate(previous) else { return false }
        if mode == .keyboard {
            return keyboardRevision(revision.deleteCount, revision.insertion)
        }
        guard let element, let start = ownedStart else { return false }
        if !replacesSelectionDirectly {
            return keyboardRevision(revision.deleteCount, revision.insertion)
        }
        let tail = previous.suffix(revision.deleteCount)
        let range = CFRange(location: start + previous.utf16.count - tail.utf16.count, length: tail.utf16.count)
        guard Self.setRange(range, on: element),
              let selected = Self.text(in: range, on: element), selected.utf16.elementsEqual(tail.utf16),
              let current = Self.selectedRange(element), Self.equal(current, range), isFocused(element) else { return false }
        // AXSelectedText replaces exactly the verified selection, not AXValue/the complete draft.
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, revision.insertion as CFString) == .success else { return false }
        var caret = CFRange(location: start + next.utf16.count, length: 0)
        guard let value = AXValueCreate(.cfRange, &caret) else { return false }
        // A successful setter is not delivery confirmation: the caller waits for
        // validate(next) on subsequent run-loop turns before sending another edit.
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func enableKeyboardCompatibility() -> Bool {
        guard inputMonitor != nil, !userIntervened, compatibilityFocusMatches() else { return false }
        mode = .keyboard
        return true
    }

    private func compatibilityFocusMatches() -> Bool {
        // AX element identity can be missing/stale in precisely these editors.
        // The captured app plus user-input/app-switch monitors own this mode.
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        guard !userIntervened, let focused = Self.focusedElement(pid: pid) else { return false }
        return CFEqual(focused, element)
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        return element
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location < Int.max - range.length else { return nil }
        return range
    }

    private static func setRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              let actual = selectedRange(element) else { return false }
        return equal(actual, range)
    }

    private static func text(in range: CFRange, on element: AXUIElement) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func equal(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }
}
