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

    static var systemAppearanceIsLight: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
    }

    /// Mean luminance 0...1 of an image; text pixels are a small minority of a field.
    private static func averageLuminance(_ image: CGImage) -> CGFloat? {
        let input = CIImage(cgImage: image)
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input,
                                     kCIInputExtentKey: CIVector(cgRect: input.extent)])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        imageContext.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.299*CGFloat(pixel[0])+0.587*CGFloat(pixel[1])+0.114*CGFloat(pixel[2]))/255
    }

    /// Second OCR pass: grey, higher contrast, dark themes inverted to dark-on-
    /// light, small crops enlarged. Normalised coordinates are unchanged.
    private static func enhanced(_ image: CGImage) -> CGImage? {
        var input = CIImage(cgImage: image)
        let extent = input.extent
        let luminance = averageLuminance(image) ?? 1
        input = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.45])
        if luminance < 0.45 { input = input.applyingFilter("CIColorInvert") }
        if extent.height < 900 {
            input = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.6, kCIInputAspectRatioKey: 1])
        }
        return imageContext.createCGImage(input, from: input.extent)
    }
    private struct Target {
        let element: AXUIElement?
        let ownerWindow: AXUIElement?
        let pid: pid_t
        let windowID: CGWindowID
        let windowLayer: Int
        let window: CGRect
        let field: CGRect
        let elementFrame: CGRect
        let singleLine: Bool
        let textSignature: Int?
        /// False when protected content (password fields, DRM) was seen in the
        /// window: AX geometry may still animate, but no screenshot is taken.
        let allowsCapture: Bool
    }
    private let trackingQueue = DispatchQueue(label: "imic.polish-field-geometry", qos: .userInitiated)
    private var trackingSamples = 0
    private var geometryRevision = 0
    private var slowSamples = 0
    private var queryTotal: TimeInterval = 0
    private var queryMaximum: TimeInterval = 0
    private var stability = FieldFollow.Stability()
    private var finalText: String?
    private var finalVerified = false
    private var finalStarted: TimeInterval?
    private var finalProbeInFlight = false
    private var lastProbeRevision = -1
    private var writingRows: [CGRect] = []
    private var writingField: CGRect?
    private var settlementEpoch = 0
    private var lastAXProbeAt: TimeInterval = 0
    private let queue = DispatchQueue(label: "imic.polish-ocr", qos: .userInitiated)
    private var generation = 0
    private var cancellation: EffectCancellation?
    private var lifecycle = PolishEffectLifecycle()
    private var targetPID: pid_t?
    private var sweepView: SweepView?
    private var regions: [CGRect] = []
    /// Paragraph ends known from the text itself (AX path); nil means infer
    /// them from blank-line gaps between rows.
    private var paragraphHint: Set<Int>?
    /// Measured from the target's pixels when a capture is allowed, otherwise
    /// the system appearance. Chooses ink vs near-white rails, no keylines.
    private var lightBackground: Bool?
    /// The draft was located through the editor's own geometry (AX ranges or
    /// text markers); its final layout then outranks the less precise OCR.
    private var editorGeometry = false
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
        Self.snapshotScreens()
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
            // One coarse crop of the field picks the rail ink; no OCR runs on it.
            // Started now so the capture overlaps the AX line walk below.
            var shade: Task<Bool?, Never>?
            if target.element != nil, canCapture, target.allowsCapture, #available(macOS 14.0, *) {
                shade = Task {
                    let image = token.cancelled ? nil : try? await Self.capture(target, maxScale: 0.5)
                    return image.flatMap(Self.averageLuminance).map { $0 > 0.5 }
                }
            }
            // Tier 1: the editor's own line geometry. Exact, fast, permission-free.
            if let layout = Self.textLayout(target: target, text: text) {
                IMicLog.write("mac.effect", "locate source=\(layout.source) lines=\(layout.rows.count)")
                let publish = { (light: Bool?) in
                    DispatchQueue.main.async {
                        self.prepared(layout.rows, generation: version, target: target, visibleUnits: layout.visibleUnits,
                                      paragraphEnds: layout.paragraphEnds, light: light)
                    }
                }
                guard let shade else { publish(nil); return }
                Task { publish(await shade.value) }
                return
            }
            // OCR below measures luminance from its own full-resolution capture.
            shade?.cancel()
            // Tier 3: a single-line field without usable ranges or OCR still has a
            // reliable vertical centre; estimate the row instead of skipping.
            let estimate = { (light: Bool?) -> Void in
                guard target.singleLine, target.element != nil,
                      let row = SweepLineLayout.singleLineEstimate(field: target.field, text: text) else {
                    DispatchQueue.main.async { self.prepared([], generation: version) }; return
                }
                IMicLog.write("mac.effect", "locate source=field_estimate")
                DispatchQueue.main.async { self.prepared([row], generation: version, target: target, light: light) }
            }
            guard canCapture, target.allowsCapture, #available(macOS 14.0, *) else {
                IMicLog.write("mac.effect", "ocr skipped reason=\(canCapture ? "protected_content" : "capture_permission")")
                estimate(nil); return
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
                        let light = Self.averageLuminance(image).map { $0 > 0.5 }
                        let rectangles = Self.recognize(image, field: target.field, expected: text, token: token,
                                                        allowClipped: target.singleLine, fieldScoped: target.element != nil)
                        let unchanged = Self.valid(target)
                        let result = unchanged && !token.cancelled ? rectangles.rectangles : []
                        IMicLog.write("mac.effect", "ocr lines=\(result.count) ms=\(Int((ProcessInfo.processInfo.systemUptime-start)*1000))")
                        if result.isEmpty, unchanged, !token.cancelled { estimate(light); return }
                        DispatchQueue.main.async {
                            self.prepared(result, generation: version, target: target, visibleUnits: rectangles.visibleUnits, light: light)
                        }
                    }
                } catch {
                    estimate(nil)
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
        regions = []; paragraphHint = nil; lightBackground = nil; editorGeometry = false; validationTarget = nil
        originalText = ""; matchedVisibleUnits = 0; releaseEndpoint = nil
        finalText = nil; finalStarted = nil; finalProbeInFlight = false
        writingRows = []; writingField = nil; stability = FieldFollow.Stability()
        trackingSamples = 0; geometryRevision = 0; lastProbeRevision = -1; slowSamples = 0; queryTotal = 0; queryMaximum = 0
        settlementEpoch += 1
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
        regions = []; paragraphHint = nil
        lifecycle.skipVisual()
        IMicLog.write("mac.effect", "skipped reason=\(reason)")
        beginDeliveryIfReady()
    }

    private func prepared(_ rectangles: [CGRect], generation version: Int, target: Target? = nil, visibleUnits: Double = 0,
                          paragraphEnds: Set<Int>? = nil, light: Bool? = nil) {
        guard generation == version, cancellation?.cancelled == false, lifecycle.phase == .locating else { return }
        lightBackground = light
        editorGeometry = paragraphEnds != nil
        regions = SweepLineLayout.lines(in: rectangles)
        paragraphHint = Self.mapped(paragraphEnds, from: rectangles, to: regions)
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

    /// Text-derived paragraph ends apply only while the rows are exactly the
    /// AX rows they were computed for; row merging falls back to gap inference.
    private static func mapped(_ ends: Set<Int>?, from source: [CGRect], to rows: [CGRect]) -> Set<Int>? {
        guard let ends, source.count == rows.count, ends.allSatisfy({ $0 < rows.count }) else { return nil }
        return ends.union([rows.count-1])
    }

    private func installPanel(regions: [CGRect], entering: Bool, endpoint: CGPoint? = nil, paragraphEnds: Set<Int>? = nil,
                              confirmed: Bool = true) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ends = paragraphEnds ?? SweepLineLayout.paragraphEnds(regions)
        let textUnion = regions.reduce(CGRect.null) { $0.union($1) }
        let anchored = endpoint.map { textUnion.union(CGRect(x: $0.x, y: $0.y, width: 1, height: 1)) } ?? textUnion
        let union = anchored.insetBy(dx: reduced ? -3 : -54, dy: reduced ? -3 : -54)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var rect = NSRect(x: union.minX, y: top-union.maxY, width: union.width, height: union.height)
        if entering, let target = validationTarget, target.element != nil {
            let visibleWindow = Self.screens.reduce(CGRect.null) { $0.union($1.intersection(target.window)) }
            if !visibleWindow.isNull {
                rect = rect.union(NSRect(x: visibleWindow.minX, y: top-visibleWindow.maxY,
                                         width: visibleWindow.width, height: visibleWindow.height).insetBy(dx: -8, dy: -8))
            }
        }
        if !entering, let panel, let view = sweepView {
            let previous = panel.frame
            rect = rect.union(previous)
            if !Self.same(rect, previous) {
                panel.setFrame(rect, display: false)
                rect = panel.frame
                let offset = CGPoint(x: previous.minX-rect.minX, y: previous.minY-rect.minY)
                view.reframe(size: rect.size, offset: offset)
            }
            let localRows = regions.map { SweepPanelCoordinates.row($0, panel: rect, screenTop: top) }
            let localEnd = endpoint.map { SweepPanelCoordinates.point($0, panel: rect, screenTop: top) }
            view.align(regions: localRows, paragraphEnds: ends, endpoint: localEnd, confirmed: confirmed)
            return
        }
        let window = panel ?? SweepPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(rect, display: false)
        rect = window.frame
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, (validationTarget?.windowLayer ?? 0)+1))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = SweepView(frame: NSRect(origin: .zero, size: rect.size))
        view.palette = (lightBackground ?? Self.systemAppearanceIsLight) ? .light : .dark
        window.contentView = view
        view.install(regions: regions.map { SweepPanelCoordinates.row($0, panel: rect, screenTop: top) },
                     paragraphEnds: ends, reduced: reduced, entering: entering)
        if let endpoint { view.setEndpoint(SweepPanelCoordinates.point(endpoint, panel: rect, screenTop: top)) }
        sweepView = view; panel = window
        window.orderFrontRegardless()
    }

    private func startSweep() {
        guard lifecycle.visualPrepared() else { return }
        installPanel(regions: regions, entering: true, paragraphEnds: paragraphHint)
        didShowSweep = true
        trackGeometry(generation: generation)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.12 : SweepLineLayout.duration(lineCount: regions.count)
        IMicLog.write("mac.effect", "sweep lines=\(regions.count) paragraphs=\((paragraphHint ?? SweepLineLayout.paragraphEnds(regions)).count) source=\(paragraphHint == nil ? "gaps" : "text") palette=\((lightBackground ?? Self.systemAppearanceIsLight) ? "light" : "dark")\(lightBackground == nil ? "(system)" : "") reduced=\(reduced) ms=\(Int(duration*1000)) resultReady=\(lifecycle.hasResult) \(Self.geometry(regions, endpoint: nil))")
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version, self.lifecycle.phase == .sweeping else { return }
            self.lifecycle.sweepFinished()
            self.sweepView?.hold()
            IMicLog.write("mac.effect", "holding resultReady=\(self.lifecycle.hasResult)")
            self.beginDeliveryIfReady()
        }
        animationEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
    }

    /// One AX query batch at a time, independent of OCR. No timer backlog and no
    /// text reads after writing starts. Existing held-text signature checks keep
    /// their 300 ms cadence and are ignored if the write began during that query.
    private func trackGeometry(generation version: Int, after delay: TimeInterval = FieldFollow.sampleInterval) {
        guard let target = validationTarget, target.element != nil, let token = cancellation,
              !token.cancelled else { return }
        let checkSignature = (lifecycle.phase == .sweeping || lifecycle.phase == .holding) && trackingSamples % 10 == 0
        trackingQueue.asyncAfter(deadline: .now()+delay) { [weak self] in
            guard let self, !token.cancelled else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let fresh = Self.following(target)
            let signatureOK = !checkSignature || target.textSignature == nil
                || (target.element.flatMap { Self.read($0, kAXValueAttribute) as? String })?.hashValue == target.textSignature
            let elapsed = ProcessInfo.processInfo.systemUptime-started
            DispatchQueue.main.async {
                guard self.generation == version, !token.cancelled,
                      [.sweeping, .holding, .writing, .releasing].contains(self.lifecycle.phase) else { return }
                guard let fresh,
                      !(checkSignature && !signatureOK && [.sweeping, .holding].contains(self.lifecycle.phase)) else {
                    if [.sweeping, .holding].contains(self.lifecycle.phase) { self.skipVisual(reason: "held_target_changed") }
                    else { self.finishVisual() }
                    return
                }
                self.trackingSamples += 1
                self.queryTotal += elapsed; self.queryMaximum = max(self.queryMaximum, elapsed)
                if elapsed > FieldFollow.sampleInterval {
                    self.slowSamples += 1
                    if self.slowSamples == 1 || self.slowSamples % 10 == 0 {
                        IMicLog.write("mac.effect", "geometry_sample slow_ms=\(Int(elapsed*1000)) slow_samples=\(self.slowSamples)")
                    }
                }
                let delta = FieldFollow.delta(from: target.field, to: fresh.field)
                if FieldFollow.classify(old: Self.geometry(target), new: Self.geometry(fresh)) == .followable {
                    self.geometryRevision += 1
                }
                self.validationTarget = fresh
                if abs(delta.dx) > 0.01 || abs(delta.dy) > 0.01 {
                    self.regions = self.regions.map { $0.offsetBy(dx: delta.dx, dy: delta.dy) }
                    self.releaseEndpoint = self.releaseEndpoint.map { CGPoint(x: $0.x+delta.dx, y: $0.y+delta.dy) }
                    // Cocoa layer coordinates grow upward; AX screen coordinates grow down.
                    self.sweepView?.follow(by: CGVector(dx: delta.dx, dy: -delta.dy))
                    IMicLog.write("mac.effect", "follow dx=\(String(format: "%.2f", delta.dx)) dy=\(String(format: "%.2f", delta.dy)) samples=\(self.trackingSamples)")
                }
                if self.finalStarted != nil && self.lifecycle.phase == .writing {
                    let wasStable = self.stability.stableSince
                    self.stability.observe(Self.geometry(fresh), at: ProcessInfo.processInfo.systemUptime)
                    self.updateFinalEstimate()
                    if self.stability.stableSince != wasStable { self.scheduleSettlementDeadline() }
                    if let stable = self.stability.stableSince, !self.finalProbeInFlight,
                       ProcessInfo.processInfo.systemUptime-self.lastAXProbeAt >= FieldFollow.sampleInterval*2 {
                        IMicLog.write("mac.effect", "stable after=\(Int((stable-self.finalStarted!)*1000))ms")
                        self.probeStableLayout(target: fresh, token: token, version: version)
                    }
                }
                self.trackGeometry(generation: version, after: max(0, FieldFollow.sampleInterval-(ProcessInfo.processInfo.systemUptime-started)))
            }
        }
    }

    private static func geometry(_ target: Target) -> FieldFollow.Geometry {
        .init(windowID: target.windowID, window: target.window, element: target.elementFrame, visible: target.field)
    }

    private func beginDeliveryIfReady() {
        guard let callback = delivery, lifecycle.beginWriting() else { return }
        deadline?.cancel(); deadline = nil
        delivery = nil
        IMicLog.write("mac.effect", "writing overlay=\(panel != nil)")
        // Rails belong to the pre-polish text: they turn into shimmering skeleton
        // placeholders until the new layout is known.
        sweepView?.beginLoading()
        writingRows = regions; writingField = validationTarget?.field
        callback()
    }

    /// Called AFTER completeSession has resolved its input retries. Keep the
    /// loading layer through the handoff; an event-post return isn't a paint ACK.
    func finishDelivery(succeeded: Bool, finalText: String, verified: Bool) {
        precondition(Thread.isMainThread)
        guard lifecycle.phase == .writing else { return }
        guard succeeded, panel != nil, let pid = targetPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { finishVisual(); return }
        Self.snapshotScreens()
        guard let target = validationTarget, let token = cancellation else { reveal(source: "no_target", burst: false); return }
        let version = generation
        if target.element == nil {
            // Window-only OCR has no field origin to track; preserve its existing fallback.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == version else { return }
                self.reveal(source: "display_deadline_estimated", burst: self.releaseEndpoint != nil)
            }
            deadline = timeout; DispatchQueue.main.asyncAfter(deadline: .now()+0.6, execute: timeout)
            let rows = regions, original = originalText, units = matchedVisibleUnits, editor = editorGeometry
            for (attempt, delay) in [0.0, 0.12, 0.28, 0.44].enumerated() {
                queue.asyncAfter(deadline: .now()+delay) { [weak self] in
                    self?.refreshFinalLayout(target: target, pid: pid, finalText: finalText, verified: verified,
                        oldRows: rows, original: original, visibleUnits: units, preferEditor: editor,
                        token: token, version: version, attempt: attempt)
                }
            }
            return
        }
        self.finalText = finalText; finalVerified = verified
        finalStarted = ProcessInfo.processInfo.systemUptime
        stability = FieldFollow.Stability(); lastProbeRevision = -1; lastAXProbeAt = 0
        stability.observe(Self.geometry(target), at: finalStarted!)
        updateFinalEstimate(); scheduleSettlementDeadline()
    }

    private func updateFinalEstimate() {
        guard let finalText, let target = validationTarget, !target.singleLine else { return }
        let rows = PolishEndpointEstimate.layout(original: originalText, final: finalText, rows: writingRows,
            field: target.field, visibleUnits: matchedVisibleUnits, referenceField: writingField)
        let endpoint = PolishEndpointEstimate.endpoint(original: originalText, final: finalText, rows: writingRows,
            field: target.field, visibleUnits: matchedVisibleUnits, referenceField: writingField)
        guard let endpoint, !rows.isEmpty else { return }
        let unchanged = rows.count == regions.count && zip(rows, regions).allSatisfy { FieldFollow.same($0, $1) }
            && releaseEndpoint.map { hypot($0.x-endpoint.x, $0.y-endpoint.y) < 0.5 } == true
        guard !unchanged else { return }
        releaseEndpoint = endpoint; regions = rows
        installPanel(regions: rows, entering: false, endpoint: endpoint, confirmed: false)
    }

    private func scheduleSettlementDeadline() {
        guard let start = finalStarted, lifecycle.phase == .writing else { return }
        deadline?.cancel(); settlementEpoch += 1
        let epoch = settlementEpoch, version = generation
        let delay = max(0, stability.deadline(start: start)-ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version, self.settlementEpoch == epoch,
                  self.lifecycle.phase == .writing else { return }
            self.updateFinalEstimate()
            let moving = self.stability.stableSince == nil
            self.reveal(source: "display_deadline_estimated moving=\(moving ? 1 : 0)", burst: self.releaseEndpoint != nil)
        }
        deadline = work; DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: work)
    }

    private func probeStableLayout(target: Target, token: EffectCancellation, version: Int) {
        guard let text = finalText else { return }
        finalProbeInFlight = true; lastAXProbeAt = ProcessInfo.processInfo.systemUptime
        let allowOCR = lastProbeRevision != geometryRevision
        let revision = geometryRevision, verified = finalVerified
        let finished = { [weak self] (layout: TextLayout?) in
            DispatchQueue.main.async {
                guard let self, self.generation == version, !token.cancelled, self.lifecycle.phase == .writing else { return }
                self.finalProbeInFlight = false
                guard self.geometryRevision == revision, self.stability.stableSince != nil else { return }
                if let layout {
                    self.releaseEndpoint = nil; self.regions = SweepLineLayout.lines(in: layout.rows)
                    self.paragraphHint = Self.mapped(layout.paragraphEnds, from: layout.rows, to: self.regions)
                    self.installPanel(regions: self.regions, entering: false, paragraphEnds: self.paragraphHint)
                    self.reveal(source: layout.source == "ocr_display_match" ? layout.source : verified ? "confirmed_range_layout" : "readable_layout", burst: true)
                }
            }
        }
        queue.async { [weak self] in
            guard let self, !token.cancelled else { return }
            if let layout = Self.textLayout(target: target, text: text),
               let after = Self.following(target), FieldFollow.classify(old: Self.geometry(target), new: Self.geometry(after)) == .none {
                finished(layout); return
            }
            // One OCR request per stable geometry; AX can retry without waiting
            // for another field movement when its range geometry arrives late.
            guard allowOCR else { finished(nil); return }
            DispatchQueue.main.async {
                guard self.generation == version, !token.cancelled, self.geometryRevision == revision else { finished(nil); return }
                self.lastProbeRevision = revision
            }
            guard target.allowsCapture, CGPreflightScreenCaptureAccess(), #available(macOS 14.0, *) else { finished(nil); return }
            Task {
                do {
                    let image = try await Self.capture(target)
                    self.queue.async {
                        guard !token.cancelled else { return }
                        let found = Self.recognize(image, field: target.field, expected: text, token: token,
                            requireTail: true, allowClipped: target.singleLine, fieldScoped: true)
                        guard !found.rectangles.isEmpty, let after = Self.following(target),
                              FieldFollow.classify(old: Self.geometry(target), new: Self.geometry(after)) == .none else { finished(nil); return }
                        finished(TextLayout(rows: found.rectangles, visibleUnits: found.visibleUnits,
                            paragraphEnds: SweepLineLayout.paragraphEnds(found.rectangles), source: "ocr_display_match"))
                    }
                } catch { finished(nil) }
            }
        }
    }

    private func refreshFinalLayout(target: Target, pid: pid_t, finalText: String, verified: Bool,
                                    oldRows: [CGRect], original: String, visibleUnits: Double, preferEditor: Bool,
                                    token: EffectCancellation, version: Int, attempt: Int) {
        guard !token.cancelled else { return }
        // Some editors expose the new value before updating its line geometry.
        // Do not finalize on that first, stale AX layout immediately after write.
        // Single-line fields qualify too: rangeLayout requires a visible tail.
        // Tried before the estimate so a confirmed layout never follows a
        // momentary jump to the guessed position.
        if attempt >= 2, let layout = Self.textLayout(target: target, text: finalText) {
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
                self.releaseEndpoint = nil
                self.regions = SweepLineLayout.lines(in: layout.rows)
                self.paragraphHint = Self.mapped(layout.paragraphEnds, from: layout.rows, to: self.regions)
                self.installPanel(regions: self.regions, entering: false, paragraphEnds: self.paragraphHint)
                self.reveal(source: verified ? "confirmed_range_layout" : "readable_layout", burst: true)
            }
            return
        }
        if !target.singleLine, target.element != nil {
            let field = target.element.flatMap { Self.visibleField($0, window: target.window) } ?? target.field
            let estimate = PolishEndpointEstimate.endpoint(original: original, final: finalText,
                                                           rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
            let estimatedRows = PolishEndpointEstimate.layout(original: original, final: finalText,
                                                              rows: oldRows, field: field, visibleUnits: visibleUnits, referenceField: target.field)
            DispatchQueue.main.async {
                guard self.generation == version, self.lifecycle.phase == .writing, !token.cancelled else { return }
                // Later passes usually repeat the same guess; re-anchoring would blink it.
                if let estimate, let previous = self.releaseEndpoint,
                   hypot(estimate.x-previous.x, estimate.y-previous.y) < 0.5 { return }
                self.releaseEndpoint = estimate
                if let estimate {
                    self.installPanel(regions: estimatedRows.isEmpty ? oldRows : estimatedRows, entering: false,
                                      endpoint: estimate, confirmed: false)
                }
            }
        }
        // OCR of the final text is a fallback. When the editor reports geometry,
        // give its post-reflow layout (attempts 2 and 3) the first chance.
        guard attempt == (preferEditor ? 3 : 1) else { return }
        guard let fresh = Self.locate(pid: pid, element: target.element, expected: finalText, token: token),
              fresh.allowsCapture else { return }
        guard #available(macOS 14.0, *) else { return }
        Task {
            do {
                guard !token.cancelled else { return }
                let image = try await Self.capture(fresh)
                self.queue.async {
                    guard !token.cancelled else { return }
                    let geometry = Self.recognize(image, field: fresh.field, expected: finalText, token: token, requireTail: true,
                                                  allowClipped: fresh.singleLine, fieldScoped: fresh.element != nil)
                    let rects = geometry.rectangles
                    guard Self.valid(fresh) else { return }
                    DispatchQueue.main.async {
                        guard self.generation == version, self.lifecycle.phase == .writing,
                              !token.cancelled, !rects.isEmpty else { return }
                        self.releaseEndpoint = nil
                        self.regions = SweepLineLayout.lines(in: rects); self.paragraphHint = nil
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
        IMicLog.write("mac.effect", "release source=\(source) burst=\(burst) \(Self.geometry(regions, endpoint: releaseEndpoint))")
        let duration = sweepView?.release(burst: burst) ?? 0.12
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version else { return }
            self.finishVisual()
        }
        animationEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now()+duration, execute: work)
    }

    /// Screen-space summary for diagnostics: union of rows and the endpoint the
    /// overlay lands on. Coordinates only, never text.
    private static func geometry(_ rows: [CGRect], endpoint: CGPoint?) -> String {
        guard let last = rows.last else { return "rows=0" }
        let union = rows.reduce(CGRect.null) { $0.union($1) }
        let end = endpoint ?? CGPoint(x: last.maxX, y: last.midY)
        return "union=\(Int(union.minX)),\(Int(union.minY)),\(Int(union.width)),\(Int(union.height)) end=\(Int(end.x)),\(Int(end.y))"
    }

    private func finishVisual() {
        if trackingSamples > 0 {
            IMicLog.write("mac.effect", "geometry_sampling samples=\(trackingSamples) avg_ms=\(Int(queryTotal*1000/Double(trackingSamples))) max_ms=\(Int(queryMaximum*1000)) slow=\(slowSamples)")
        }
        cancellation?.cancel()
        deadline?.cancel(); deadline = nil
        animationEnd?.cancel(); animationEnd = nil
        panel?.orderOut(nil); panel = nil; sweepView = nil
        removeMonitors()
        regions = []; paragraphHint = nil; validationTarget = nil
        originalText = ""; matchedVisibleUnits = 0; releaseEndpoint = nil
        finalText = nil; finalStarted = nil; finalProbeInFlight = false
        writingRows = []; writingField = nil; stability = FieldFollow.Stability()
        trackingSamples = 0; geometryRevision = 0; lastProbeRevision = -1; slowSamples = 0; queryTotal = 0; queryMaximum = 0
        settlementEpoch += 1
        delivery = nil; allowed = nil; interrupted = nil
        lifecycle.finish()
        onVisualFinished?()
    }

    private struct TextLayout {
        let rows: [CGRect]
        let visibleUnits: Double
        /// Row indices ended by a hard line break, plus the text's last row.
        let paragraphEnds: Set<Int>
        var source = "ax_range"
    }

    /// Editor geometry: plain AX line ranges first, then the WebKit/Chromium
    /// text-marker API (Chrome, Safari, Electron), whose AXBoundsForRange is
    /// often an empty rectangle.
    private static func textLayout(target: Target, text: String) -> TextLayout? {
        // Terminal AX boxes are half as wide as wide (CJK) text really is; OCR
        // reads what is actually drawn.
        if TypedTextSafety.containsWideCharacters(text),
           TypedTextSafety.isTerminal(bundleIdentifier: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier,
                                      labels: []) {
            IMicLog.write("mac.effect", "locate editor_geometry=off cause=terminal_wide_text")
            return nil
        }
        if let layout = rangeLayout(target: target, text: text) { return layout }
        guard let element = target.element, let field = visibleField(element, window: target.window),
              let marker = TextMarkerGeometry.layout(element: element, text: text, field: field,
                                                     deadline: ProcessInfo.processInfo.systemUptime+0.25) else { return nil }
        return TextLayout(rows: marker.rows, visibleUnits: marker.visibleUnits,
                          paragraphEnds: marker.paragraphEnds, source: "ax_marker")
    }

    /// Visible line rectangles of the last occurrence of `text`, read from the
    /// editor's AX line ranges. Layout only, never permission to edit. Rejects
    /// geometry that is slow, hidden at the tail, or implausible (duplicated or
    /// field-sized rectangles); callers then fall back to OCR.
    private static func rangeLayout(target: Target, text: String) -> TextLayout? {
        guard let element = target.element, let value = read(element, kAXValueAttribute) as? String,
              let field = visibleField(element, window: target.window), !text.isEmpty else { return nil }
        let string = value as NSString
        let span = string.range(of: text, options: .backwards)
        guard span.location != NSNotFound else { return nil }
        // A slow or hung editor must not hold the serial OCR queue for the next utterance.
        let deadline = ProcessInfo.processInfo.systemUptime+0.25
        func parameter(_ name: String, _ input: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &result) == .success ? result : nil
        }
        func line(containing index: Int) -> NSRange? {
            guard let number = parameter(kAXLineForIndexParameterizedAttribute, NSNumber(value: index)),
                  let raw = parameter(kAXRangeForLineParameterizedAttribute, number),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            var range = CFRange()
            guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
                  range.location >= 0, range.length > 0, range.length <= 100_000,
                  range.location <= index, index < range.location+range.length else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        func bounds(_ range: NSRange) -> CGRect? {
            var input = CFRange(location: range.location, length: range.length)
            guard let parameterValue = AXValueCreate(.cfRange, &input),
                  let raw = parameter(kAXBoundsForRangeParameterizedAttribute, parameterValue),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            var rect = CGRect.zero
            guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
                  rect.width > 1, rect.height > 1 else { return nil }
            return rect
        }
        // Walk backwards from the tail: only visible lines (plus the first one
        // above the viewport) cost AX calls, however long the dictation is.
        var rows: [(rect: CGRect, endsParagraph: Bool)] = []
        var visibleUnits = 0.0
        var seen = Set<[Int]>()
        var tailChecked = false
        var end = NSMaxRange(span)
        while end > span.location, rows.count < 64 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let line = line(containing: end-1) else { return nil }
            let start = max(span.location, line.location)
            defer { end = start }
            guard let segment = TextLineSegment.visible(NSRange(location: start, length: end-start), in: string) else { continue }
            guard let rect = bounds(segment.range) else { return nil }
            // Some editors answer every range with the element or one stale line box.
            let key = [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)]
            guard seen.insert(key).inserted, rect.height <= max(64, field.height*0.5) || target.singleLine,
                  !same(rect, target.elementFrame) else { return nil }
            let visible = rect.intersection(field)
            if !tailChecked {
                tailChecked = true
                guard visible.width > 1, visible.height >= rect.height*0.8 else { return nil }
            }
            if visible.width > 1, visible.height > 1 {
                rows.append((visible, segment.endsParagraph || rows.isEmpty))
                visibleUnits += PolishEndpointEstimate.units(in: string.substring(with: segment.range))
            } else if rect.maxY <= field.minY+1 {
                break
            }
        }
        guard tailChecked, !rows.isEmpty else { return nil }
        let ordered = Array(rows.reversed())
        return TextLayout(rows: ordered.map(\.rect), visibleUnits: visibleUnits,
                          paragraphEnds: Set(ordered.indices.filter { ordered[$0].endsParagraph }))
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    /// Several attributes in one IPC round trip; unsupported ones come back nil.
    /// Falls back to single reads when the target rejects the batched call.
    private static func read(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == attributes.count else {
            return attributes.map { read(element, $0) }
        }
        return array.map { value in
            CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError ? nil : value
        }
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        let values = read(element, [kAXPositionAttribute, kAXSizeAttribute])
        return frame(position: values[0], size: values[1])
    }
    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let a = position, let b = size,
              CFGetTypeID(a) == AXValueGetTypeID(), CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        let av = a as! AXValue, bv = b as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(av) == .cgPoint, AXValueGetType(bv) == .cgSize,
              AXValueGetValue(av, .cgPoint, &point), AXValueGetValue(bv, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func visibleField(_ element: AXUIElement, window: CGRect, content: CGRect? = nil) -> CGRect? {
        guard let content = content ?? frame(element) else { return nil }
        var clips: [CGRect] = []
        var parent = read(element, kAXParentAttribute)
        for _ in 0..<24 {
            guard let raw = parent, CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let values = read(raw as! AXUIElement, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute])
            let role = values[0] as? String
            if role == kAXScrollAreaRole || role == "AXClipView" || role == kAXWindowRole,
               let rect = frame(position: values[1], size: values[2]), rect.width > 10, rect.height > 8 { clips.append(rect) }
            if role == kAXWindowRole { break }
            parent = values[3]
        }
        // Windows can extend past the display edge; never draw for off-screen text.
        clips.append(screens.first { $0.intersects(content) } ?? .zero)
        return TextViewport.visible(content: content, window: window, clips: clips)
    }

    /// Display frames in AX (top-left) coordinates. Workers must not touch
    /// NSScreen, so main refreshes this snapshot at the start of each pass.
    private static let screenLock = NSLock()
    private static var screenSnapshot: [CGRect] = []
    private static var screens: [CGRect] { screenLock.lock(); defer { screenLock.unlock() }; return screenSnapshot }
    private static func snapshotScreens() {
        precondition(Thread.isMainThread)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frames = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top-$0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        screenLock.lock(); screenSnapshot = frames; screenLock.unlock()
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 && abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
    }
    /// Geometry-only identity check. Window changes remain fatal; movement of the
    /// same field within that window is followable. No value/string query here.
    private static func following(_ target: Target) -> Target? {
        guard let window = windows().first(where: { $0.id == target.windowID && $0.pid == target.pid && $0.visible }),
              FieldFollow.same(window.frame, target.window), let element = target.element,
              let current = frame(element), let visible = visibleField(element, window: target.window, content: current) else { return nil }
        if let owner = target.ownerWindow {
            guard let value = read(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
                  CFEqual(value, owner) else { return nil }
        }
        return Target(element: element, ownerWindow: target.ownerWindow, pid: target.pid, windowID: target.windowID,
                      windowLayer: target.windowLayer, window: target.window, field: visible, elementFrame: current,
                      singleLine: target.singleLine, textSignature: target.textSignature, allowsCapture: target.allowsCapture)
    }
    private static func valid(_ target: Target) -> Bool {
        guard let currentWindow = windows().first(where: { $0.id == target.windowID && $0.pid == target.pid && $0.visible }),
              same(currentWindow.frame, target.window) else { return false }
        guard let element = target.element else { return true }
        guard let current = frame(element), same(current, target.elementFrame),
              let visible = visibleField(element, window: target.window), same(visible, target.field) else { return false }
        if let signature = target.textSignature {
            return (read(element, kAXValueAttribute) as? String)?.hashValue == signature
        }
        return true
    }

    private static func windows() -> [PolishWindowSelection.Candidate] {
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return records.compactMap { record in
            guard let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let id = record[kCGWindowNumber as String] as? UInt32,
                  let layer = record[kCGWindowLayer as String] as? Int,
                  let raw = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw) else { return nil }
            return .init(id: id, pid: pid, frame: frame, layer: layer,
                         visible: (record[kCGWindowAlpha as String] as? Double ?? 1) > 0)
        }
    }

    private static func locate(pid: pid_t, element: AXUIElement?, expected: String, token: EffectCancellation) -> Target? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var candidates: [AXUIElement] = []
        if let element { candidates.append(element) }
        var focused = read(app, kAXFocusedUIElementAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        // Electron apps (Claude, ChatGPT, Cursor, VS Code) publish their text fields
        // only after AXManualAccessibility is requested. This asks the app for its
        // AX tree; it is not a TCC permission and changes nothing else.
        if focused == nil, element == nil,
           AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            usleep(120_000)
            focused = read(app, kAXFocusedUIElementAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            IMicLog.write("mac.effect", "manual accessibility requested focused=\(focused != nil)")
        }
        if let focused { candidates.append(focused) }
        var protectedSeen = false
        let until = ProcessInfo.processInfo.systemUptime + 0.4
        var index = 0
        if let window = read(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() { candidates.append(window as! AXUIElement) }
        while index < candidates.count, index < 2_000, !token.cancelled, ProcessInfo.processInfo.systemUptime < until {
            let candidate = candidates[index]; index += 1
            AXUIElementSetMessagingTimeout(candidate, 0.06)
            // One round trip per node: large web/Electron trees exhaust the
            // 0.4s budget quickly when every attribute is its own IPC call.
            let values = read(candidate, [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent",
                                          kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            let role = values[0] as? String
            if values[1] as? String == kAXSecureTextFieldSubrole || (values[2] as? Bool) == true {
                // Never decorate the secure field itself. Elsewhere in the window it
                // only rules out screenshots, so AX-located fields keep the effect.
                if element.map({ CFEqual($0, candidate) }) == true || focused.map({ CFEqual($0, candidate) }) == true { return nil }
                protectedSeen = true
                continue
            }
            if role == "AXTextArea" || role == "AXTextField", let field = frame(position: values[3], size: values[4]),
               field.width > 10, field.height > 8 {
                // The captured focused element is preferred. Discovered fields must
                // actually contain a distinctive suffix of our emitted transcript.
                let captured = element.map { CFEqual($0, candidate) } ?? false
                let value = read(candidate, kAXValueAttribute) as? String
                let content = value ?? ""
                let suffix = String(expected.suffix(16))
                if captured || (!suffix.isEmpty && content.contains(suffix)) {
                    let owner = read(candidate, kAXWindowAttribute)
                    let ownerFrame = owner.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? frame($0 as! AXUIElement) : nil }
                    if let window = PolishWindowSelection.choose(windows().filter { $0.frame.intersects(field) }, pid: pid, preferred: ownerFrame),
                       let visible = visibleField(candidate, window: window.frame) {
                        return Target(element: candidate, ownerWindow: owner.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }, pid: pid, windowID: window.id, windowLayer: window.layer,
                                      window: window.frame, field: visible, elementFrame: field,
                                      singleLine: role == kAXTextFieldRole || (read(candidate, "AXMultiline") as? Bool) == false,
                                      textSignature: value?.hashValue,
                                      allowsCapture: !protectedSeen)
                    }
                }
            }
            if let children = values[5] as? [AXUIElement] { candidates.append(contentsOf: children) }
        }
        guard !token.cancelled else { return nil }
        // Window-wide OCR would screenshot the protected content itself.
        guard !protectedSeen else { IMicLog.write("mac.effect", "locate skipped reason=protected_content"); return nil }
        let focusedWindow = read(app, kAXFocusedWindowAttribute)
        let preferred = focusedWindow.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? frame($0 as! AXUIElement) : nil }
        guard let window = PolishWindowSelection.choose(windows(), pid: pid, preferred: preferred) else { return nil }
        IMicLog.write("mac.effect", "locate fallback=window_ocr layer=\(window.layer)")
        return Target(element: nil, ownerWindow: nil, pid: pid, windowID: window.id, windowLayer: window.layer,
                      window: window.frame, field: window.frame, elementFrame: window.frame,
                      singleLine: false, textSignature: nil, allowsCapture: true)
    }

    @available(macOS 14.0, *)
    /// `maxScale` 2 suits OCR; a luminance probe needs only a coarse image.
    private static func capture(_ target: Target, maxScale: CGFloat = 2) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else { throw CaptureError.unavailable }
        let configuration = SCStreamConfiguration()
        let scale = min(maxScale, 2_800 / max(target.window.width, target.window.height))
        configuration.width = max(1, Int(target.window.width * scale))
        configuration.height = max(1, Int(target.window.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        // Without this a window on a 1x display is delivered at its native size in
        // the corner of the larger canvas, and every OCR box maps to the wrong place.
        configuration.scalesToFit = true
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
        // The post-write check shares a 600ms visual deadline; a second pass would only miss it.
        guard first.rectangles.isEmpty, !requireTail, !token.cancelled, let retry = enhanced(image) else { return first }
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
        let observed = observations.compactMap { observation in observation.topCandidates(1).first.map { (observation, $0) } }
        let candidates = observed.map(\.1)
        if requireTail, !allowClipped, TextRegionMatcher.locate(expected: String(expected.suffix(24)), fragments: candidates.map(\.string),
                                                fieldScoped: fieldScoped, cancelled: { token.cancelled }) == nil { return RecognizedRegions() }
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
        var raw: [(rect: CGRect, endsLine: Bool)] = []
        for span in spans {
            let candidate = candidates[span.fragment]
            // A whole line uses the observation's own box; Vision interpolates
            // sub-ranges, which drifts with mixed CJK and Latin widths.
            let r: CGRect
            if span.range.location == 0, span.range.length == (candidate.string as NSString).length {
                r = observed[span.fragment].0.boundingBox
            } else {
                guard let range = Range(span.range, in: candidate.string), let box = try? candidate.boundingBox(for: range) else { continue }
                r = box.boundingBox
            }
            let result = CGRect(x: field.minX+r.minX*field.width, y: field.minY+(1-r.maxY)*field.height,
                                width: r.width*field.width, height: r.height*field.height).intersection(field)
            if result.width > 1, result.height > 1 {
                raw.append((result, NSMaxRange(span.range) == (candidate.string as NSString).length))
            }
        }
        let rectangles = refineInk(raw, image: image, field: field)
        return RecognizedRegions(rectangles: rectangles, visibleUnits: visibleUnits, includesEnd: match.includesEnd)
    }

    /// Snap OCR boxes to the glyph ink in the same capture. Vision's boxes float
    /// with each line's glyphs, which put rails at uneven distances below the
    /// text and line ends a little off. Each row searches only up to the midpoint
    /// of its neighbours; a box that cannot be confirmed keeps its OCR geometry.
    private static func refineInk(_ rows: [(rect: CGRect, endsLine: Bool)], image: CGImage, field: CGRect) -> [CGRect] {
        guard !rows.isEmpty, let ink = inkImage(image) else { return rows.map(\.rect) }
        let sx = CGFloat(image.width)/field.width, sy = CGFloat(image.height)/field.height
        let rects = rows.map(\.rect)
        return rows.map { row in
            let r = row.rect
            let above = rects.filter { $0.midY < r.minY }.map(\.maxY).max()
            let below = rects.filter { $0.midY > r.maxY }.map(\.minY).min()
            let top = above.map { ($0+r.minY)/2 } ?? r.minY-r.height*0.5
            let bottom = below.map { ($0+r.maxY)/2 } ?? r.maxY+r.height*0.5
            let lower = Int(((top-field.minY)*sy).rounded(.down)), upper = Int(((bottom-field.minY)*sy).rounded(.up))
            guard upper > lower else { return r }
            let box = CGRect(x: (r.minX-field.minX)*sx, y: (r.minY-field.minY)*sy, width: r.width*sx, height: r.height*sy)
            guard let glyph = InkBounds.refine(box, in: ink, window: lower...upper, extendRight: row.endsLine) else { return r }
            let refined = CGRect(x: field.minX+glyph.minX/sx, y: field.minY+glyph.minY/sy,
                                 width: glyph.width/sx, height: glyph.height/sy)
            // Glyph ink is tighter than a line box; leave room for descent so the
            // rail sits like an underline, as it does on the AX path.
            return CGRect(x: refined.minX, y: refined.minY, width: refined.width, height: refined.height*1.12).intersection(field)
        }
    }

    private static func inkImage(_ image: CGImage) -> InkImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width*height <= 16_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width*height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? InkImage(pixels: pixels, width: width, height: height) : nil
    }
}

final class SweepPanel: NSPanel {
    /// A passive screen-coordinate overlay may extend into a screen's margins.
    /// AppKit must not nudge its initial frame to fit the visible work area:
    /// doing so moves every initial rail, while a later realignment looks right.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Colours chosen per target background. Without keylines, rails read like a
/// native underline in the text's own ink; orange stays the only accent.
private struct SweepPalette {
    let line: NSColor
    let flash: NSColor
    let glowOpacity: Float
    let glowRadius: CGFloat

    static let ember = NSColor(srgbRed: 1, green: 0x5B/255.0, blue: 0x18/255.0, alpha: 1)
    /// Dark editors: near-white line core and a narrow phosphor halo (design tokens).
    static let dark = SweepPalette(line: NSColor(srgbRed: 0xDC/255.0, green: 0xE5/255.0, blue: 0xE4/255.0, alpha: 1),
                                   flash: NSColor(srgbRed: 0xDC/255.0, green: 0xE5/255.0, blue: 0xE4/255.0, alpha: 1),
                                   glowOpacity: 0.85, glowRadius: 2.5)
    /// Light editors: soft ink like the text itself; a white flash would vanish,
    /// so the contact frame is orange and the halo is kept faint.
    static let light = SweepPalette(line: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 0.82),
                                    flash: ember.withAlphaComponent(0.9),
                                    glowOpacity: 0.3, glowRadius: 1.5)
}

private final class SweepView: NSView {
    private let ember = SweepPalette.ember
    var palette = SweepPalette.dark
    private var rowRegions: [CGRect] = []
    private var followOffset = CGVector.zero
    private var paragraphEnds: Set<Int> = []
    private var reducedMotion = false
    private var introRoot: CALayer?
    private var loadingRoot: CALayer?
    private var endpoint: CGPoint?
    private var endpointCore: CALayer?
    private var rails: [CALayer] = []
    private var caps: [CALayer] = []
    /// Dim placeholder rails and endpoints shown while the new layout is pending.
    private var skeletonRails: [CALayer] = []
    private var skeletonCaps: [CALayer] = []
    private var alignedAt: CFTimeInterval = 0

    private static let travelTime: CFTimeInterval = 0.2
    private static let hitStop: CFTimeInterval = 0.045
    private static let impactTime: CFTimeInterval = SweepLineLayout.lineDuration-travelTime
    private static let retireTime: CFTimeInterval = 0.08

    func install(regions: [CGRect], paragraphEnds ends: Set<Int>, reduced: Bool, entering: Bool = true) {
        wantsLayer = true
        guard let layer, !regions.isEmpty else { return }
        layer.masksToBounds = false
        followOffset = .zero; layer.sublayerTransform = CATransform3DIdentity
        rowRegions = snapped(regions); paragraphEnds = ends; reducedMotion = reduced
        if !entering || reduced { hold(); return }
        let intro = CALayer(); intro.frame = bounds
        layer.addSublayer(intro); introRoot = intro
        let time = CACurrentMediaTime()
        for (row, rect) in rowRegions.enumerated() {
            installLine(rect, terminal: ends.contains(row), on: intro,
                        time: time+SweepLineLayout.delay(row: row, lineCount: regions.count))
        }
    }

    private func block(_ rect: CGRect, _ color: NSColor) -> CALayer {
        let node = CALayer(); node.frame = rect; node.backgroundColor = color.cgColor
        return node
    }

    /// Underline weight: 2px for body text, 3px for large text.
    private func thickness(_ rect: CGRect) -> CGFloat { SweepLineLayout.stroke(lineHeight: rect.height)+1 }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private func snap(_ value: CGFloat) -> CGFloat { (value*scale).rounded()/scale }

    /// OCR and AX coordinates are fractional; snap rows to device pixels so the
    /// thin rails stay crisp instead of straddling pixels.
    private func snapped(_ rects: [CGRect]) -> [CGRect] {
        rects.map { rect in
            let minX = snap(rect.minX), minY = snap(rect.minY)
            return CGRect(x: minX, y: minY, width: max(1/scale, snap(rect.maxX)-minX), height: max(1/scale, snap(rect.maxY)-minY))
        }
    }

    /// Underline rail in the palette's ink, never orange. Hold rails anchor at
    /// their right end so release retracts them into the endpoint; drawn rails
    /// anchor left and are re-anchored before release.
    private func rail(for rect: CGRect, anchorLeft: Bool = false) -> CALayer {
        let t = thickness(rect)
        let node = block(CGRect(x: 0, y: 0, width: rect.width, height: t), palette.line)
        node.anchorPoint = CGPoint(x: anchorLeft ? 0 : 1, y: 0.5)
        node.position = CGPoint(x: anchorLeft ? rect.minX : rect.maxX, y: rect.minY-1-t/2)
        return node
    }

    private func anchorRight(_ node: CALayer) {
        guard node.anchorPoint.x != 1 else { return }
        let shift = node.bounds.width*(1-node.anchorPoint.x)
        node.anchorPoint = CGPoint(x: 1, y: node.anchorPoint.y)
        node.position = CGPoint(x: node.position.x+shift, y: node.position.y)
    }

    /// Paragraph endpoint: an orange caret-like bar from the rail to just above
    /// the row. Centred on the text end, so the final one covers the editor's
    /// own insertion caret instead of standing next to it.
    private func cap(for rect: CGRect, at point: CGPoint? = nil) -> CALayer {
        let t = thickness(rect)
        let node = block(CGRect(x: 0, y: 0, width: max(4, t+2), height: rect.height+t+2), ember)
        node.position = capPosition(for: rect, endpoint: point)
        node.shadowColor = ember.cgColor; node.shadowOpacity = palette.glowOpacity
        node.shadowRadius = palette.glowRadius; node.shadowOffset = .zero
        return node
    }

    private func capPosition(for rect: CGRect, endpoint point: CGPoint?) -> CGPoint {
        let t = thickness(rect)
        return CGPoint(x: snap(point?.x ?? rect.maxX)+1, y: (point.map { snap($0.y) } ?? rect.midY)-t/2)
    }

    /// Short flat shard flying from `origin` along `angle`.
    private func shard(from origin: CGPoint, angle: CGFloat, length: CGFloat, distance: CGFloat,
                       color: NSColor, on root: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let node = block(CGRect(x: 0, y: 0, width: length, height: 2), color)
        node.position = origin; node.opacity = 0
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

    /// One-to-two frame contact flash of an impact.
    private func flash(at point: CGPoint, size: CGSize, on root: CALayer, begin: CFTimeInterval) {
        let node = block(CGRect(origin: .zero, size: size), palette.flash)
        node.position = point; node.opacity = 0
        root.addSublayer(node)
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [1, 1, 0]; light.keyTimes = [0, 0.4, 1]; light.calculationMode = .discrete
        light.duration = 0.05; light.beginTime = begin
        node.add(light, forKey: "contact-flash")
    }

    /// Wind-up, accelerate into the stop, hit-stop, contact flash, squash and
    /// recoil. Only a paragraph's last row lands on the orange endpoint; other
    /// rows end with a small tick in the line colour.
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

        // The scanning blade: a solid bar with two trailing speed lines, no plate.
        let clip = CALayer(); clip.frame = rect.insetBy(dx: -4, dy: -4); clip.masksToBounds = true
        row.addSublayer(clip)
        let h = clip.bounds.height
        let width = min(56, max(22, rect.height*1.6))
        let carriage = CALayer(); carriage.bounds = CGRect(x: 0, y: 0, width: width, height: h)
        carriage.anchorPoint = CGPoint(x: 1, y: 0.5)
        carriage.addSublayer(block(CGRect(x: width-3, y: 2, width: 2, height: h-4), palette.line))
        for (length, y) in [(width*0.62, h*0.62), (width*0.36, h*0.3)] {
            carriage.addSublayer(block(CGRect(x: width-6-length, y: y, width: length, height: 1.5),
                                       palette.line.withAlphaComponent(palette.line.alphaComponent*0.55)))
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
            let tick = block(CGRect(x: rect.maxX+1, y: rect.minY+rect.height*0.15, width: 2, height: rect.height*0.7), palette.line)
            tick.opacity = 0; row.addSublayer(tick)
            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, 1, 0]; light.keyTimes = [0, 0.2, 1]
            light.duration = 0.09; light.beginTime = hitAt
            tick.add(light, forKey: "row-tick")
            return
        }
        let endpointCap = cap(for: rect); endpointCap.opacity = 0; row.addSublayer(endpointCap)
        endpointCap.add(impact(duration: Self.impactTime, begin: hitAt), forKey: "endpoint-impact")

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
                  color: index == 1 ? ember : palette.line, on: row, begin: hitAt+0.01, duration: 0.11)
        }
    }

    /// Endpoint landing: appears stretched, squashes, overshoots and settles.
    private func impact(duration: CFTimeInterval, begin: CFTimeInterval) -> CAAnimationGroup {
        let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 1; appear.toValue = 1
        let stretchY = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretchY.values = [1.9, 0.6, 1.12, 1]; stretchY.keyTimes = [0, 0.3, 0.65, 1]
        let stretchX = CAKeyframeAnimation(keyPath: "transform.scale.x")
        stretchX.values = [0.45, 1.7, 0.92, 1]; stretchX.keyTimes = [0, 0.3, 0.65, 1]
        let group = CAAnimationGroup(); group.animations = [appear, stretchY, stretchX]
        for animation in group.animations! { animation.duration = duration }
        group.duration = duration; group.beginTime = begin
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        return group
    }

    func setEndpoint(_ point: CGPoint) {
        let point = CGPoint(x: point.x-followOffset.dx, y: point.y-followOffset.dy)
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
        let core = makeCore(for: last, at: endpoint)
        loading.addSublayer(core); endpointCore = core
    }

    /// The final endpoint with a restrained three-step status cadence.
    private func makeCore(for last: CGRect, at point: CGPoint?) -> CALayer {
        let core = cap(for: last, at: point)
        for i in 0..<3 {
            let cell = block(CGRect(x: -6-CGFloat(i)*5, y: -5, width: 3, height: 3), i == 0 ? ember : palette.line)
            core.addSublayer(cell)
            guard !reducedMotion else { continue }
            cell.opacity = 0.25
            let step = CAKeyframeAnimation(keyPath: "opacity")
            step.values = [0.25, 1, 1, 0.25]; step.keyTimes = [0, 0.15, 0.45, 1]
            step.calculationMode = .discrete; step.duration = 1.2; step.repeatCount = .infinity
            step.beginTime = CACurrentMediaTime()+Double(i)*0.16
            cell.add(step, forKey: "status-step")
        }
        return core
    }

    /// Static endpoints for every paragraph except the last, whose endpoint is
    /// the movable status core.
    private func installCaps(on loading: CALayer) {
        caps.forEach { $0.removeFromSuperlayer() }
        caps = paragraphEnds.sorted().filter { $0 < rowRegions.count-1 }.map { index in
            let node = cap(for: rowRegions[index]); loading.addSublayer(node); return node
        }
    }

    /// No smoothing delay: a field move and all its visual children land in the
    /// same transaction, including with Reduce Motion. Coordinates inside roots
    /// stay field-local; align converts fresh screen measurements to that space.
    func follow(by delta: CGVector) {
        followOffset.dx += delta.dx; followOffset.dy += delta.dy
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation(followOffset.dx, followOffset.dy, 0)
        CATransaction.commit()
    }

    func reframe(size: CGSize, offset: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame.size = size
        introRoot?.frame = bounds; loadingRoot?.frame = bounds
        follow(by: CGVector(dx: offset.x, dy: offset.y))
        CATransaction.commit()
    }

    /// The editor is replacing the text under the rails and the new layout is not
    /// known yet. Instead of an empty gap, the rails stay where they are as dim
    /// skeleton placeholders with a skeleton-screen shimmer running along them,
    /// staggered row by row. Nothing moves across lines; the status endpoint keeps
    /// its cadence. The skeleton leaves when the confirmed layout draws or on release.
    func beginLoading() {
        guard !rails.isEmpty || !caps.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let now = CACurrentMediaTime()
        for (row, line) in rails.enumerated() {
            line.removeAllAnimations()
            line.transform = CATransform3DIdentity
            let dim = palette.line.withAlphaComponent(palette.line.alphaComponent*0.32).cgColor
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = line.backgroundColor; fade.toValue = dim; fade.duration = reducedMotion ? 0 : 0.12
            line.backgroundColor = dim
            line.add(fade, forKey: "skeleton-dim")
            if !reducedMotion { shimmer(along: line, begin: now+0.08+Double(row)*0.08) }
        }
        for node in caps {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = node.opacity; fade.toValue = 0.4; fade.duration = reducedMotion ? 0 : 0.12
            node.opacity = 0.4
            node.add(fade, forKey: "skeleton-dim")
        }
        CATransaction.commit()
        skeletonRails += rails; skeletonCaps += caps
        rails = []; caps = []
    }

    /// The final text is already in the field but its confirmed layout is not:
    /// stretch or shrink each skeleton bar in place to the estimated length of the
    /// new text, so a shorter polished result is not overhung by the draft's bars.
    /// Bars only change width (no vertical travel across lines); extra rows fade
    /// in as skeletons, surplus rows fade out.
    private func reshapeSkeleton(to regions: [CGRect]) {
        guard !skeletonRails.isEmpty, !regions.isEmpty else { return }
        let duration = reducedMotion ? 0 : 0.18
        let easing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        retire(skeletonCaps, fade: true); skeletonCaps = []
        var kept: [CALayer] = []
        // A single-row draft has no measured line pitch, so the estimate guesses
        // where new lines go and could cut through them; those rows wait for the
        // confirmed layout. With two or more rows the pitch is observed.
        let rows = skeletonRails.count >= 2 ? regions : Array(regions.prefix(skeletonRails.count))
        for (index, rect) in rows.enumerated() {
            guard index < skeletonRails.count else {
                let line = rail(for: rect)
                line.backgroundColor = palette.line.withAlphaComponent(palette.line.alphaComponent*0.32).cgColor
                loadingRoot?.addSublayer(line)
                if !reducedMotion {
                    let show = CABasicAnimation(keyPath: "opacity"); show.fromValue = 0; show.toValue = 1; show.duration = 0.12
                    line.add(show, forKey: "skeleton-in")
                    shimmer(along: line, begin: CACurrentMediaTime()+Double(index)*0.08)
                }
                kept.append(line)
                continue
            }
            let line = skeletonRails[index]
            anchorRight(line)
            let current = line.presentation() ?? line
            let fromWidth = current.bounds.width, fromX = current.position.x
            // Keep the bar on its own line; only a near-identical row may shift.
            let y = abs(rect.minY-1-thickness(rect)/2-line.position.y) < rect.height*0.6
                ? rect.minY-1-thickness(rect)/2 : line.position.y
            line.bounds.size.width = rect.width
            line.position = CGPoint(x: rect.maxX, y: y)
            if duration > 0 {
                let width = CABasicAnimation(keyPath: "bounds.size.width")
                width.fromValue = fromWidth; width.toValue = rect.width
                let x = CABasicAnimation(keyPath: "position.x")
                x.fromValue = fromX; x.toValue = rect.maxX
                for animation in [width, x] { animation.duration = duration; animation.timingFunction = easing }
                line.add(width, forKey: "skeleton-width"); line.add(x, forKey: "skeleton-x")
            }
            kept.append(line)
        }
        if skeletonRails.count > rows.count {
            retire(Array(skeletonRails[rows.count...]), fade: false)
        }
        skeletonRails = kept
        CATransaction.commit()
    }

    /// A narrow highlight travelling left to right inside a rail, then a short
    /// rest, repeated: the loading cue of a skeleton screen.
    private func shimmer(along line: CALayer, begin: CFTimeInterval) {
        line.masksToBounds = true
        let length = line.bounds.width
        let width = min(140, max(36, length*0.35))
        let band = CAGradientLayer()
        let bright = palette.line.cgColor, clear = palette.line.withAlphaComponent(0).cgColor
        band.colors = [clear, bright, clear]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.bounds = CGRect(x: 0, y: 0, width: width, height: line.bounds.height)
        band.position = CGPoint(x: -width/2, y: line.bounds.height/2)
        line.addSublayer(band)
        let travel = min(1.1, max(0.45, (length+width*2)/760))
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width/2; move.toValue = length+width/2
        move.duration = travel
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        let cycle = CAAnimationGroup(); cycle.animations = [move]
        cycle.duration = travel+0.28; cycle.repeatCount = .infinity
        cycle.beginTime = begin
        band.add(cycle, forKey: "skeleton-shimmer")
    }

    /// Skeleton placeholders fade out in place while the new rails draw.
    private func retireSkeleton() {
        let nodes = skeletonRails+skeletonCaps
        skeletonRails = []; skeletonCaps = []
        retire(nodes, fade: true)
    }

    private func retire(_ nodes: [CALayer], fade: Bool) {
        guard !nodes.isEmpty else { return }
        let duration = reducedMotion ? 0 : Self.retireTime
        guard duration > 0 else { nodes.forEach { $0.removeFromSuperlayer() }; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for node in nodes {
            if !fade { anchorRight(node) }
            let keyPath = fade ? "opacity" : "transform.scale.x"
            let current = fade ? CGFloat(node.presentation()?.opacity ?? node.opacity)
                               : node.presentation()?.transform.m11 ?? node.transform.m11
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = current; animation.toValue = fade ? 0 : 0.001
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 0.5)
            node.removeAllAnimations()
            if fade { node.opacity = 0 } else { node.transform = CATransform3DMakeScale(0.001, 1, 1) }
            node.add(animation, forKey: "retire")
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now()+duration) { nodes.forEach { $0.removeFromSuperlayer() } }
    }

    /// New layout after the write. Old rails wait as skeleton placeholders;
    /// nothing ever travels across lines.
    /// - Confirmed geometry (AX or OCR of the final text): new rails draw on in
    ///   place, top to bottom, and the endpoint lands at the end of the last row.
    ///   A one-line draft growing into four lines visibly becomes four lines.
    /// - Estimated geometry: only the endpoint blinks to its estimated place,
    ///   because rails at a guessed position could cut through the text.
    func align(regions: [CGRect], paragraphEnds ends: Set<Int>, endpoint: CGPoint?, confirmed: Bool) {
        let regions = snapped(regions.map { $0.offsetBy(dx: -followOffset.dx, dy: -followOffset.dy) })
        let endpoint = endpoint.map { CGPoint(x: $0.x-followOffset.dx, y: $0.y-followOffset.dy) }
        guard let loading = loadingRoot, let last = regions.last else { return }
        // Rails from an earlier pass retract; the skeleton stays until a confirmed
        // layout replaces it, so an estimate never reopens an empty gap.
        retire(rails, fade: false); rails = []
        retire(caps, fade: true); caps = []
        if confirmed { retireSkeleton() }
        rowRegions = regions; paragraphEnds = ends; self.endpoint = endpoint
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let target = capPosition(for: last, endpoint: endpoint)
        let resized = endpointCore.map { abs($0.bounds.height-(last.height+thickness(last)+2)) > 0.5 } ?? true
        let core: CALayer
        let moved = endpointCore.map { hypot($0.position.x-target.x, $0.position.y-target.y) > 0.5 } ?? true
        if resized || moved || endpointCore == nil {
            if let previous = endpointCore { retire([previous], fade: true) }
            core = makeCore(for: last, at: endpoint); loading.addSublayer(core); endpointCore = core
        } else { core = endpointCore! }
        let now = CACurrentMediaTime()

        if !confirmed { reshapeSkeleton(to: regions) }
        guard confirmed, !reducedMotion else {
            // Use the old endpoint's displacement. A newly-created core already
            // sits at target, but must still fade in after re-anchoring.
            core.position = target
            if confirmed {   // reduced motion: confirmed rails appear without motion
                for rect in regions { let line = rail(for: rect); loading.addSublayer(line); rails.append(line) }
                installCaps(on: loading)
            }
            if (moved || resized), !reducedMotion {
                let appear = CAKeyframeAnimation(keyPath: "opacity")
                appear.values = [0, 0, 1]; appear.keyTimes = [0, 0.5, 1]; appear.duration = Self.retireTime
                core.add(appear, forKey: "reanchor")
            }
            alignedAt = now+(reducedMotion ? 0 : Self.retireTime)
            return
        }

        // Draw while the skeleton fades: the loading state hands over without a gap.
        let start = now+0.03
        let drawTime = 0.12
        let stagger = regions.count > 1 ? min(0.045, 0.18/Double(regions.count-1)) : 0
        let easing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        for (index, rect) in regions.enumerated() {
            let line = rail(for: rect, anchorLeft: true); loading.addSublayer(line); rails.append(line)
            let draw = CABasicAnimation(keyPath: "transform.scale.x")
            draw.fromValue = 0.001; draw.toValue = 1; draw.duration = drawTime
            draw.timingFunction = easing; draw.beginTime = start+Double(index)*stagger
            draw.fillMode = .backwards
            line.add(draw, forKey: "redraw")
        }
        // Each paragraph endpoint appears as its row finishes drawing.
        caps = ends.sorted().filter { $0 < regions.count-1 }.map { index in
            let node = cap(for: regions[index]); loading.addSublayer(node)
            node.add(hidden(for: start+Double(index)*stagger+drawTime-now), forKey: "wait")
            return node
        }
        let landing = start+Double(regions.count-1)*stagger+drawTime
        core.position = target
        core.add(hidden(for: landing-now), forKey: "wait")
        core.add(impact(duration: 0.1, begin: landing), forKey: "endpoint-landing")
        alignedAt = landing+0.1
    }

    private func hidden(for duration: CFTimeInterval) -> CABasicAnimation {
        let wait = CABasicAnimation(keyPath: "opacity"); wait.fromValue = 0; wait.toValue = 0
        wait.duration = max(0.001, duration)
        return wait
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
        // An estimate-only finish still has the skeleton; it leaves with the rails.
        retireSkeleton()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for line in rails {
            anchorRight(line)
            let pull = CABasicAnimation(keyPath: "transform.scale.x")
            pull.fromValue = 1; pull.toValue = 0.001; pull.duration = retract
            pull.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 0.5)
            pull.beginTime = start; pull.fillMode = .both; pull.isRemovedOnCompletion = false
            line.add(pull, forKey: "retract")
        }
        CATransaction.commit()
        for node in caps {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            fade.duration = 0.06; fade.beginTime = start+retract*0.6
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            node.add(fade, forKey: "cap-out")
        }
        guard let core = endpointCore else { return delay+retract+0.08 }
        let hitAt = start+(rails.isEmpty ? 0 : retract)
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
        let end = hitAt-CACurrentMediaTime()
        guard burst else { return end+0.16 }
        let origin = core.position
        flash(at: origin, size: CGSize(width: core.bounds.width+8, height: core.bounds.height+6), on: layer, begin: hitAt)
        for index in 0..<9 {
            let angle = CGFloat(-70+Double(index)*17.5) * .pi/180
            let major = index % 3 == 1
            shard(from: origin, angle: angle, length: major ? 14 : 8, distance: major ? 34 : 22,
                  color: major ? ember : palette.line, on: layer, begin: hitAt+0.01, duration: 0.18)
        }
        return end+0.2
    }
}
