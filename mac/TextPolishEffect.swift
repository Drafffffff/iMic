import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CoreText

private final class EffectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// Main-thread coordinator. Capture, AX queries, matching and OCR run off-main.
/// A visual failure always releases final delivery; it never authorizes an edit.
// Mutable coordinator state is confined to main; workers use immutable Target
// snapshots and the lock-protected cancellation token, returning via main.async.
final class TextPolishEffect: @unchecked Sendable {
    var onVisualFinished: (() -> Void)?
    var blocksGestures: Bool { lifecycle.blocksGestures }
    private(set) var didShowSweep = false
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "polishSweep") as? Bool ?? true
    }
    /// Uses generated text, never a screenshot or user content. Swift's lazy
    /// static initialization also serializes a first real request with warmup.
    static func prewarm() {
        guard enabled else { return }
        DispatchQueue.global(qos: .utility).async { _ = Self.ocrWarmup }
    }
    private static let ocrWarmup: Bool = {
        let start = ProcessInfo.processInfo.systemUptime
        guard let context = CGContext(data: nil, width: 384, height: 96, bitsPerComponent: 8,
                                      bytesPerRow: 384*4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 384, height: 96))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "iMic 语音输入 123", attributes: attributes))
        context.textPosition = CGPoint(x: 12, y: 30)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return false }
        let request = makeOCRRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            IMicLog.write("mac.effect", "ocr warmup ok lines=\(request.results?.count ?? 0) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000))")
            return true
        } catch {
            IMicLog.write("mac.effect", "ocr warmup unavailable")
            return false
        }
    }()
    private static func makeOCRRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        return request
    }
    private struct Target {
        let element: AXUIElement
        let windowID: CGWindowID
        let window: CGRect
        let field: CGRect
        let elementFrame: CGRect
        let textSignature: Int?
    }
    private let queue = DispatchQueue(label: "imic.polish-ocr", qos: .userInitiated)
    private var generation = 0
    private var cancellation: EffectCancellation?
    private var lifecycle = PolishEffectLifecycle()
    private var targetPID: pid_t?
    private var sweepView: SweepView?
    private var regions: [CGRect] = []
    private var originalText = ""
    private var matchedVisibleUnits: Double = 0
    private var releaseEndpoint: CGPoint?
    private var validationTarget: Target?
    private var delivery: (() -> Void)?
    private var allowed: (() -> Bool)?
    private var interrupted: (() -> Void)?
    private var deadline: DispatchWorkItem?
    private var animationEnd: DispatchWorkItem?
    private var eventMonitor: Any?
    private var appMonitor: NSObjectProtocol?
    private var panel: NSPanel?
    var phase: PolishEffectLifecycle.Phase { lifecycle.phase }

    func beginSession() { cancel(); lifecycle = PolishEffectLifecycle() }

    func prepare(pid: pid_t, element: AXUIElement?, text: String,
                 allowed: @escaping () -> Bool, interrupted: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        didShowSweep = false
        lifecycle.beginPreparation()
        targetPID = pid
        originalText = text
        self.allowed = allowed
        self.interrupted = interrupted
        guard Self.enabled, !text.isEmpty, allowed() else { lifecycle.skipVisual(); return }
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else {
            IMicLog.write("mac.effect", "skipped reason=capture_unavailable_or_permission")
            lifecycle.skipVisual(); return
        }
        let token = EffectCancellation()
        cancellation = token
        let version = generation
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != InputTarget.keyboardEventTag else { return }
            self?.userTookOver()
        }
        appMonitor = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != pid else { return }
            self?.userTookOver()
        }
        guard eventMonitor != nil else { lifecycle.skipVisual(); token.cancel(); return }
        queue.async { [weak self] in
            guard let self, !token.cancelled,
                  let target = Self.locate(pid: pid, element: element, expected: text, token: token) else {
                if !token.cancelled { IMicLog.write("mac.effect", "locate unavailable chars=\(text.count)") }
                DispatchQueue.main.async { self?.prepared([], generation: version) }
                return
            }
            IMicLog.write("mac.effect", "viewport clipped=\(!Self.same(target.elementFrame, target.field)) height=\(Int(target.field.height)) document_height=\(Int(target.elementFrame.height))")
            Task {
                do {
                    guard !token.cancelled else { return }
                    let image = try await Self.capture(target)
                    self.queue.async {
                        guard !token.cancelled, Self.valid(target) else {
                            DispatchQueue.main.async { self.prepared([], generation: version) }; return
                        }
                        let start = ProcessInfo.processInfo.systemUptime
                        let rectangles = Self.recognize(image, field: target.field, expected: text, token: token)
                        let unchanged = Self.valid(target)
                        let result = unchanged && !token.cancelled ? rectangles.rectangles : []
                        IMicLog.write("mac.effect", "ocr lines=\(result.count) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000))")
                        DispatchQueue.main.async { self.prepared(result, generation: version, target: target, visibleUnits: rectangles.visibleUnits) }
                    }
                } catch {
                    DispatchQueue.main.async { self.prepared([], generation: version) }
                }
            }
        }
    }

    /// Result selection is independent of OCR/intro. A fast result joins the
    /// intro already in flight; a slow one releases the held loading state.
    func deliverAfterSweep(_ completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard lifecycle.selectResult() else { return }
        delivery = completion
        if lifecycle.phase == .locating {
            let version = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == version, self.lifecycle.phase == .locating else { return }
                self.skipVisual(reason: "location_deadline")
            }
            deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
        beginDeliveryIfReady()
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation += 1
        cancellation?.cancel(); cancellation = nil
        deadline?.cancel(); deadline = nil
        animationEnd?.cancel(); animationEnd = nil
        panel?.orderOut(nil); panel = nil; sweepView = nil
        removeMonitors()
        lifecycle.cancel()
        regions = []; validationTarget = nil
        originalText = ""; matchedVisibleUnits = 0; releaseEndpoint = nil
        delivery = nil; allowed = nil; interrupted = nil; targetPID = nil
    }

    private func removeMonitors() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let appMonitor { NSWorkspace.shared.notificationCenter.removeObserver(appMonitor) }
        appMonitor = nil
    }

    private func userTookOver() {
        interrupted?()
        if lifecycle.phase == .writing || lifecycle.phase == .releasing {
            finishVisual()
        } else { skipVisual(reason: "user_takeover") }
    }

    private func skipVisual(reason: String) {
        cancellation?.cancel()
        deadline?.cancel(); deadline = nil
        animationEnd?.cancel(); animationEnd = nil
        panel?.orderOut(nil); panel = nil; sweepView = nil
        regions = []
        lifecycle.skipVisual()
        IMicLog.write("mac.effect", "skipped reason=\(reason)")
        beginDeliveryIfReady()
    }

    private func prepared(_ rectangles: [CGRect], generation version: Int, target: Target? = nil, visibleUnits: Double = 0) {
        guard generation == version, cancellation?.cancelled == false, lifecycle.phase == .locating else { return }
        regions = SweepLineLayout.rows(in: rectangles)
        validationTarget = target
        matchedVisibleUnits = visibleUnits
        guard !regions.isEmpty, allowed?() == true, let target else { skipVisual(reason: "no_matching_regions"); return }
        deadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version, self.lifecycle.phase == .locating else { return }
            self.skipVisual(reason: "geometry_deadline")
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: timeout)
        queue.async { [weak self] in
            let valid = Self.valid(target)
            DispatchQueue.main.async {
                guard let self, self.generation == version, self.lifecycle.phase == .locating else { return }
                self.deadline?.cancel(); self.deadline = nil
                if valid, self.allowed?() == true { self.startSweep() }
                else { self.skipVisual(reason: "geometry_changed") }
            }
        }
    }

    private func installPanel(regions: [CGRect], entering: Bool, endpoint: CGPoint? = nil) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let textUnion = regions.reduce(CGRect.null) { $0.union($1) }
        let anchored = endpoint.map { textUnion.union(CGRect(x: $0.x, y: $0.y, width: 1, height: 1)) } ?? textUnion
        let union = anchored.insetBy(dx: reduced ? -3 : -54, dy: reduced ? -3 : -54)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var rect = NSRect(x: union.minX, y: top-union.maxY, width: union.width, height: union.height)
        if !entering, let panel, let view = sweepView {
            let previous = panel.frame
            rect = rect.union(previous)
            panel.setFrame(rect, display: false)
            let offset = CGPoint(x: previous.minX-rect.minX, y: previous.minY-rect.minY)
            view.reframe(size: rect.size, offset: offset)
            let localRows = regions.map { CGRect(x: $0.minX-rect.minX, y: top-$0.maxY-rect.minY, width: $0.width, height: $0.height) }
            let localEnd = endpoint.map { CGPoint(x: $0.x-rect.minX, y: top-$0.y-rect.minY) }
            view.align(regions: localRows, endpoint: localEnd)
            return
        }
        let window = panel ?? SweepPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(rect, display: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = SweepView(frame: NSRect(origin: .zero, size: union.size))
        window.contentView = view
        view.install(regions: regions.map { CGRect(x: $0.minX-union.minX, y: union.maxY-$0.maxY, width: $0.width, height: $0.height) },
                     reduced: reduced, entering: entering)
        if let endpoint { view.setEndpoint(CGPoint(x: endpoint.x-union.minX, y: union.maxY-endpoint.y)) }
        sweepView = view; panel = window
        window.orderFrontRegardless()
    }

    private func startSweep() {
        guard lifecycle.visualPrepared() else { return }
        installPanel(regions: regions, entering: true)
        didShowSweep = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.12 : SweepLineLayout.duration(lineCount: regions.count)
        IMicLog.write("mac.effect", "sweep lines=\(regions.count) reduced=\(reduced) ms=\(Int(duration*1000)) resultReady=\(lifecycle.hasResult)")
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version, self.lifecycle.phase == .sweeping else { return }
            self.lifecycle.sweepFinished()
            self.sweepView?.hold()
            IMicLog.write("mac.effect", "holding resultReady=\(self.lifecycle.hasResult)")
            self.beginDeliveryIfReady()
            self.watchHeldGeometry(generation: version)
        }
        animationEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
    }

    private func watchHeldGeometry(generation version: Int) {
        guard lifecycle.phase == .holding, let target = validationTarget, let token = cancellation else { return }
        queue.asyncAfter(deadline: .now()+0.3) { [weak self] in
            guard let self, !token.cancelled else { return }
            let valid = Self.valid(target)
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .holding else { return }
                if valid { self.watchHeldGeometry(generation: version) }
                else { self.skipVisual(reason: "held_geometry_changed") }
            }
        }
    }

    private func beginDeliveryIfReady() {
        guard let callback = delivery, lifecycle.beginWriting() else { return }
        deadline?.cancel(); deadline = nil
        delivery = nil
        IMicLog.write("mac.effect", "writing overlay=\(panel != nil)")
        callback()
    }

    /// Called AFTER completeSession has resolved its input retries. Keep the
    /// loading layer through the handoff; an event-post return isn't a paint ACK.
    func finishDelivery(succeeded: Bool, finalText: String, verified: Bool) {
        precondition(Thread.isMainThread)
        guard lifecycle.phase == .writing else { return }
        guard succeeded, panel != nil, let pid = targetPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { finishVisual(); return }
        let version = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version else { return }
            self.reveal(source: "display_deadline_estimated", burst: self.releaseEndpoint != nil)
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now()+0.6, execute: timeout)
        guard let target = validationTarget, let token = cancellation else { reveal(source: "no_target", burst: false); return }
        let oldRows = regions, original = originalText, visibleUnits = matchedVisibleUnits
        // Read again after the editor has had time to reflow/auto-grow. All
        // passes share the existing 600ms visual deadline and cancellation.
        for (attempt, delay) in [0.0, 0.12, 0.28, 0.44].enumerated() {
            queue.asyncAfter(deadline: .now()+delay) { [weak self] in
                self?.refreshFinalLayout(target: target, pid: pid, finalText: finalText, verified: verified,
                                         oldRows: oldRows, original: original, visibleUnits: visibleUnits,
                                         token: token, version: version, attempt: attempt)
            }
        }
    }

    private func refreshFinalLayout(target: Target, pid: pid_t, finalText: String, verified: Bool,
                                    oldRows: [CGRect], original: String, visibleUnits: Double,
                                    token: EffectCancellation, version: Int, attempt: Int) {
        guard !token.cancelled else { return }
        let field = Self.visibleField(target.element, window: target.window) ?? target.field
        let estimate = PolishEndpointEstimate.endpoint(original: original, final: finalText,
                                                       rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
        let estimatedRows = PolishEndpointEstimate.layout(original: original, final: finalText,
                                                          rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
        DispatchQueue.main.async {
            guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
            self.releaseEndpoint = estimate
            if let estimate { self.installPanel(regions: estimatedRows.isEmpty ? oldRows : estimatedRows, entering: false, endpoint: estimate) }
        }
        // Some editors expose the new value before updating its line geometry.
        // Do not finalize on that first, stale AX layout immediately after write.
        if attempt >= 2, let rects = Self.finalRows(target: target, text: finalText) {
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
                self.releaseEndpoint = nil
                self.regions = SweepLineLayout.rows(in: rects)
                self.installPanel(regions: self.regions, entering: false)
                self.reveal(source: verified ? "confirmed_range_layout" : "readable_layout", burst: true)
            }
            return
        }
        guard attempt == 1 else { return }
        guard let fresh = Self.locate(pid: pid, element: target.element, expected: finalText, token: token) else { return }
        guard #available(macOS 14.0, *) else { return }
        Task {
            do {
                guard !token.cancelled else { return }
                let image = try await Self.capture(fresh)
                self.queue.async {
                    guard !token.cancelled else { return }
                    let geometry = Self.recognize(image, field: fresh.field, expected: finalText, token: token, requireTail: true)
                    let rects = geometry.rectangles
                    guard Self.valid(fresh) else { return }
                    DispatchQueue.main.async {
                        guard self.generation == version, self.lifecycle.phase == .writing,
                              !token.cancelled, !rects.isEmpty else { return }
                        self.releaseEndpoint = nil
                        self.regions = SweepLineLayout.rows(in: rects)
                        self.installPanel(regions: self.regions, entering: false)
                        self.reveal(source: "ocr_display_match", burst: true)
                    }
                }
            } catch { /* The visual-only deadline releases the hold. */ }
        }
    }

    private func reveal(source: String, burst: Bool) {
        guard targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              cancellation?.cancelled == false else { finishVisual(); return }
        guard lifecycle.beginRelease() else { return }
        deadline?.cancel(); deadline = nil
        IMicLog.write("mac.effect", "release source=\(source) burst=\(burst)")
        let duration = sweepView?.release(burst: burst) ?? 0.12
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version else { return }
            self.finishVisual()
        }
        animationEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
    }

    private func finishVisual() {
        cancellation?.cancel()
        deadline?.cancel(); deadline = nil
        animationEnd?.cancel(); animationEnd = nil
        panel?.orderOut(nil); panel = nil; sweepView = nil
        removeMonitors()
        regions = []; validationTarget = nil
        originalText = ""; matchedVisibleUnits = 0; releaseEndpoint = nil
        delivery = nil; allowed = nil; interrupted = nil
        lifecycle.finish()
        onVisualFinished?()
    }

    /// Layout refresh after writing, not permission to edit. If this target's
    /// range geometry is incomplete (e.g. Codex), use the OCR display check.
    private static func finalRows(target: Target, text: String) -> [CGRect]? {
        guard let value = read(target.element, kAXValueAttribute) as? String,
              let field = visibleField(target.element, window: target.window), !text.isEmpty else { return nil }
        let span = (value as NSString).range(of: text, options: .backwards)
        guard span.location != NSNotFound else { return nil }
        func parameter(_ name: String, _ input: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(target.element, name as CFString, input, &result) == .success ? result : nil
        }
        var cursor = span.location
        var result: [CGRect] = []
        var terminalVisible = false
        while cursor < NSMaxRange(span), result.count < 64 {
            guard let line = parameter(kAXLineForIndexParameterizedAttribute, NSNumber(value: cursor)),
                  let raw = parameter(kAXRangeForLineParameterizedAttribute, line),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let rangeValue = raw as! AXValue
            var lineRange = CFRange()
            guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &lineRange),
                  lineRange.location >= 0, lineRange.length > 0,
                  lineRange.location <= cursor, lineRange.length <= 100_000 else { return nil }
            let end = min(NSMaxRange(span), lineRange.location+lineRange.length)
            guard end > cursor else { return nil }
            var range = CFRange(location: cursor, length: end-cursor)
            guard let rangeParameter = AXValueCreate(.cfRange, &range),
                  let rawRect = parameter(kAXBoundsForRangeParameterizedAttribute, rangeParameter),
                  CFGetTypeID(rawRect) == AXValueGetTypeID() else { return nil }
            let rectValue = rawRect as! AXValue
            var rect = CGRect.zero
            guard AXValueGetType(rectValue) == .cgRect, AXValueGetValue(rectValue, .cgRect, &rect),
                  rect.width > 1, rect.height > 1 else { return nil }
            let visible = rect.intersection(field)
            if visible.width > 1, visible.height > 1 { result.append(visible) }
            if end == NSMaxRange(span) {
                terminalVisible = visible.width > 1 && visible.height >= rect.height*0.8
            }
            cursor = end
        }
        return cursor == NSMaxRange(span) && terminalVisible && !result.isEmpty ? result : nil
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let a = read(element, kAXPositionAttribute), let b = read(element, kAXSizeAttribute),
              CFGetTypeID(a) == AXValueGetTypeID(), CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        let av = a as! AXValue, bv = b as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(av) == .cgPoint, AXValueGetType(bv) == .cgSize,
              AXValueGetValue(av, .cgPoint, &point), AXValueGetValue(bv, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func visibleField(_ element: AXUIElement, window: CGRect) -> CGRect? {
        guard let content = frame(element) else { return nil }
        var clips: [CGRect] = []
        var parent = read(element, kAXParentAttribute)
        for _ in 0..<24 {
            guard let raw = parent, CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let ancestor = raw as! AXUIElement
            let role = read(ancestor, kAXRoleAttribute) as? String
            if role == kAXScrollAreaRole || role == "AXClipView" || role == kAXWindowRole,
               let rect = frame(ancestor), rect.width > 10, rect.height > 8 { clips.append(rect) }
            if role == kAXWindowRole { break }
            parent = read(ancestor, kAXParentAttribute)
        }
        return TextViewport.visible(content: content, window: window, clips: clips)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 && abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
    }
    private static func valid(_ target: Target) -> Bool {
        guard let current = frame(target.element), same(current, target.elementFrame),
              let visible = visibleField(target.element, window: target.window), same(visible, target.field) else { return false }
        if let signature = target.textSignature {
            return (read(target.element, kAXValueAttribute) as? String)?.hashValue == signature
        }
        return true
    }

    private static func locate(pid: pid_t, element: AXUIElement?, expected: String, token: EffectCancellation) -> Target? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var candidates: [AXUIElement] = []
        if let element { candidates.append(element) }
        if let focused = read(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() { candidates.append(focused as! AXUIElement) }
        let until = ProcessInfo.processInfo.systemUptime + 0.4
        var index = 0
        if let window = read(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() { candidates.append(window as! AXUIElement) }
        while index < candidates.count, index < 2_000, !token.cancelled, ProcessInfo.processInfo.systemUptime < until {
            let candidate = candidates[index]; index += 1
            AXUIElementSetMessagingTimeout(candidate, 0.06)
            let role = read(candidate, kAXRoleAttribute) as? String
            if role == "AXTextArea" || role == "AXTextField", let field = frame(candidate), field.width > 10, field.height > 8 {
                if read(candidate, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
                    || (read(candidate, "AXProtectedContent") as? Bool) == true { continue }
                // The captured focused element is preferred. Discovered fields must
                // actually contain a distinctive suffix of our emitted transcript.
                let captured = element.map { CFEqual($0, candidate) } ?? false
                let content = read(candidate, kAXValueAttribute) as? String ?? ""
                let suffix = String(expected.suffix(16))
                if captured || (!suffix.isEmpty && content.contains(suffix)) {
                    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    let matches: [(CGWindowID, CGRect)] = windows.compactMap { info in
                        guard info[kCGWindowOwnerPID as String] as? Int32 == pid,
                              info[kCGWindowLayer as String] as? Int == 0,
                              let id = info[kCGWindowNumber as String] as? UInt32,
                              let raw = info[kCGWindowBounds as String] as? NSDictionary,
                              let rect = CGRect(dictionaryRepresentation: raw), rect.intersects(field) else { return nil }
                        return (id, rect)
                    }
                    let owner = read(candidate, kAXWindowAttribute)
                    let ownerFrame = owner.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? frame($0 as! AXUIElement) : nil }
                    let window = matches.first(where: { item in ownerFrame.map { same($0, item.1) } ?? false })
                        ?? matches.min(by: { $0.1.width*$0.1.height < $1.1.width*$1.1.height })
                    if let window, let visible = visibleField(candidate, window: window.1) {
                        return Target(element: candidate, windowID: window.0, window: window.1, field: visible,
                                      elementFrame: field, textSignature: (read(candidate, kAXValueAttribute) as? String)?.hashValue)
                    }
                }
            }
            if let children = read(candidate, kAXChildrenAttribute) as? [AXUIElement] { candidates.append(contentsOf: children) }
        }
        return nil
    }

    @available(macOS 14.0, *)
    private static func capture(_ target: Target) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else { throw CaptureError.unavailable }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2_800 / max(target.window.width, target.window.height))
        configuration.width = max(1, Int(target.window.width * scale))
        configuration.height = max(1, Int(target.window.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        let sx = CGFloat(image.width) / target.window.width, sy = CGFloat(image.height) / target.window.height
        let crop = CGRect(x: (target.field.minX-target.window.minX)*sx, y: (target.field.minY-target.window.minY)*sy,
                          width: target.field.width*sx, height: target.field.height*sy).integral
        guard let result = image.cropping(to: crop) else { throw CaptureError.unavailable }
        return result
    }
    private enum CaptureError: Error { case unavailable }

    private struct RecognizedRegions {
        var rectangles: [CGRect] = []
        var visibleUnits: Double = 0
    }
    private static func recognize(_ image: CGImage, field: CGRect, expected: String, token: EffectCancellation, requireTail: Bool = false) -> RecognizedRegions {
        guard !token.cancelled else { return RecognizedRegions() }
        _ = ocrWarmup
        guard !token.cancelled else { return RecognizedRegions() }
        let request = makeOCRRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return RecognizedRegions() }
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY-$1.boundingBox.midY) > 0.015 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        if requireTail, TextRegionMatcher.match(expected: String(expected.suffix(24)), fragments: candidates.map(\.string),
                                               cancelled: { token.cancelled }) == nil { return RecognizedRegions() }
        guard let spans = TextRegionMatcher.match(expected: expected, fragments: candidates.map(\.string), cancelled: { token.cancelled }) else {
            if !token.cancelled { IMicLog.write("mac.effect", "ocr unmatched expected_chars=\(expected.count) fragments=\(candidates.count)") }
            return RecognizedRegions()
        }
        let visibleUnits = spans.reduce(0.0) { total, span in
            total+PolishEndpointEstimate.units(in: (candidates[span.fragment].string as NSString).substring(with: span.range))
        }
        let rectangles: [CGRect] = spans.compactMap { span in
            let candidate = candidates[span.fragment]
            guard let range = Range(span.range, in: candidate.string), let box = try? candidate.boundingBox(for: range) else { return nil }
            let r = box.boundingBox
            let result = CGRect(x: field.minX+r.minX*field.width, y: field.minY+(1-r.maxY)*field.height,
                                width: r.width*field.width, height: r.height*field.height).intersection(field)
            return result.width > 1 && result.height > 1 ? result : nil
        }
        return RecognizedRegions(rectangles: rectangles, visibleUnits: visibleUnits)
    }
}

private final class SweepPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SweepView: NSView {
    private let ember = NSColor(srgbRed: 1, green: 0.29, blue: 0, alpha: 1)
    private let white = NSColor.white
    private let black = NSColor.black
    private var rowRegions: [CGRect] = []
    private var reducedMotion = false
    private var introRoot: CALayer?
    private var loadingRoot: CALayer?
    private var endpoint: CGPoint?
    private var endpointCore: CALayer?
    private var rails: [CALayer] = []
    private var alignedAt: CFTimeInterval = 0

    func install(regions: [CGRect], reduced: Bool, entering: Bool = true) {
        wantsLayer = true
        guard let layer, !regions.isEmpty else { return }
        layer.masksToBounds = false
        rowRegions = regions; reducedMotion = reduced
        if !entering || reduced { hold(); return }
        let intro = CALayer(); intro.frame = bounds
        layer.addSublayer(intro); introRoot = intro
        let time = CACurrentMediaTime()
        for (row, rect) in regions.enumerated() {
            installLine(rect, on: intro, time: time+SweepLineLayout.delay(row: row, lineCount: regions.count))
        }
    }

    private func block(_ rect: CGRect, _ color: NSColor) -> CALayer {
        let node = CALayer(); node.frame = rect; node.backgroundColor = color.cgColor
        return node
    }

    /// A small white stop stays below the baseline, without a crossing reticle.
    private func lock(at point: CGPoint) -> CALayer {
        let node = CALayer(); node.bounds = CGRect(x: 0, y: 0, width: 4, height: 9); node.position = point
        node.addSublayer(block(node.bounds, black))
        node.addSublayer(block(CGRect(x: 1, y: 1, width: 2, height: 7), white))
        return node
    }

    private func rail(for rect: CGRect) -> CALayer {
        let node = CALayer(); node.bounds = CGRect(x: 0, y: 0, width: rect.width, height: 4)
        node.anchorPoint = CGPoint(x: 0, y: 0.5)
        node.position = CGPoint(x: rect.minX, y: rect.minY-2)
        node.addSublayer(block(CGRect(x: 0, y: 0, width: rect.width, height: 3), black))
        node.addSublayer(block(CGRect(x: 0, y: 1, width: rect.width, height: 1), white))
        let length = min(24, rect.width*0.25)
        node.addSublayer(block(CGRect(x: max(0, rect.width-length), y: 0, width: length, height: 3), ember))
        return node
    }

    private func installLine(_ rect: CGRect, on root: CALayer, time: CFTimeInterval) {
        let track = rail(for: rect); root.addSublayer(track)
        let signal = CAKeyframeAnimation(keyPath: "opacity")
        signal.values = [0, 1, 1, 0]; signal.keyTimes = [0, 0.08, 0.85, 1]
        signal.duration = SweepLineLayout.lineDuration; signal.beginTime = time
        track.opacity = 0; track.add(signal, forKey: "rail-arm")

        let clip = CALayer(); clip.frame = rect.insetBy(dx: -2, dy: -4); clip.masksToBounds = true
        root.addSublayer(clip)
        let width = min(66, max(28, rect.width*0.12))
        let carriage = CALayer(); carriage.bounds = CGRect(x: 0, y: 0, width: width, height: clip.bounds.height)
        carriage.position = CGPoint(x: -width/2, y: clip.bounds.midY)
        // Opaque plates and narrow gaps replace the old blurred gradient tail.
        carriage.addSublayer(block(CGRect(x: width-8, y: 0, width: 8, height: clip.bounds.height), black))
        carriage.addSublayer(block(CGRect(x: width-5, y: 1, width: 3, height: clip.bounds.height-2), white))
        for i in 0..<3 {
            let length = width*CGFloat(3-i)/6
            carriage.addSublayer(block(CGRect(x: width-12-length, y: CGFloat(i)*5+3,
                                             width: length, height: i == 0 ? 4 : 2), i == 1 ? white : ember))
        }
        clip.addSublayer(carriage)
        let travel = CAKeyframeAnimation(keyPath: "position.x")
        travel.values = [-width/2, -width/2+3, clip.bounds.width+width/2, clip.bounds.width+width/2]
        travel.keyTimes = [0, 0.12, 0.8, 1]
        travel.timingFunctions = [CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1),
                                 CAMediaTimingFunction(name: .linear)]
        travel.duration = 0.245; travel.beginTime = time
        travel.fillMode = .forwards; travel.isRemovedOnCompletion = false
        carriage.add(travel, forKey: "heavy-scan")

        let stop = lock(at: CGPoint(x: rect.maxX, y: rect.midY)); root.addSublayer(stop); stop.opacity = 0
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.x")
        squash.values = [1.7, 0.55, 1]; squash.keyTimes = [0, 0.3, 1]
        let hit = CAKeyframeAnimation(keyPath: "opacity"); hit.values = [1, 1, 1]; hit.keyTimes = [0, 0.3, 1]
        squash.duration = 0.075; hit.duration = 0.075
        let impact = CAAnimationGroup(); impact.animations = [squash, hit]
        impact.beginTime = time+0.245; impact.duration = 0.075
        impact.fillMode = .forwards; impact.isRemovedOnCompletion = false
        stop.add(impact, forKey: "mechanical-stop")
    }

    func setEndpoint(_ point: CGPoint) {
        endpoint = point
        // Estimated and actual layouts can re-anchor the lock without a flyover
        // across unrelated text. The controller owns the screen coordinates.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        endpointCore?.position = point
        CATransaction.commit()
    }

    func hold() {
        guard loadingRoot == nil, let layer else { return }
        introRoot?.removeFromSuperlayer(); introRoot = nil
        let loading = CALayer(); loading.frame = bounds
        layer.addSublayer(loading); loadingRoot = loading
        for (index, rect) in rowRegions.enumerated() {
            let line = rail(for: rect); rails.append(line); loading.addSublayer(line)
            guard index == rowRegions.count-1 else { continue }
            let core = lock(at: endpoint ?? CGPoint(x: rect.maxX, y: rect.midY))
            loading.addSublayer(core); endpointCore = core
            // A restrained three-step status cadence, not a flashing text box.
            for i in 0..<3 {
                let cell = block(CGRect(x: -7-CGFloat(i)*5, y: -5, width: 3, height: 3), i == 0 ? ember : white)
                core.addSublayer(cell)
                guard !reducedMotion else { continue }
                cell.opacity = 0.25
                let step = CAKeyframeAnimation(keyPath: "opacity")
                step.values = [0.25, 1, 1, 0.25]; step.keyTimes = [0, 0.15, 0.45, 1]
                step.calculationMode = .discrete; step.duration = 1.2; step.repeatCount = .infinity
                step.beginTime = CACurrentMediaTime()+Double(i)*0.16
                cell.add(step, forKey: "status-step")
            }
        }
    }

    func reframe(size: CGSize, offset: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame.size = size
        if let root = loadingRoot {
            for child in root.sublayers ?? [] {
                let previous = child.presentation()?.position ?? child.position
                child.position = CGPoint(x: previous.x+offset.x, y: previous.y+offset.y)
                child.removeAnimation(forKey: "align-position")
            }
            root.frame = bounds
        }
        rowRegions = rowRegions.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
        CATransaction.commit()
    }

    func align(regions: [CGRect], endpoint: CGPoint?) {
        guard let loading = loadingRoot, let last = regions.last else { return }
        let duration = reducedMotion ? 0 : 0.18
        func move(_ node: CALayer, from position: CGPoint) {
            guard duration > 0 else { return }
            let motion = CABasicAnimation(keyPath: "position")
            motion.fromValue = NSValue(point: position); motion.toValue = NSValue(point: node.position)
            motion.duration = duration; motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            node.add(motion, forKey: "align-position")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var next: [CALayer] = []
        for (index, rect) in regions.enumerated() {
            let old = index < rails.count ? rails[index] : nil
            let previous = old?.presentation() ?? old
            let start = previous?.position ?? CGPoint(x: rect.minX, y: rect.minY-2)
            let width = previous.map { $0.bounds.width * $0.transform.m11 } ?? 1
            let line = rail(for: rect); loading.addSublayer(line); next.append(line)
            move(line, from: start)
            if duration > 0 {
                let resize = CABasicAnimation(keyPath: "transform.scale.x")
                resize.fromValue = max(0.001, width/max(1, rect.width)); resize.toValue = 1
                resize.duration = duration; resize.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                line.add(resize, forKey: "align-width")
            }
        }
        // Removed rows contract to their start rather than leaving the old tail.
        for (index, old) in rails.enumerated() {
            if index < regions.count || duration == 0 { old.removeFromSuperlayer(); continue }
            let collapse = CABasicAnimation(keyPath: "transform.scale.x")
            collapse.fromValue = old.presentation()?.transform.m11 ?? 1; collapse.toValue = 0.001
            collapse.duration = duration; old.transform = CATransform3DMakeScale(0.001, 1, 1)
            old.add(collapse, forKey: "removed-row")
            DispatchQueue.main.asyncAfter(deadline: .now()+duration) { old.removeFromSuperlayer() }
        }
        rails = next; rowRegions = regions; self.endpoint = endpoint
        if let core = endpointCore {
            let start = core.presentation()?.position ?? core.position
            core.position = endpoint ?? CGPoint(x: last.maxX, y: last.midY)
            move(core, from: start)
        }
        alignedAt = CACurrentMediaTime()+duration
        CATransaction.commit()
    }

    @discardableResult
    func release(burst: Bool) -> TimeInterval {
        guard let layer else { return 0.12 }
        let delay = reducedMotion ? 0 : max(0, alignedAt-CACurrentMediaTime())
        if let loading = loadingRoot {
            loading.opacity = 0
            let cut = CABasicAnimation(keyPath: "opacity"); cut.fromValue = 1; cut.toValue = 0; cut.duration = 0.07
            cut.beginTime = CACurrentMediaTime()+delay; cut.fillMode = .backwards
            loading.add(cut, forKey: "loading-cut")
        }
        guard burst, !reducedMotion, let rect = rowRegions.last else { return delay+0.12 }
        let origin = endpoint ?? CGPoint(x: rect.maxX, y: rect.midY)
        let time = CACurrentMediaTime()+delay
        let core = lock(at: origin); layer.addSublayer(core); core.opacity = 0
        let press = CAKeyframeAnimation(keyPath: "transform.scale.x")
        press.values = [1, 0.35, 2.2, 0.1]; press.keyTimes = [0, 0.22, 0.42, 1]
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [1, 1, 1, 0]; light.keyTimes = [0, 0.22, 0.5, 1]
        press.duration = 0.2; light.duration = 0.2
        let snap = CAAnimationGroup(); snap.animations = [press, light]
        snap.duration = 0.2; snap.beginTime = time
        core.add(snap, forKey: "lock-release")

        // Directed flat shards: a few deliberate rays carry more weight than
        // a cloud of dust. Opaque black keylines preserve contrast on any theme.
        for index in 0..<12 {
            let angle = CGFloat(index)*(.pi*2/12) + .pi/12
            let distance: CGFloat = index % 3 == 0 ? 40 : 25
            let ray = CALayer(); ray.bounds = CGRect(x: 0, y: 0, width: index % 3 == 0 ? 15 : 8, height: 5)
            ray.position = origin; ray.opacity = 0
            ray.addSublayer(block(ray.bounds, black))
            ray.addSublayer(block(ray.bounds.insetBy(dx: 1, dy: 1), index % 3 == 0 ? ember : white))
            ray.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            layer.addSublayer(ray)
            let travel = CABasicAnimation(keyPath: "position")
            travel.fromValue = NSValue(point: origin)
            travel.toValue = NSValue(point: CGPoint(x: origin.x+cos(angle)*distance, y: origin.y+sin(angle)*distance*0.8))
            travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            let scale = CAKeyframeAnimation(keyPath: "transform.scale.x")
            scale.values = [0.3, 1, 0.15]; scale.keyTimes = [0, 0.2, 1]
            let cut = CAKeyframeAnimation(keyPath: "opacity")
            cut.values = [0, 1, 1, 0]; cut.keyTimes = [0, 0.05, 0.65, 1]
            for animation in [travel, scale, cut] { animation.duration = 0.17 }
            let group = CAAnimationGroup(); group.animations = [travel, scale, cut]
            group.beginTime = time+0.045; group.duration = 0.17
            ray.add(group, forKey: "directed-shard")
        }
        return delay+0.23
    }
}
