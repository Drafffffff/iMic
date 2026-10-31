import AppKit
import ApplicationServices

// Landing-page demo window. Replays a timeline exported from the iPhone demo recording
// into this process's own chat-style composer, and runs the real TextPolishEffect on it.
// It never posts events to, or reads from, any other application.
//
//   site-demo-mac <timeline.json> <ready-file>
//
// The timeline holds {"t": seconds, "kind": ..., "text": ...} items relative to t0.
// Once the window is on screen the frame (top-left screen coordinates) is written to
// <ready-file>; the capture script starts recording, then sends SIGUSR1 to start t0.

struct Item: Decodable { let t: Double; let kind: String; let text: String? }
struct Timeline: Decodable {
    let title: String
    let history: [String]
    let items: [Item]
    let duration: Double
}

enum Config {
    static var timeline: Timeline!
    static var readyFile = ""
}

enum Palette {
    static let ink = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1)
    static let panel = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
    static let raised = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
    static let ivory = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1)
    static let font = NSFont.systemFont(ofSize: 24)   // large enough to read in the page video
}

/// Message history: simple bubbles, newest at the bottom.
final class HistoryView: NSView {
    struct Bubble { let text: String; let outgoing: Bool; var layer: CALayer? }
    private(set) var bubbles: [Bubble] = []
    override var isFlipped: Bool { true }

    init(frame: NSRect, history: [String]) {
        super.init(frame: frame)
        wantsLayer = true
        for text in history { append(text, outgoing: false, animated: false) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func measure(_ text: String, width: CGFloat) -> NSSize {
        let attributed = NSAttributedString(string: text, attributes: [.font: Palette.font])
        let rect = attributed.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin])
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    func append(_ text: String, outgoing: Bool, animated: Bool) {
        guard let root = layer else { return }
        let maxWidth = bounds.width * 0.66
        let size = measure(text, width: maxWidth - 32)
        let bubble = CALayer()
        bubble.backgroundColor = (outgoing ? Palette.raised : Palette.panel).cgColor
        bubble.cornerRadius = 16
        bubble.frame = NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + 22)
        let label = CATextLayer()
        label.string = NSAttributedString(string: text, attributes: [.font: Palette.font, .foregroundColor: Palette.ivory])
        label.isWrapped = true
        label.contentsScale = 2
        label.frame = NSRect(x: 16, y: 11, width: size.width + 2, height: size.height + 2)
        bubble.addSublayer(label)
        root.addSublayer(bubble)
        bubbles.append(Bubble(text: text, outgoing: outgoing, layer: bubble))
        layout(animated: animated, newest: animated ? bubble : nil)
    }

    private func layout(animated: Bool, newest: CALayer?) {
        var y = bounds.height - 14
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.26 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        for bubble in bubbles.reversed() {
            guard let layer = bubble.layer else { continue }
            let frame = layer.frame
            y -= frame.height
            let x = bubble.outgoing ? bounds.width - frame.width - 18 : 18
            if layer === newest {
                CATransaction.setDisableActions(true)
                layer.frame = NSRect(x: x, y: bounds.height + 20, width: frame.width, height: frame.height)
                layer.opacity = 0
                CATransaction.setDisableActions(false)
            }
            layer.frame = NSRect(x: x, y: y, width: frame.width, height: frame.height)
            layer.opacity = 1
            y -= 10
        }
        CATransaction.commit()
    }
}

final class Demo: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var history: HistoryView!
    var composer: NSTextView!
    let effect = TextPolishEffect()
    var start: CFTimeInterval = 0
    var pending: [Item] = Config.timeline.items.sorted { $0.t < $1.t }
    var timer: Timer?
    var utteranceBase = ""          // composer text before the current utterance
    var sweepFinal: String?
    var counterCells: [CALayer] = []
    var applied = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 860, height: 640)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Palette.ink
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovable = false
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.ink.cgColor
        window.contentView = content

        let title = NSTextField(labelWithString: Config.timeline.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Palette.ivory
        title.frame = NSRect(x: 0, y: frame.height - 40, width: frame.width, height: 22)
        title.alignment = .center
        content.addSubview(title)
        let rule = NSView(frame: NSRect(x: 0, y: frame.height - 52, width: frame.width, height: 1))
        rule.wantsLayer = true; rule.layer?.backgroundColor = Palette.raised.cgColor
        content.addSubview(rule)

        let composerHeight: CGFloat = 118
        let bottomInset: CGFloat = 86   // keeps the sweep overlay inside the recorded window
        history = HistoryView(frame: NSRect(x: 40, y: bottomInset + composerHeight + 8, width: frame.width - 80,
                                            height: frame.height - 52 - bottomInset - composerHeight - 8), history: Config.timeline.history)
        content.addSubview(history)

        let field = NSView(frame: NSRect(x: 58, y: bottomInset, width: frame.width - 116, height: composerHeight - 8))
        field.wantsLayer = true
        field.layer?.backgroundColor = Palette.panel.cgColor
        field.layer?.cornerRadius = 14
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Palette.raised.cgColor
        content.addSubview(field)
        let scroll = NSScrollView(frame: field.bounds.insetBy(dx: 12, dy: 10))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        composer = NSTextView(frame: scroll.bounds)
        composer.font = Palette.font
        composer.textColor = Palette.ivory
        composer.insertionPointColor = Palette.ivory
        composer.drawsBackground = false
        composer.isRichText = false
        composer.textContainerInset = NSSize(width: 2, height: 6)
        composer.typingAttributes = [.font: Palette.font, .foregroundColor: Palette.ivory]
        composer.setAccessibilityLabel("消息")
        scroll.documentView = composer
        field.addSubview(scroll)

        // Always the sharpest display (Retina), whichever screen currently has focus.
        // Event counter (12 bits, 3pt cells) in the top-left corner, inside the recorded
        // area but in the strip the composer crops away; places each replayed item in the
        // recording precisely.
        let counter = CALayer()
        counter.frame = NSRect(x: 18, y: frame.height - 26, width: 20, height: 8)
        counter.backgroundColor = NSColor.black.cgColor
        for bit in 0..<12 {
            let cell = CALayer()
            cell.frame = NSRect(x: 1 + CGFloat(bit % 6) * 3, y: 4 - CGFloat(bit / 6) * 3, width: 3, height: 3)
            cell.backgroundColor = NSColor.black.cgColor
            counter.addSublayer(cell)
            counterCells.append(cell)
        }
        content.layer?.addSublayer(counter)

        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else { exit(3) }
        let origin = NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.midY - frame.height / 2)
        window.setFrameOrigin(origin)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(composer)
        NSApp.activate(ignoringOtherApps: true)

        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.begin() }
        source.resume()
        objc_setAssociatedObject(self, "signal", source, .OBJC_ASSOCIATION_RETAIN)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let top = NSScreen.screens[0].frame.maxY   // global top-left origin for screencapture
            let w = self.window.frame
            let rect = "\(Int(w.minX)),\(Int(top - w.maxY)),\(Int(w.width)),\(Int(w.height)) scale=\(screen.backingScaleFactor) pid=\(getpid())"
            try? rect.write(toFile: Config.readyFile, atomically: true, encoding: .utf8)
        }
    }

    func begin() {
        start = CACurrentMediaTime()
        timer = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func tick() {
        let now = CACurrentMediaTime() - start
        while let item = pending.first, item.t <= now {
            pending.removeFirst()
            apply(item)
        }
        if now > Config.timeline.duration { NSApp.terminate(nil) }
    }

    var text: String { composer.string }
    func setText(_ value: String, caretAtEnd: Bool = true) {
        composer.string = value
        if caretAtEnd { composer.setSelectedRange(NSRange(location: (value as NSString).length, length: 0)) }
    }
    var caret: Int { composer.selectedRange().location }

    func apply(_ item: Item) {
        applied += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (bit, cell) in counterCells.enumerated() {
            cell.backgroundColor = (applied >> bit) & 1 == 1 ? NSColor.white.cgColor : NSColor.black.cgColor
        }
        CATransaction.commit()
        switch item.kind {
        case "hold":
            utteranceBase = text
        case "live":
            setText(utteranceBase + (item.text ?? ""))
        case "polish.start":
            // The draft is in the field; the real sweep runs over it while "polishing".
            let element = focusedElement()
            effect.beginSession()
            effect.prepare(pid: getpid(), element: element, text: text,
                           allowed: { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() },
                           interrupted: {})
        case "typed":
            let final = utteranceBase + (item.text ?? "")
            if effect.phase != .idle {
                effect.deliverAfterSweep { [weak self] in
                    guard let self else { return }
                    self.setText(final)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.effect.finishDelivery(succeeded: true, finalText: final, verified: false)
                    }
                }
            } else {
                setText(final)
            }
        case "left":
            composer.setSelectedRange(NSRange(location: max(0, caret - 1), length: 0))
        case "right":
            composer.setSelectedRange(NSRange(location: min((text as NSString).length, caret + 1), length: 0))
        case "delete":
            if caret > 0 {
                let range = NSRange(location: caret - 1, length: 1)
                composer.textStorage?.replaceCharacters(in: range, with: "")
                composer.setSelectedRange(NSRange(location: caret - 1 < 0 ? 0 : range.location, length: 0))
            }
        case "clear":
            setText("")
        case "return":
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            setText("")
            if !message.isEmpty { history.append(message, outgoing: true, animated: true) }
        default:
            break
        }
    }

    func focusedElement() -> AXUIElement? {
        let app = AXUIElementCreateApplication(getpid())
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let data = FileManager.default.contents(atPath: arguments[1]),
      let parsed = try? JSONDecoder().decode(Timeline.self, from: data) else {
    FileHandle.standardError.write(Data("usage: site-demo-mac <timeline.json> <ready-file>\n".utf8)); exit(2)
}
Config.timeline = parsed
Config.readyFile = arguments[2]

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Demo()
app.delegate = delegate
app.run()
