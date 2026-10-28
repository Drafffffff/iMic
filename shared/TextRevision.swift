import Foundation

/// 保留已输入的共同前缀，只替换尾部；计数按字素簇而非 UTF-16 单元。
struct TextRevision {
    let deleteCount: Int
    let insertion: String

    init(from previous: String, to next: String) {
        var oldIndex = previous.startIndex
        var newIndex = next.startIndex
        while oldIndex != previous.endIndex, newIndex != next.endIndex,
              previous[oldIndex] == next[newIndex] {
            previous.formIndex(after: &oldIndex)
            next.formIndex(after: &newIndex)
        }
        deleteCount = previous.distance(from: oldIndex, to: previous.endIndex)
        insertion = String(next[newIndex...])
    }
}

/// Text iMic types is data, never keystrokes with side effects.
enum TypedTextSafety {
    /// Control characters other than line breaks and tabs (ESC, DEL, C1, …) are
    /// dropped everywhere: typed into a terminal they act as key sequences.
    /// In a terminal every line break and tab also becomes a space, one for one,
    /// so a multi-line result never presses Return to run a line and revision
    /// arithmetic over characters stays aligned with what was typed.
    static func sanitize(_ text: String, terminal: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            let breaks = character.isNewline || character == "\t"
            if breaks {
                result.append(terminal ? " " : character)
                continue
            }
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.generalCategory == .control }) { continue }
            result.append(character)
        }
        return result
    }

    /// Terminal emulators, plus terminal panes inside editors (VS Code, Cursor,
    /// JetBrains), recognised from the bundle or the focused control's labels.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "io.appmakes.otty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "org.alacritty", "io.alacritty", "co.zeit.hyper",
        "com.github.wez.wezterm", "org.tabby"
    ]

    /// East Asian wide characters (CJK, kana, Hangul, full-width forms, emoji).
    /// Terminals draw each in two cells, but Terminal.app and Otty report one
    /// cell per character through AX, so their boxes cover half the text.
    static func containsWideCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD: return true
            default: return false
            }
        }
    }

    static func isTerminal(bundleIdentifier: String?, labels: [String?]) -> Bool {
        if let bundleIdentifier, terminalBundles.contains(bundleIdentifier) { return true }
        return labels.contains { label in
            guard let label = label?.lowercased(), !label.isEmpty else { return false }
            return label.contains("terminal") || label.contains("终端") || label.contains("xterm")
        }
    }
}
