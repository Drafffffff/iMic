import AppKit
import Foundation

// Read the canonical App glyph table; do not maintain a second font.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("ios/iMic/PixelFont.swift"), encoding: .utf8)
let pattern = #""(.)": \[((?:"[01]{5}"(?:, )?){7})\]"#
let regex = try NSRegularExpression(pattern: pattern)
let ns = source as NSString
var glyphs: [Character: [String]] = [:]
for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
    let character = Character(ns.substring(with: match.range(at: 1)))
    glyphs[character] = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "\"", with: "").components(separatedBy: ", ")
}
guard glyphs.count >= 40 else { fatalError("PixelFont glyph table format changed") }
let output = root.appendingPathComponent("site/assets/pixel")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for label in ["FEEL", "STRING", "POLISH", "MODES", "SOUND", "ANYWHERE", "PRIVATE", "START", "DOWNLOAD", "FAQ", "RETURN", "LINK", "404"] {
    // PixelText uppercases its input in the App too.
    let text = label.uppercased()
    let width = text.count * 6 - 1
    var cells = ""
    for (index, character) in text.enumerated() {
        guard let rows = glyphs[character] else { fatalError("Missing glyph: \(character)") }
        for (y, row) in rows.enumerated() {
            for (x, bit) in row.enumerated() where bit == "1" {
                cells += "<rect x=\"\(index * 6 + x)\" y=\"\(y)\" width=\"1\" height=\"1\"/>"
            }
        }
    }
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) 7\" width=\"\(width * 3)\" height=\"21\" shape-rendering=\"crispEdges\"><title>\(label)</title><g fill=\"#f2f0e6\">\(cells)</g></svg>\n"
    try svg.write(to: output.appendingPathComponent("\(label.lowercased()).svg"), atomically: true, encoding: .utf8)
}
print("Generated site labels from PixelFont.glyphs (\(glyphs.count) glyphs)")

// The mixed-case App wordmark is artwork, not PixelText. Recover its pixel
// silhouette from the canonical PNG and normalize the two foreground inks to
// the brand colors. Black pixels become transparent on the site's ink ground.
let markURL = root.appendingPathComponent("ios/iMic/Assets.xcassets/Wordmark.imageset/wordmark@3x.png")
guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: markURL)) else { fatalError("App wordmark missing") }
guard bitmap.bitsPerSample == 8, !bitmap.isPlanar, bitmap.samplesPerPixel == 3, !bitmap.hasAlpha,
      let pixels = bitmap.bitmapData else { fatalError("Wordmark must be an interleaved 8-bit RGB PNG") }
struct Run: Hashable { let x: Int; let width: Int; let ink: Int }
struct Cell { let run: Run; let y: Int; var height: Int }
var cells: [Cell] = [], active: [Run: Int] = [:]
for y in 0..<bitmap.pixelsHigh {
    var row: [Int] = []
    for x in 0..<bitmap.pixelsWide {
        // Read encoded samples directly: color-space conversion would move a
        // few antialiased edge pixels across the silhouette threshold.
        let pixel = pixels + y*bitmap.bytesPerRow + x*(bitmap.bitsPerPixel/8)
        let r = Double(pixel[0])/255, g = Double(pixel[1])/255, b = Double(pixel[2])/255
        row.append(max(r, max(g, b)) < 0.3 ? 0 : r > 0.6 && g < 0.5 && b < 0.3 ? 2 : 1)
    }
    var next: [Run: Int] = [:], x = 0
    while x < row.count {
        let start = x, ink = row[x]
        while x < row.count && row[x] == ink { x += 1 }
        guard ink != 0 else { continue }
        let run = Run(x: start, width: x-start, ink: ink)
        if let index = active[run] { cells[index].height += 1; next[run] = index }
        else { next[run] = cells.count; cells.append(Cell(run: run, y: y, height: 1)) }
    }
    active = next
}
let shapes = cells.map { c in
    "<rect x=\"\(c.run.x)\" y=\"\(c.y)\" width=\"\(c.run.width)\" height=\"\(c.height)\" fill=\"\(c.run.ink == 2 ? "#ff4a00" : "#f2f0e6")\"/>"
}.joined()
let mark = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(bitmap.pixelsWide) \(bitmap.pixelsHigh)\" width=\"\(bitmap.pixelsWide)\" height=\"\(bitmap.pixelsHigh)\" shape-rendering=\"crispEdges\"><title>iMic</title>\(shapes)</svg>\n"
try mark.write(to: output.appendingPathComponent("imic.svg"), atomically: true, encoding: .utf8)
print("Generated mixed-case App wordmark: \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(cells.count) merged pixel rectangles")
