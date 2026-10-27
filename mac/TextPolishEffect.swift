import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CoreText
import CoreImage

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
    /// Vision ignores text shorter than 1/32 of the image by default. Tall text
    /// areas and window-wide fallback crops put ordinary 12pt text below that,
    /// so the floor is set from pixels instead (about 4pt at the 2x capture).
    private static func makeOCRRequest(imageHeight: Int = 0) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        if imageHeight > 0 { request.minimumTextHeight = Float(min(1.0/32, 8/Double(imageHeight))) }
        return request
    }
    private static let imageContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Second OCR pass: grey, higher contrast, dark themes inverted to dark-on-
    /// light, small crops enlarged. Normalised coordinates are unchanged.
    private static func enhanced(_ image: CGImage) -> CGImage? {
        var input = CIImage(cgImage: image)
        let extent = input.extent
        var luminance: CGFloat = 1
        if let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: extent)])?.outputImage {
            var pixel = [UInt8](repeating: 0, count: 4)
            imageContext.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            luminance = (0.299*CGFloat(pixel[0])+0.587*CGFloat(pixel[1])+0.114*CGFloat(pixel[2]))/255
        }
        input = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.45])
        if luminance < 0.45 { input = input.applyingFilter("CIColorInvert") }
        if extent.height < 900 {
            input = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.6, kCIInputAspectRatioKey: 1])
        }
        return imageContext.createCGImage(input, from: input.extent)
    }
    private struct Target {
        let element: AXUIElement
        let windowID: CGWindowID
        let window: CGRect
        let field: CGRect
        let elementFrame: CGRect
        let singleLine: Bool
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
        guard Self.enabled, !text.isEmpty, allowed() else {
            IMicLog.write("mac.effect", "skipped reason=ineligible enabled=\(Self.enabled) chars=\(text.count)")
            lifecycle.skipVisual(); return
        }
        // AX range geometry needs no screen recording; OCR is only a fallback tier.
        let canCapture: Bool
        if #available(macOS 14.0, *) { canCapture = CGPreflightScreenCaptureAccess() } else { canCapture = false }
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
            IMicLog.write("mac.effect", "viewport clipped=\(!Self.same(target.elementFrame, target.field)) height=\(Int(target.field.height)) document_height=\(Int(target.elementFrame.height)) single_line=\(target.singleLine)")
            // Tier 1: the editor's own line geometry. Exact, fast, permission-free.
            if let layout = Self.rangeLayout(target: target, text: text) {
                IMicLog.write("mac.effect", "locate source=ax_range lines=\(layout.rows.count)")
                DispatchQueue.main.async { self.prepared(layout.rows, generation: version, target: target, visibleUnits: layout.visibleUnits) }
                return
            }
            // Tier 3: a single-line field without usable ranges or OCR still has a
            // reliable vertical centre; estimate the row instead of skipping.
            let estimate = { () -> Void in
                guard target.singleLine,
                      let row = SweepLineLayout.singleLineEstimate(field: target.field, text: text) else {
                    DispatchQueue.main.async { self.prepared([], generation: version) }; return
                }
                IMicLog.write("mac.effect", "locate source=field_estimate")
                DispatchQueue.main.async { self.prepared([row], generation: version, target: target) }
            }
            guard canCapture, #available(macOS 14.0, *) else {
                IMicLog.write("mac.effect", "ocr skipped reason=capture_permission")
                estimate(); return
            }
            // Tier 2: OCR of the field (or window) with an enhanced retry.
            Task {
                do {
                    guard !token.cancelled else { return }
                    let image = try await Self.capture(target)
                    self.queue.async {
                        guard !token.cancelled, Self.valid(target) else {
                            DispatchQueue.main.async { self.prepared([], generation: version) }; return
                        }
                        let start = ProcessInfo.processInfo.systemUptime
                        let rectangles = Self.recognize(image, field: target.field, expected: text, token: token,
                                                        allowClipped: target.singleLine, fieldScoped: true)
                        let unchanged = Self.valid(target)
                        let result = unchanged && !token.cancelled ? rectangles.rectangles : []
                        IMicLog.write("mac.effect", "ocr lines=\(result.count) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000))")
                        if result.isEmpty, unchanged, !token.cancelled { estimate(); return }
                        DispatchQueue.main.async { self.prepared(result, generation: version, target: target, visibleUnits: rectangles.visibleUnits) }
                    }
                } catch {
                    estimate()
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
        regions = SweepLineLayout.lines(in: rectangles)
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
            view.align(regions: localRows, paragraphEnds: SweepLineLayout.paragraphEnds(regions), endpoint: localEnd)
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
                     paragraphEnds: SweepLineLayout.paragraphEnds(regions), reduced: reduced, entering: entering)
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
        if !target.singleLine {
            let estimate = PolishEndpointEstimate.endpoint(original: original, final: finalText,
                                                           rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
            let estimatedRows = PolishEndpointEstimate.layout(original: original, final: finalText,
                                                              rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
                self.releaseEndpoint = estimate
                if let estimate { self.installPanel(regions: estimatedRows.isEmpty ? oldRows : estimatedRows, entering: false, endpoint: estimate) }
            }
        }
        // Some editors expose the new value before updating its line geometry.
        // Do not finalize on that first, stale AX layout immediately after write.
        // Single-line fields qualify too: rangeLayout requires a visible tail.
        if attempt >= 2, let rects = Self.finalRows(target: target, text: finalText) {
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
                self.releaseEndpoint = nil
                self.regions = SweepLineLayout.lines(in: rects)
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
                    let geometry = Self.recognize(image, field: fresh.field, expected: finalText, token: token, requireTail: true,
                                                  allowClipped: fresh.singleLine, fieldScoped: true)
                    let rects = geometry.rectangles
                    guard Self.valid(fresh) else { return }
                    DispatchQueue.main.async {
                        guard self.generation == version, self.lifecycle.phase == .writing,
                              !token.cancelled, !rects.isEmpty else { return }
                        self.releaseEndpoint = nil
                        self.regions = SweepLineLayout.lines(in: rects)
                        self.installPanel(regions: self.regions, entering: false)
                        self.reveal(source: "ocr_display_match", burst: geometry.includesEnd)
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
        rangeLayout(target: target, text: text)?.rows
    }

    /// Visible line rectangles of the last occurrence of `text`, read from the
    /// editor's AX line ranges. Rejects geometry that is incomplete, hidden at
    /// the tail, or implausible (duplicated or field-sized rectangles).
    private static func rangeLayout(target: Target, text: String) -> (rows: [CGRect], visibleUnits: Double)? {
        let element = target.element
        guard let value = read(element, kAXValueAttribute) as? String,
              let field = visibleField(element, window: target.window), !text.isEmpty else { return nil }
        let span = (value as NSString).range(of: text, options: .backwards)
        guard span.location != NSNotFound else { return nil }
        func parameter(_ name: String, _ input: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &result) == .success ? result : nil
        }
        var cursor = span.location
        var result: [CGRect] = []
        var terminalVisible = false
        var visibleUnits = 0.0
        var seen = Set<[Int]>()
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
            // Some editors answer every range with the element or one stale line box.
            let key = [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)]
            guard seen.insert(key).inserted, rect.height <= max(64, field.height*0.5) || target.singleLine,
                  !same(rect, target.elementFrame) else { return nil }
            let visible = rect.intersection(field)
            if visible.width > 1, visible.height > 1 {
                result.append(visible)
                visibleUnits += PolishEndpointEstimate.units(in: (value as NSString).substring(with: NSRange(location: cursor, length: end-cursor)))
            }
            if end == NSMaxRange(span) {
                terminalVisible = visible.width > 1 && visible.height >= rect.height*0.8
            }
            cursor = end
        }
        return cursor == NSMaxRange(span) && terminalVisible && !result.isEmpty ? (result, visibleUnits) : nil
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
                                      elementFrame: field, singleLine: role == kAXTextFieldRole || (read(candidate, "AXMultiline") as? Bool) == false, textSignature: (read(candidate, kAXValueAttribute) as? String)?.hashValue)
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
        var includesEnd = false
    }
    private static func recognize(_ image: CGImage, field: CGRect, expected: String, token: EffectCancellation,
                                  requireTail: Bool = false, allowClipped: Bool = false, fieldScoped: Bool = false) -> RecognizedRegions {
        guard !token.cancelled else { return RecognizedRegions() }
        _ = ocrWarmup
        let first = recognizePass(image, field: field, expected: expected, token: token, requireTail: requireTail,
                                  allowClipped: allowClipped, fieldScoped: fieldScoped, pass: 1)
        guard first.rectangles.isEmpty, !token.cancelled, let retry = enhanced(image) else { return first }
        return recognizePass(retry, field: field, expected: expected, token: token, requireTail: requireTail,
                             allowClipped: allowClipped, fieldScoped: fieldScoped, pass: 2)
    }

    private static func recognizePass(_ image: CGImage, field: CGRect, expected: String, token: EffectCancellation,
                                      requireTail: Bool, allowClipped: Bool, fieldScoped: Bool, pass: Int) -> RecognizedRegions {
        guard !token.cancelled else { return RecognizedRegions() }
        let request = makeOCRRequest(imageHeight: image.height)
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return RecognizedRegions() }
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY-$1.boundingBox.midY) > 0.015 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        if requireTail, !allowClipped, TextRegionMatcher.match(expected: String(expected.suffix(24)), fragments: candidates.map(\.string),
                                               cancelled: { token.cancelled }) == nil { return RecognizedRegions() }
        guard let match = TextRegionMatcher.locate(expected: expected, fragments: candidates.map(\.string), allowClipped: allowClipped,
                                                   fieldScoped: fieldScoped, cancelled: { token.cancelled }) else {
            if !token.cancelled { IMicLog.write("mac.effect", "ocr unmatched pass=\(pass) expected_chars=\(expected.count) fragments=\(candidates.count)") }
            return RecognizedRegions()
        }
        if pass > 1 { IMicLog.write("mac.effect", "ocr matched pass=\(pass)") }
        let spans = match.spans
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
        return RecognizedRegions(rectangles: rectangles, visibleUnits: visibleUnits, includesEnd: match.includesEnd)
    }
}

private final class SweepPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SweepView: NSView {
    /// Tokens from docs/design/2026-10-27-ui-direction.md: orange marks only the
    /// active focus (one endpoint per paragraph), near-white is the line core,
    /// black keylines keep contrast on light and dark editors alike.
    private let ember = NSColor(srgbRed: 1, green: 0x5B/255.0, blue: 0x18/255.0, alpha: 1)
    private let lineCore = NSColor(srgbRed: 0xDC/255.0, green: 0xE5/255.0, blue: 0xE4/255.0, alpha: 1)
    private let black = NSColor.black
    private var rowRegions: [CGRect] = []
    private var paragraphEnds: Set<Int> = []
    private var reducedMotion = false
    private var introRoot: CALayer?
    private var loadingRoot: CALayer?
    private var endpoint: CGPoint?
    private var endpointCore: CALayer?
    private var rails: [CALayer] = []
    private var caps: [CALayer] = []
    private var alignedAt: CFTimeInterval = 0

    private static let travelTime: CFTimeInterval = 0.2
    private static let hitStop: CFTimeInterval = 0.045
    private static let impactTime: CFTimeInterval = SweepLineLayout.lineDuration-travelTime

    func install(regions: [CGRect], paragraphEnds ends: Set<Int>, reduced: Bool, entering: Bool = true) {
        wantsLayer = true
        guard let layer, !regions.isEmpty else { return }
        layer.masksToBounds = false
        rowRegions = regions; paragraphEnds = ends; reducedMotion = reduced
        if !entering || reduced { hold(); return }
        let intro = CALayer(); intro.frame = bounds
        layer.addSublayer(intro); introRoot = intro
        let time = CACurrentMediaTime()
        for (row, rect) in regions.enumerated() {
            installLine(rect, terminal: ends.contains(row), on: intro,
                        time: time+SweepLineLayout.delay(row: row, lineCount: regions.count))
        }
    }

    private func block(_ rect: CGRect, _ color: NSColor) -> CALayer {
        let node = CALayer(); node.frame = rect; node.backgroundColor = color.cgColor
        return node
    }

    private func thickness(_ rect: CGRect) -> CGFloat { SweepLineLayout.stroke(lineHeight: rect.height)+2 }

    /// Underline rail: black keyline around a near-white core, never orange.
    /// Loading rails anchor at their right end so release retracts them into
    /// the paragraph endpoint; intro rails anchor left and are drawn by the carriage.
    private func rail(for rect: CGRect, anchorLeft: Bool = false) -> CALayer {
        let t = thickness(rect)
        let node = CALayer(); node.bounds = CGRect(x: 0, y: 0, width: rect.width, height: t)
        node.anchorPoint = CGPoint(x: anchorLeft ? 0 : 1, y: 0.5)
        node.position = CGPoint(x: anchorLeft ? rect.minX : rect.maxX, y: rect.minY-1-t/2)
        node.addSublayer(block(node.bounds, black))
        node.addSublayer(block(CGRect(x: 0, y: 1, width: rect.width, height: t-2), lineCore))
        return node
    }

    /// Paragraph endpoint: an orange caret-like bar from the rail up to the row
    /// top, with a narrow same-colour halo hugging the core (no wide bloom).
    private func cap(for rect: CGRect, at point: CGPoint? = nil) -> CALayer {
        let t = thickness(rect)
        let node = CALayer(); node.bounds = CGRect(x: 0, y: 0, width: t+2, height: rect.height+t+1)
        node.position = capPosition(for: rect, endpoint: point)
        node.addSublayer(block(node.bounds, black))
        let fill = block(node.bounds.insetBy(dx: 1, dy: 1), ember)
        fill.shadowColor = ember.cgColor; fill.shadowOpacity = 0.85
        fill.shadowRadius = 2.5; fill.shadowOffset = .zero
        node.addSublayer(fill)
        return node
    }

    private func capPosition(for rect: CGRect, endpoint point: CGPoint?) -> CGPoint {
        let t = thickness(rect)
        return CGPoint(x: (point?.x ?? rect.maxX)+t/2+2, y: (point?.y ?? rect.midY)-(t+1)/2)
    }

    /// Short flat shard with a black keyline, flying from `origin` along `angle`.
    private func shard(from origin: CGPoint, angle: CGFloat, length: CGFloat, distance: CGFloat,
                       color: NSColor, on root: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let node = CALayer(); node.bounds = CGRect(x: 0, y: 0, width: length, height: 4)
        node.position = origin; node.opacity = 0
        node.addSublayer(block(node.bounds, black))
        node.addSublayer(block(node.bounds.insetBy(dx: 1, dy: 1), color))
        node.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        root.addSublayer(node)
        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: origin)
        travel.toValue = NSValue(point: CGPoint(x: origin.x+cos(angle)*distance, y: origin.y+sin(angle)*distance))
        travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.x")
        stretch.values = [0.3, 1, 0.15]; stretch.keyTimes = [0, 0.2, 1]
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 1, 1, 0]; light.keyTimes = [0, 0.05, 0.6, 1]
        let group = CAAnimationGroup(); group.animations = [travel, stretch, light]
        for animation in group.animations! { animation.duration = duration }
        group.beginTime = begin; group.duration = duration
        node.add(group, forKey: "shard")
    }

    /// One-to-two frame near-white flash: the "contact" frame of an impact.
    private func flash(at point: CGPoint, size: CGSize, on root: CALayer, begin: CFTimeInterval) {
        let node = block(CGRect(origin: .zero, size: size), lineCore)
        node.position = point; node.opacity = 0
        root.addSublayer(node)
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [1, 1, 0]; light.keyTimes = [0, 0.4, 1]; light.calculationMode = .discrete
        light.duration = 0.05; light.beginTime = begin
        node.add(light, forKey: "contact-flash")
    }

    /// Wind-up, accelerate into the stop, hit-stop, contact flash, squash and
    /// recoil. Only a paragraph's last row lands on the orange endpoint; other
    /// rows end with a small near-white tick.
    private func installLine(_ rect: CGRect, terminal: Bool, on root: CALayer, time: CFTimeInterval) {
        let travel = Self.travelTime, total = Self.travelTime+Self.hitStop
        let hitAt = time+travel
        let wind = 0.035/travel
        let accelerate = CAMediaTimingFunction(controlPoints: 0.75, 0, 0.95, 0.45)
        let row = CALayer(); row.frame = root.bounds; root.addSublayer(row)

        let track = rail(for: rect, anchorLeft: true); row.addSublayer(track)
        let draw = CAKeyframeAnimation(keyPath: "transform.scale.x")
        draw.values = [0.001, 0.001, 1]; draw.keyTimes = [0, NSNumber(value: wind), 1]
        draw.timingFunctions = [CAMediaTimingFunction(name: .linear), accelerate]
        draw.duration = travel; draw.beginTime = time
        draw.fillMode = .backwards
        track.add(draw, forKey: "rail-draw")

        let clip = CALayer(); clip.frame = rect.insetBy(dx: -4, dy: -4); clip.masksToBounds = true
        row.addSublayer(clip)
        let h = clip.bounds.height
        let width = min(56, max(22, rect.height*1.6))
        let carriage = CALayer(); carriage.bounds = CGRect(x: 0, y: 0, width: width, height: h)
        carriage.anchorPoint = CGPoint(x: 1, y: 0.5)
        carriage.addSublayer(block(CGRect(x: width-6, y: 0, width: 6, height: h), black))
        carriage.addSublayer(block(CGRect(x: width-4, y: 1, width: 2, height: h-2), lineCore))
        for (length, y) in [(width*0.62, h*0.62), (width*0.36, h*0.3)] {
            carriage.addSublayer(block(CGRect(x: width-8-length, y: y, width: length, height: 2), lineCore))
        }
        let endX = clip.bounds.width-3
        carriage.position = CGPoint(x: endX, y: h/2); carriage.opacity = 0
        clip.addSublayer(carriage)
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [8, 3, endX, endX]
        move.keyTimes = [0, NSNumber(value: wind*travel/total), NSNumber(value: travel/total), 1]
        move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), accelerate, CAMediaTimingFunction(name: .linear)]
        let visible = CABasicAnimation(keyPath: "opacity"); visible.fromValue = 1; visible.toValue = 1
        let carry = CAAnimationGroup(); carry.animations = [move, visible]
        move.duration = total; visible.duration = total
        carry.duration = total; carry.beginTime = time
        carriage.add(carry, forKey: "carriage")

        guard terminal else {
            let tick = block(CGRect(x: rect.maxX+1, y: rect.minY+rect.height*0.15, width: 2, height: rect.height*0.7), lineCore)
            tick.opacity = 0; row.addSublayer(tick)
            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, 1, 0]; light.keyTimes = [0, 0.2, 1]
            light.duration = 0.09; light.beginTime = hitAt
            tick.add(light, forKey: "row-tick")
            return
        }
        let endpointCap = cap(for: rect); endpointCap.opacity = 0; row.addSublayer(endpointCap)
        let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 1; appear.toValue = 1
        let stretchY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretchY.values = [1.9, 0.6, 1.12, 1]; stretchY.keyTimes = [0, 0.3, 0.65, 1]
        let stretchX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        stretchX.values = [0.45, 1.7, 0.92, 1]; stretchX.keyTimes = [0, 0.3, 0.65, 1]
        let squash = CAAnimationGroup(); squash.animations = [appear, stretchY, stretchX]
        for animation in squash.animations! { animation.duration = Self.impactTime }
        squash.duration = Self.impactTime; squash.beginTime = hitAt
        squash.fillMode = .forwards; squash.isRemovedOnCompletion = false
        endpointCap.add(squash, forKey: "endpoint-impact")

        let recoil = CAKeyframeAnimation(keyPath: "transform.translation.x")
        recoil.values = [0, 3, -1.5, 0]; recoil.keyTimes = [0, 0.25, 0.6, 1]
        recoil.duration = 0.11; recoil.beginTime = hitAt
        row.add(recoil, forKey: "recoil")

        let origin = endpointCap.position
        flash(at: origin, size: CGSize(width: endpointCap.bounds.width+6, height: endpointCap.bounds.height+4),
              on: row, begin: hitAt)
        for (index, degrees) in [-32.0, 0, 32].enumerated() {
            shard(from: CGPoint(x: origin.x+2, y: origin.y), angle: CGFloat(degrees * .pi/180),
                  length: index == 1 ? 9 : 6, distance: index == 1 ? 16 : 11,
                  color: index == 1 ? ember : lineCore, on: row, begin: hitAt+0.01, duration: 0.11)
        }
    }

    func setEndpoint(_ point: CGPoint) {
        endpoint = point
        // Estimated and actual layouts can re-anchor the endpoint without a
        // flyover across unrelated text. The controller owns screen coordinates.
        guard let last = rowRegions.last else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        endpointCore?.position = capPosition(for: last, endpoint: point)
        CATransaction.commit()
    }

    func hold() {
        guard loadingRoot == nil, let layer else { return }
        introRoot?.removeFromSuperlayer(); introRoot = nil
        let loading = CALayer(); loading.frame = bounds
        layer.addSublayer(loading); loadingRoot = loading
        for rect in rowRegions {
            let line = rail(for: rect); rails.append(line); loading.addSublayer(line)
        }
        installCaps(on: loading)
        guard let last = rowRegions.last else { return }
        let core = cap(for: last, at: endpoint)
        loading.addSublayer(core); endpointCore = core
        // A restrained three-step status cadence at the single final endpoint.
        for i in 0..<3 {
            let cell = block(CGRect(x: -6-CGFloat(i)*5, y: -5, width: 3, height: 3), i == 0 ? ember : lineCore)
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

    /// Static endpoints for every paragraph except the last, whose endpoint is
    /// the movable status core.
    private func installCaps(on loading: CALayer) {
        caps.forEach { $0.removeFromSuperlayer() }
        caps = paragraphEnds.sorted().filter { $0 < rowRegions.count-1 }.map { index in
            let node = cap(for: rowRegions[index]); loading.addSublayer(node); return node
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

    func align(regions: [CGRect], paragraphEnds ends: Set<Int>, endpoint: CGPoint?) {
        guard let loading = loadingRoot, let last = regions.last else { return }
        let duration = reducedMotion ? 0 : 0.18
        let easing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        func move(_ node: CALayer, from position: CGPoint) {
            guard duration > 0 else { return }
            let motion = CABasicAnimation(keyPath: "position")
            motion.fromValue = NSValue(point: position); motion.toValue = NSValue(point: node.position)
            motion.duration = duration; motion.timingFunction = easing
            node.add(motion, forKey: "align-position")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var next: [CALayer] = []
        for (index, rect) in regions.enumerated() {
            let old = index < rails.count ? rails[index] : nil
            let previous = old?.presentation() ?? old
            let start = previous?.position ?? CGPoint(x: rect.maxX, y: rect.minY-2)
            let width = previous.map { $0.bounds.width * $0.transform.m11 } ?? 1
            let line = rail(for: rect); loading.addSublayer(line); next.append(line)
            move(line, from: start)
            if duration > 0 {
                let resize = CABasicAnimation(keyPath: "transform.scale.x")
                resize.fromValue = max(0.001, width/max(1, rect.width)); resize.toValue = 1
                resize.duration = duration; resize.timingFunction = easing
                line.add(resize, forKey: "align-width")
            }
        }
        // Removed rows retract into their endpoint rather than leaving a tail.
        for (index, old) in rails.enumerated() {
            if index < regions.count || duration == 0 { old.removeFromSuperlayer(); continue }
            let collapse = CABasicAnimation(keyPath: "transform.scale.x")
            collapse.fromValue = old.presentation()?.transform.m11 ?? 1; collapse.toValue = 0.001
            collapse.duration = duration; old.transform = CATransform3DMakeScale(0.001, 1, 1)
            old.add(collapse, forKey: "removed-row")
            DispatchQueue.main.asyncAfter(deadline: .now()+duration) { old.removeFromSuperlayer() }
        }
        rails = next; rowRegions = regions; paragraphEnds = ends; self.endpoint = endpoint
        installCaps(on: loading)
        if let core = endpointCore {
            let start = core.presentation()?.position ?? core.position
            core.position = capPosition(for: last, endpoint: endpoint)
            move(core, from: start)
        }
        alignedAt = CACurrentMediaTime()+duration
        CATransaction.commit()
    }

    /// Rails retract into their endpoints, then the final endpoint punches and
    /// throws shards forward in the reading direction.
    @discardableResult
    func release(burst: Bool) -> TimeInterval {
        guard let layer, let loading = loadingRoot else { return 0.12 }
        let delay = reducedMotion ? 0 : max(0, alignedAt-CACurrentMediaTime())
        if reducedMotion {
            loading.opacity = 0
            let cut = CABasicAnimation(keyPath: "opacity"); cut.fromValue = 1; cut.toValue = 0; cut.duration = 0.07
            loading.add(cut, forKey: "loading-cut")
            return 0.12
        }
        let start = CACurrentMediaTime()+delay
        let retract = 0.09
        for line in rails {
            let pull = CABasicAnimation(keyPath: "transform.scale.x")
            pull.fromValue = 1; pull.toValue = 0.001; pull.duration = retract
            pull.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 0.5)
            pull.beginTime = start; pull.fillMode = .both; pull.isRemovedOnCompletion = false
            line.add(pull, forKey: "retract")
        }
        for node in caps {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            fade.duration = 0.06; fade.beginTime = start+retract*0.6
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            node.add(fade, forKey: "cap-out")
        }
        guard let core = endpointCore else { return delay+retract+0.08 }
        let hitAt = start+retract
        let punchY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        punchY.values = [1, 1.5, 0.05]; punchY.keyTimes = [0, 0.35, 1]
        let punchX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        punchX.values = [1, 0.6, burst ? 2.2 : 1]; punchX.keyTimes = [0, 0.35, 1]
        let out = CAKeyframeAnimation(keyPath: "opacity")
        out.values = [1, 1, 0]; out.keyTimes = [0, 0.5, 1]
        let punch = CAAnimationGroup(); punch.animations = [punchY, punchX, out]
        for animation in punch.animations! { animation.duration = 0.16 }
        punch.duration = 0.16; punch.beginTime = hitAt
        punch.fillMode = .forwards; punch.isRemovedOnCompletion = false
        core.add(punch, forKey: "endpoint-release")
        guard burst else { return delay+retract+0.16 }
        let origin = core.position
        flash(at: origin, size: CGSize(width: core.bounds.width+8, height: core.bounds.height+6), on: layer, begin: hitAt)
        for index in 0..<9 {
            let angle = CGFloat(-70+Double(index)*17.5) * .pi/180
            let major = index % 3 == 1
            shard(from: origin, angle: angle, length: major ? 14 : 8, distance: major ? 34 : 22,
                  color: major ? ember : lineCore, on: layer, begin: hitAt+0.01, duration: 0.18)
        }
        return delay+retract+0.2
    }
}
