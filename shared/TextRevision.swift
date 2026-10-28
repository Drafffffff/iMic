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

    static func isTerminal(bundleIdentifier: String?, labels: [String?]) -> Bool {
        if let bundleIdentifier, terminalBundles.contains(bundleIdentifier) { return true }
        return labels.contains { label in
            guard let label = label?.lowercased(), !label.isEmpty else { return false }
            return label.contains("terminal") || label.contains("终端") || label.contains("xterm")
        }
    }
}
