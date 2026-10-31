import AppKit

struct MicStatusBarPresentation: Equatable {
    enum Phase: Equatable { case offline, pairing, ready, listening, processing }

    let phase: Phase

    var label: String {
        switch phase {
        case .offline: return L10n.text("iMic disconnected")
        case .pairing: return L10n.text("iMic awaiting pairing")
        case .ready: return L10n.text("iMic connected")
        case .listening: return L10n.text("iMic listening")
        case .processing: return L10n.text("iMic recognizing")
        }
    }

    var menuTitle: String {
        switch phase {
        case .pairing: return "PAIR"
        case .listening: return "REC"
        case .processing: return "..."
        default: return ""
        }
    }
}

enum MicStatusBarIcons {
    static func image(_ presentation: MicStatusBarPresentation) -> NSImage {
        let width: CGFloat = 20
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            MicBrand.drawMenuMark(in: NSRect(x: 1, y: 0, width: 18, height: 18))
            switch presentation.phase {
            case .offline:
                // 右下角的小斜线表示未连接。
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 15.5, y: 1.5))
                slash.line(to: NSPoint(x: 19.5, y: 5.5))
                slash.lineWidth = 1.6
                slash.stroke()
            case .pairing:
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 1.5, width: 3.5, height: 3.5)).fill()
            case .ready:
                NSBezierPath(ovalIn: NSRect(x: 16.5, y: 1.5, width: 3.5, height: 3.5)).fill()
            case .listening:
                for x in stride(from: 16.0, through: 20.0, by: 2.0) {
                    NSBezierPath(rect: NSRect(x: x, y: 2, width: 1, height: 3)).fill()
                }
            case .processing:
                for x in stride(from: 16.0, through: 20.0, by: 2.0) {
                    NSBezierPath(ovalIn: NSRect(x: x, y: 2.5, width: 1.5, height: 1.5)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = presentation.label
        return image
    }
}
