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

enum InputTailTransaction {
    enum Outcome { case applied, needsConfirmation, keyboard, blocked }

    /// Selection can be recovered before a text write. Once a write was attempted,
    /// a failure is ambiguous: never replay it through a second delivery channel.
    static func perform(
        select: () -> Bool, verify: () -> Bool, restoreOriginal: () -> Bool,
        write: () -> Bool, restoreFinal: () -> Bool
    ) -> Outcome {
        guard select(), verify() else { return restoreOriginal() ? .keyboard : .blocked }
        guard write() else { return .needsConfirmation }
        return restoreFinal() ? .applied : .needsConfirmation
    }
}

/// Prefer verified AX ranges; keyboard compatibility is explicitly authorized for
/// unreadable/unreliable targets and stops on any external input or app switch.
final class InputTarget {
    /// Explicit whole-field clear, separate from streaming tail revisions. Never
    /// issue a blind Select All against an unreadable editor, page or terminal.
    static func clearFocusedText(pid: pid_t, completion: @escaping (Bool) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let element = focusedElement(pid: pid) else { completion(false); return }
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard clearRoleAllowed(role as? String, valueSettable: isSettable(kAXValueAttribute, on: element)),
              focusedElement(pid: pid).map({ CFEqual($0, element) }) == true,
              AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFString) == .success else {
            completion(false); return
        }
        let deadline = Date().addingTimeInterval(0.35)
        func verify() {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  focusedElement(pid: pid).map({ CFEqual($0, element) }) == true else { completion(false); return }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String, text.isEmpty { completion(true); return }
            guard Date() < deadline else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: verify)
        }
        verify()
    }

    static func clearRoleAllowed(_ role: String?, valueSettable: Bool) -> Bool {
        valueSettable && [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
    }
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
    enum Replacement { case applied, pending, blocked }
    enum PendingResolution { case none, waiting, applied(String), blocked }
    private struct PendingReplacement {
        let next: String
        let deadline: Date
        var attemptedCaretRecovery = false
    }
    private var pendingReplacement: PendingReplacement?

    static func initialMode(bundleIdentifier: String?, canObserveRange: Bool) -> Mode {
        // Otty exposes a rendered screen, not the TUI editor cursor. Codex's
        // rich-text composer advertises range support but AX tail selection can
        // leave a visible selection/formatting popover when replacement fails.
        // Choose compatibility before any range mutation, not after a timeout.
        switch bundleIdentifier {
        case "io.appmakes.otty", "com.openai.codex": return .keyboard
        default: return canObserveRange ? .verifiedRange : .keyboard
        }
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
    var visualElement: AXUIElement? { element }
    var permitsVisualEffect: Bool { !userIntervened && compatibilityFocusMatches() }
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
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return InputTarget(pid: pid, element: element, initialSelection: selection,
                           mode: initialMode(bundleIdentifier: bundleIdentifier, canObserveRange: canObserve),
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
    ) -> Replacement {
        guard revision.deleteCount > 0, revision.deleteCount <= previous.count,
              pendingReplacement == nil,
              case .ready = validate(previous) else { return .blocked }
        if mode == .keyboard {
            return keyboardRevision(revision.deleteCount, revision.insertion) ? .applied : .blocked
        }
        guard let element, let start = ownedStart else { return .blocked }
        if !replacesSelectionDirectly {
            return keyboardRevision(revision.deleteCount, revision.insertion) ? .applied : .blocked
        }
        let tail = previous.suffix(revision.deleteCount)
        let range = CFRange(location: start + previous.utf16.count - tail.utf16.count, length: tail.utf16.count)
        let outcome = InputTailTransaction.perform(
            select: { Self.setRange(range, on: element) },
            verify: {
                guard self.isFocused(element),
                      let selected = Self.text(in: range, on: element), selected.utf16.elementsEqual(tail.utf16),
                      let current = Self.selectedRange(element) else { return false }
                return Self.equal(current, range)
            },
            restoreOriginal: {
                let caret = CFRange(location: start + previous.utf16.count, length: 0)
                guard self.isFocused(element),
                      Self.text(in: CFRange(location: start, length: previous.utf16.count), on: element) == previous,
                      let current = Self.selectedRange(element),
                      Self.equal(current, range) || Self.equal(current, caret) else { return false }
                return (Self.equal(current, caret) || Self.setRange(caret, on: element))
                    && self.enableKeyboardCompatibility()
            },
            write: {
                guard self.isFocused(element), let current = Self.selectedRange(element),
                      Self.equal(current, range) else { return false }
                return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                                   revision.insertion as CFString) == .success
            },
            restoreFinal: {
                self.isFocused(element)
                    && Self.setRange(CFRange(location: start + next.utf16.count, length: 0), on: element)
            }
        )
        switch outcome {
        case .applied:
            // Even a successful AX setter is not an editor acceptance receipt.
            // Keep ownership of reconciliation so a timeout cannot replay it.
            pendingReplacement = PendingReplacement(next: next, deadline: Date().addingTimeInterval(1.5))
            return .pending
        case .keyboard:
            IMicLog.write("mac.input", "mode=keyboard_compatibility reason=ax_selection_recovered")
            return keyboardRevision(revision.deleteCount, revision.insertion) ? .applied : .blocked
        case .needsConfirmation:
            pendingReplacement = PendingReplacement(next: next, deadline: Date().addingTimeInterval(0.3))
            IMicLog.write("mac.input", "AX write outcome uncertain; reconciling without replay")
            return .pending
        case .blocked: return .blocked
        }
    }

    func settlePendingReplacement() -> PendingResolution {
        guard var pending = pendingReplacement else { return .none }
        if case .ready = validate(pending.next) {
            pendingReplacement = nil
            return .applied(pending.next)
        }
        guard !userIntervened, let element, isFocused(element), let start = ownedStart,
              Date() < pending.deadline else {
            pendingReplacement = nil
            return .blocked
        }
        // Recover a stranded selection only after the complete NEW span is visible
        // and the selection is entirely inside it. Never restore a stale old caret.
        if !pending.attemptedCaretRecovery,
           Self.text(in: CFRange(location: start, length: pending.next.utf16.count), on: element) == pending.next,
           let selection = Self.selectedRange(element), selection.location >= start,
           selection.location + selection.length <= start + pending.next.utf16.count {
            pending.attemptedCaretRecovery = true
            pendingReplacement = pending
            _ = Self.setRange(CFRange(location: start + pending.next.utf16.count, length: 0), on: element)
        }
        return .waiting
    }

    func enableKeyboardCompatibility() -> Bool {
        guard pendingReplacement == nil, inputMonitor != nil, !userIntervened, compatibilityFocusMatches() else { return false }
        mode = .keyboard
        return true
    }

    private func compatibilityFocusMatches() -> Bool {
        // AX element identity can be missing/stale in precisely these editors.
        // The captured app plus user-input/app-switch monitors own this mode.
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        guard !userIntervened, compatibilityFocusMatches(),
              let focused = Self.focusedElement(pid: pid) else { return false }
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
