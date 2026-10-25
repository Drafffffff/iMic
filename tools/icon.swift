import AppKit
import Foundation

// App icon: Phosphor "microphone-fill" (MIT), obtained through Iconify.
// Source: https://iconify.design/icon-sets/ph/microphone-fill.html
// The glyph is embedded so the generator has no runtime file dependency.
let microphoneSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 256 256"><path fill="#FF4A00" d="M80 128V64a48 48 0 0 1 96 0v64a48 48 0 0 1-96 0m128 0a8 8 0 0 0-16 0a64 64 0 0 1-128 0a8 8 0 0 0-16 0a80.11 80.11 0 0 0 72 79.6V240a8 8 0 0 0 16 0v-32.4a80.11 80.11 0 0 0 72-79.6"/></svg>
"""

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: icon <mac|ios> <output-dir>\n".utf8))
    exit(2)
}
let mode = arguments[1]
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let ink = NSColor(srgbRed: 0.027, green: 0.027, blue: 0.027, alpha: 1)

func drawIcon(size: CGFloat, rounded: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    if rounded {
        let path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
            cornerWidth: size * 0.225,
            cornerHeight: size * 0.225,
            transform: nil
        )
        context.addPath(path)
        context.clip()
    }
    context.setFillColor(ink.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    if let microphone = NSImage(data: Data(microphoneSVG.utf8)) {
        let side = size * 0.64
        microphone.draw(
            in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
    image.unlockFocus()
    return image
}

func png(pixels: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixels),
        pixelsHigh: Int(pixels),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawIcon(size: pixels, rounded: mode == "mac")
        .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
if mode == "mac" {
    let specs: [(String, CGFloat)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, size) in specs {
        guard let data = png(pixels: size) else { continue }
        try data.write(to: output.appendingPathComponent(name))
    }
} else {
    let specs: [(String, Int, String, String, String)] = [
        ("Icon-20@2x.png", 40, "iphone", "20x20", "2x"),
        ("Icon-20@3x.png", 60, "iphone", "20x20", "3x"),
        ("Icon-29@2x.png", 58, "iphone", "29x29", "2x"),
        ("Icon-29@3x.png", 87, "iphone", "29x29", "3x"),
        ("Icon-40@2x.png", 80, "iphone", "40x40", "2x"),
        ("Icon-40@3x.png", 120, "iphone", "40x40", "3x"),
        ("Icon-60@2x.png", 120, "iphone", "60x60", "2x"),
        ("Icon-60@3x.png", 180, "iphone", "60x60", "3x"),
        ("Icon-1024.png", 1024, "ios-marketing", "1024x1024", "1x")
    ]
    var images: [[String: String]] = []
    for (name, pixels, idiom, size, scale) in specs {
        guard let data = png(pixels: CGFloat(pixels)) else { continue }
        try data.write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": idiom, "size": size, "scale": scale])
    }
    let object: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1]
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("Contents.json"))
}
