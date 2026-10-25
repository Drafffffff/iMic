import AppKit

enum MicBrand {
    static let orange = NSColor(srgbRed: 1.0, green: 0.29, blue: 0.0, alpha: 1.0)
    static let ink = NSColor(srgbRed: 0.035, green: 0.035, blue: 0.035, alpha: 1.0)
    static let ivory = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1.0)

    /// 菜单栏只使用模板图像，由系统决定黑白；像素麦克风保证 18pt 下仍可辨认。
    static func drawMenuMark(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let unit = rect.width / 18
        NSColor.black.setFill()
        NSColor.black.setStroke()
        drawMic(in: rect, unit: unit)
    }

    private static func drawMic(in rect: NSRect, unit: CGFloat) {
        // 头、U 形拾音架、话筒杆与底座彼此留出空隙，缩小后仍能读出麦克风。
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 6.3 * unit, y: rect.minY + 9.1 * unit,
                                         width: 5.4 * unit, height: 8.1 * unit),
                     xRadius: 2.7 * unit, yRadius: 2.7 * unit).fill()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.minX + 9 * unit, y: rect.minY + 9.2 * unit),
                      radius: 4.1 * unit, startAngle: 200, endAngle: 340, clockwise: false)
        arc.lineWidth = 1.5 * unit
        arc.lineCapStyle = .round
        arc.stroke()
        pixel(rect, x: 8.2, y: 3.6, w: 1.6, h: 3.2, unit: unit)
        pixel(rect, x: 5.8, y: 2.6, w: 6.4, h: 1.4, unit: unit)
        // 两侧的像素声波
        pixel(rect, x: 1.3, y: 9.6, w: 1.3, h: 2.4, unit: unit)
        pixel(rect, x: 15.4, y: 9.6, w: 1.3, h: 2.4, unit: unit)
        pixel(rect, x: 0.2, y: 13.0, w: 1.1, h: 1.1, unit: unit)
        pixel(rect, x: 16.7, y: 13.0, w: 1.1, h: 1.1, unit: unit)
    }

    private static func pixel(_ rect: NSRect, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, unit: CGFloat) {
        NSBezierPath(rect: NSRect(x: rect.minX + x * unit, y: rect.minY + y * unit,
                                  width: w * unit, height: h * unit)).fill()
    }

    /// 主窗口使用与 App Icon 相同的 Phosphor 麦克风（MIT，经 Iconify）。
    private static let logoGlyphSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="148" height="244" viewBox="54 6 148 244"><path fill="#FF4A00" d="M80 128V64a48 48 0 0 1 96 0v64a48 48 0 0 1-96 0m128 0a8 8 0 0 0-16 0a64 64 0 0 1-128 0a8 8 0 0 0-16 0a80.11 80.11 0 0 0 72 79.6V240a8 8 0 0 0 16 0v-32.4a80.11 80.11 0 0 0 72-79.6"/>
    </svg>
    """

    static func logo(size: CGFloat = 26) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let glyph = NSImage(data: Data(logoGlyphSVG.utf8)) {
            // 保持 Iconify 图标的原始宽高比，避免塞进正方形时被压扁。
            let width = size * (148.0 / 244.0)
            glyph.draw(
                in: NSRect(x: (size - width) / 2, y: 0, width: width, height: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
