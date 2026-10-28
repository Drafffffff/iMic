import AppKit
import ApplicationServices
import ScreenCaptureKit

// Real-app polish sweep self-test. Built by scripts/test-polish-apps.sh as a
// separate bundle signed like iMic, so it reuses iMic's Accessibility and Screen
// Recording grants. It only types into the test document the script opened,
// never presses Return, and records screenshots plus the effect's own log.

struct Options {
    var out = URL(fileURLWithPath: "/tmp/imic-polish-apps")
    var name = "case"
    var keys: [String] = []
    var typed = ""
    var final = ""
    var cleanup: [String] = []

    init(_ arguments: [String]) {
        func decode(_ value: String) -> String {
            Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "--out": out = URL(fileURLWithPath: parts[1])
            case "--name": name = parts[1]
            case "--keys": keys = parts[1].split(separator: ",").map(String.init)
            case "--type-b64": typed = decode(parts[1])
            case "--final-b64": final = decode(parts[1])
            case "--cleanup": cleanup = parts[1].split(separator: ",").map(String.init)
            default: break
            }
        }
    }
}

let options = Options(CommandLine.arguments)
let startedAt = Date()
var result: [String: Any] = ["name": options.name]
var phases: [String] = []

func finish(_ status: String) {
    result["status"] = status
    result["phases"] = phases
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let since = formatter.string(from: startedAt.addingTimeInterval(-0.05))
    let log = (try? String(contentsOf: IMicLog.fileURL, encoding: .utf8)) ?? ""
    result["effect"] = log.split(separator: "\n").filter { line in
        line.contains("[mac.effect]") && String(line.prefix(24)) >= String(since.prefix(24))
    }.map { String($0.dropFirst(25)) }
    try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: options.out.appendingPathComponent("\(options.name).json"))
    }
    exit(status == "ok" ? 0 : 1)
}

// MARK: - Keyboard

let keyCodes: [String: CGKeyCode] = [
    "left": 123, "right": 124, "down": 125, "up": 126, "delete": 51, "home": 115, "end": 119,
    "escape": 53, "a": 0, "c": 8, "e": 14, "k": 40, "s": 1, "u": 32, "w": 13, "space": 49, "tab": 48
]

func post(_ token: String, pid: pid_t) {
    var name = token, repeatCount = 1
    if let star = token.firstIndex(of: "*") {
        name = String(token[..<star]); repeatCount = Int(token[token.index(after: star)...]) ?? 1
    }
    var flags = CGEventFlags()
    let parts = name.split(separator: "+").map(String.init)
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "alt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        default: break
        }
    }
    guard let key = parts.last, let code = keyCodes[key], key != "return" else { return }
    let source = CGEventSource(stateID: .privateState)
    source?.userData = InputTarget.keyboardEventTag
    for _ in 0..<repeatCount {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        usleep(name == "delete" ? 3_000 : 25_000)
    }
}

func deleteBackward(_ count: Int, pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    source?.userData = InputTarget.keyboardEventTag
    for _ in 0..<count {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
            event.flags = []
            event.postToPid(pid)
        }
        usleep(4_000)
    }
}

func type(_ text: String, pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    source?.userData = InputTarget.keyboardEventTag
    var chunk = ""
    func flush() {
        guard !chunk.isEmpty else { return }
        let units = Array(chunk.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.postToPid(pid)
        }
        chunk = ""
        usleep(12_000)
    }
    for character in text {
        // Line breaks go through as their own event, like iMic's own delivery.
        if character == "\n" { flush(); chunk = "\r"; flush(); continue }
        if chunk.utf16.count + String(character).utf16.count > 20 { flush() }
        chunk.append(character)
    }
    flush()
}

// MARK: - Accessibility ground truth

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func rect(of value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func focused(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    if let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
        return (value as! AXUIElement)
    }
    // Electron publishes its tree only after AXManualAccessibility is requested.
    guard AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success else { return nil }
    usleep(300_000)
    guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Caret position from the editor, when it exposes one: end of the character
/// before the insertion point (or start of the one after it).
func caret(_ element: AXUIElement) -> CGPoint? {
    guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
        return TextMarkerGeometry.caretPoint(element: element)
    }
    var range = CFRange()
    guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
    func bounds(_ location: Int) -> CGRect? {
        var probe = CFRange(location: location, length: 1)
        guard location >= 0, let value = AXValueCreate(.cfRange, &probe) else { return nil }
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &output) == .success else { return nil }
        return rect(of: output).flatMap { $0.width >= 0 && $0.height > 1 ? $0 : nil }
    }
    if let before = bounds(range.location-1), before.width > 0 { return CGPoint(x: before.maxX, y: before.midY) }
    if let after = bounds(range.location), after.width > 0 { return CGPoint(x: after.minX, y: after.midY) }
    return TextMarkerGeometry.caretPoint(element: element)
}

/// Focus the first text field inside the window's web area.
func focusWebField(_ pid: pid_t) -> Bool {
    guard let window = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
          CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
    var queue: [AXUIElement] = [window as! AXUIElement]
    var insideWeb = Set<Int>()
    var index = 0
    while index < queue.count, index < 4000 {
        let node = queue[index]; index += 1
        let role = attribute(node, kAXRoleAttribute) as? String
        let web = role == "AXWebArea" || insideWeb.contains(index-1)
        if web, role == "AXTextArea" || role == "AXTextField" {
            return AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if web { insideWeb.insert(queue.count) }
            queue.append(child)
        }
    }
    return false
}

/// Step-by-step marker probe: which call in the text-marker walk answers.
func markerSteps(_ element: AXUIElement, pid: pid_t) -> [String: Any] {
    var steps: [String: Any] = [:]
    func param(_ target: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(target, name as CFString, input, &value)
        steps[name] = error == .success ? String(describing: CFCopyTypeIDDescription(CFGetTypeID(value!))) : "error \(error.rawValue)"
        return error == .success ? value : nil
    }
    var raw: CFTypeRef?
    let selectionError = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &raw)
    steps["selection.element"] = selectionError == .success ? "ok" : "error \(selectionError.rawValue)"
    var host = element
    if selectionError != .success {
        // Chromium keeps the selection on the web area; try ancestors.
        var parent = attribute(element, kAXParentAttribute)
        for _ in 0..<30 {
            guard let candidate = parent, CFGetTypeID(candidate) == AXUIElementGetTypeID() else { break }
            let node = candidate as! AXUIElement
            if AXUIElementCopyAttributeValue(node, "AXSelectedTextMarkerRange" as CFString, &raw) == .success {
                steps["selection.host"] = attribute(node, kAXRoleAttribute) as? String ?? "?"
                host = node; break
            }
            parent = attribute(node, kAXParentAttribute)
        }
    }
    guard let selection = raw, CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return steps }
    let caret = AXTextMarkerRangeCopyEndMarker(selection as! AXTextMarkerRange)
    if let previous = param(host, "AXPreviousTextMarkerForTextMarker", caret), CFGetTypeID(previous) == AXTextMarkerGetTypeID() {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, previous as! AXTextMarker, caret)
        if let value = param(host, "AXBoundsForTextMarkerRange", range), let r = rect(of: value) { steps["caretRect"] = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }
        _ = param(host, "AXLineTextMarkerRangeForTextMarker", previous)
        steps["string"] = param(host, "AXStringForTextMarkerRange", range) as? String ?? "-"
        steps["length"] = (param(host, "AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue ?? -1
    }
    return steps
}

// MARK: - Screenshots

@available(macOS 14.0, *)
func snapshot(_ region: CGRect, _ label: String) {
    Task {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(region) }) ?? content.displays.first
        else { return }
        let bounds = CGDisplayBounds(display.displayID)
        let local = region.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        guard local.width > 4, local.height > 4 else { return }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = Int(local.width*2); configuration.height = Int(local.height*2)
        configuration.showsCursor = false
        configuration.scalesToFit = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return }
        let url = options.out.appendingPathComponent("\(options.name)-\(label).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Run

func run() {
    guard AXIsProcessTrusted() else { result["error"] = "accessibility_not_granted"; finish("error"); return }
    guard let front = NSWorkspace.shared.frontmostApplication else { finish("error"); return }
    let pid = front.processIdentifier
    result["app"] = front.bundleIdentifier ?? front.localizedName ?? "?"
    result["capture"] = CGPreflightScreenCaptureAccess()
    for key in options.keys {
        if key == "focus-web" { result["focusWeb"] = focusWebField(pid); usleep(300_000) }
        else if key.hasPrefix("pretype:") {
            type(Data(base64Encoded: String(key.dropFirst(8))).flatMap { String(data: $0, encoding: .utf8) } ?? "", pid: pid)
        } else { post(key, pid: pid) }
    }
    usleep(150_000)
    type(options.typed, pid: pid)
    usleep(450_000)

    guard let element = focused(pid) else { result["error"] = "no_focused_element"; finish("error"); return }
    result["role"] = attribute(element, kAXRoleAttribute) as? String ?? "?"
    result["subrole"] = attribute(element, kAXSubroleAttribute) as? String ?? ""
    let field = frame(element) ?? .zero
    result["field"] = [Int(field.minX), Int(field.minY), Int(field.width), Int(field.height)]
    // Capability probe: which text-geometry APIs this editor answers.
    func probe(_ element: AXUIElement) -> [String: Any] {
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        let value = attribute(element, kAXValueAttribute) as? String ?? ""
        let location = (value as NSString).range(of: options.typed, options: .backwards).location
        var info: [String: Any] = ["params": (names as? [String]) ?? [], "valueChars": value.count,
                                   "valueHasTyped": location != NSNotFound]
        if location != NSNotFound {
            var number: CFTypeRef?
            info["lineForIndex"] = AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                                                                               NSNumber(value: location) as CFTypeRef, &number) == .success
            var range = CFRange(location: location, length: 1)
            var output: CFTypeRef?
            if let parameter = AXValueCreate(.cfRange, &range),
               AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &output) == .success,
               let bounds = rect(of: output) {
                info["boundsFirstChar"] = [Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)]
            }
        }
        return info
    }
    result["probe"] = probe(element)
    result["markerSteps"] = markerSteps(element, pid: pid)
    if ProcessInfo.processInfo.environment["IMIC_PROBE_ENHANCED"] != nil || CommandLine.arguments.contains("--probe-enhanced") {
        let app = AXUIElementCreateApplication(pid)
        var before: CFTypeRef?
        AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &before)
        result["enhancedBefore"] = (before as? Bool) ?? "unset"
        result["enhancedSet"] = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success
        usleep(600_000)
        if let refreshed = focused(pid) { result["markerStepsEnhanced"] = markerSteps(refreshed, pid: pid) }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }
    let application = AXUIElementCreateApplication(pid)
    result["manualAX"] = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    usleep(250_000)
    if let refreshed = focused(pid) { result["probeAfterManual"] = probe(refreshed) }
    let typedCaret = caret(element)
    result["caretTyped"] = typedCaret.map { [Int($0.x), Int($0.y)] } ?? []
    // Screenshot region: the field, or a band around the caret for big editors.
    var region = field.insetBy(dx: -40, dy: -30)
    if region.width > 1100 || region.height > 520 || region.isEmpty, let point = typedCaret {
        region = CGRect(x: point.x-620, y: point.y-170, width: 900, height: 300)
    }

    let target = InputTarget.capture(pid: pid)
    let effect = TextPolishEffect()
    effect.beginSession()
    effect.prepare(pid: pid, element: target.visualElement, text: options.typed,
                   allowed: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                   interrupted: { phases.append("interrupted") })
    var last = ""
    var shots = Set<String>()
    var wrote: Date?
    let timer = Timer(timeInterval: 0.015, repeats: true) { _ in
        let phase = "\(effect.phase)"
        if phase != last { phases.append(phase); last = phase }
        if #available(macOS 14.0, *) {
            if phase == "holding", !shots.contains("hold") { shots.insert("hold"); snapshot(region, "hold") }
            if let wrote, Date().timeIntervalSince(wrote) > 0.3, !shots.contains("final") { shots.insert("final"); snapshot(region, "final") }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    if #available(macOS 14.0, *) {
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { snapshot(region, "sweep") }
    }
    // The polished result arrives after the intro, like a typical DeepSeek reply.
    DispatchQueue.main.asyncAfter(deadline: .now()+0.9) {
        effect.deliverAfterSweep {
            // Deletes go to the same process queue as the typing, then settle, so
            // the two streams cannot interleave (iMic's own revisions are ordered too).
            deleteBackward(options.typed.count, pid: pid)
            usleep(250_000)
            type(options.final, pid: pid)
            wrote = Date()
            DispatchQueue.main.asyncAfter(deadline: .now()+0.06) {
                effect.finishDelivery(succeeded: true, finalText: options.final, verified: false)
            }
        }
    }
    func end() {
        // Leave 2s after the final text for reflow, final layout and release.
        if let wrote, Date().timeIntervalSince(wrote) < 2.0 || effect.phase == .writing && Date().timeIntervalSince(wrote) < 3.0 {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { end() }; return
        }
        if wrote == nil, Date().timeIntervalSince(startedAt) < 8 { DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { end() }; return }
        timer.invalidate()
        if let element = focused(pid), let point = caret(element) { result["caretFinal"] = [Int(point.x), Int(point.y)] }
        options.cleanup.forEach { post($0, pid: pid) }
        effect.cancel()
        finish("ok")
    }
    DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { end() }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { run() }
app.run()
