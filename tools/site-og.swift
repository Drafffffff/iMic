import AppKit
import Foundation
// Composite the real first-screen browser screenshot with the canonical pixel wordmark.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let shot = root.appendingPathComponent("build/ux-shots/site/desktop-hero.png")
guard let screenshot = NSImage(contentsOf: shot),
      let mark = NSImage(contentsOf: root.appendingPathComponent("site/assets/pixel/imic.svg")),
      let icon = NSImage(contentsOf: root.appendingPathComponent("site/assets/icons/icon-512.png")),
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Generate desktop-hero screenshot and icons first") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0.035, green: 0.035, blue: 0.035, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x:0,y:0,width:1200,height:630)).fill()
screenshot.draw(in:NSRect(x:380,y:25,width:800,height:500),from:.zero,operation:.sourceOver,fraction:1)
icon.draw(in:NSRect(x:44,y:482,width:72,height:72),from:.zero,operation:.sourceOver,fraction:1)
mark.draw(in:NSRect(x:132,y:503,width:184,height:56),from:.zero,operation:.sourceOver,fraction:1)
let text="按住说话，\n松手即输入。" as NSString
text.draw(in:NSRect(x:48,y:235,width:390,height:190),withAttributes:[.font:NSFont.systemFont(ofSize:46,weight:.semibold),.foregroundColor:NSColor(srgbRed:0.95,green:0.94,blue:0.90,alpha:1)])
("iPhone → Mac" as NSString).draw(at:NSPoint(x:52,y:164),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:20,weight:.regular),.foregroundColor:NSColor(srgbRed:0.7,green:0.68,blue:0.64,alpha:1)])
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("site/assets/icons/og.png"))
