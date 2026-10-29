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
for label in ["iMic", "FEEL", "HOLD", "STRING", "LIVE", "POLISH", "SOUND", "ANYWHERE", "PRIVATE", "START", "DOWNLOAD", "FAQ", "RETURN", "LINK", "404"] {
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
print("Generated \(15) SVG labels from PixelFont.glyphs (\(glyphs.count) glyphs)")
