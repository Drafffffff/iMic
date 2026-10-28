import Foundation

/// DeepSeek 润色的结果守门员：转写整理器绝不应该回答或执行用户口述中的问题。
public enum DeepSeekPolicy {
    private static let questionMarkers = [
        "吗", "呢", "？", "?", "是否", "能不能", "可不可以", "怎么", "为什么", "如何"
    ]
    private static let requestMarkers = [
        "帮我", "帮忙", "麻烦", "给我", "替我"
    ]
    private static let answerPrefixes = [
        "可以", "好的", "行", "不行", "当然", "是的", "没问题", "明白", "收到"
    ]

    /// 译文中的问句标记：各语言问号，以及日语、韩语、中文常见的句末疑问词。
    private static let translatedQuestionMarkers = [
        "?", "？", "か", "까", "나요", "니", "吗", "呢", "乎", "耶", "否"
    ]

    /// 文言文允许凝练压缩；其他模式沿用翻译守门，终端始终使用单行校验。
    public static func isAcceptable(raw: String, polished: String, options: PolishOptions) -> Bool {
        if options.isCommand { return isAcceptable(raw: raw, polished: polished, output: .command) }
        if options.mode != .classical || options.output != .chinese {
            return isAcceptable(raw: raw, polished: polished, output: options.output)
        }
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !result.isEmpty else { return false }
        return isAcceptableTranslation(source: source, result: result, minimumRatio: 0.12)
    }

    public static func isAcceptable(raw: String, polished: String, output: PolishOutput = .original) -> Bool {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !result.isEmpty else { return false }

        switch output {
        case .command: return isAcceptableCommand(result)
        case .chinese, .english, .japanese, .korean: return isAcceptableTranslation(source: source, result: result)
        case .original: break
        }

        // 过度缩短通常意味着模型在总结/回答，而不是整理。
        if source.count >= 12, Double(result.count) < Double(source.count) * 0.45 {
            return false
        }

        let sourceHasQuestion = questionMarkers.contains { source.contains($0) }
        let resultHasQuestion = questionMarkers.contains { result.contains($0) }
        if sourceHasQuestion, !resultHasQuestion {
            return false
        }

        let sourceHasRequest = requestMarkers.contains { source.contains($0) }
        let resultHasRequest = requestMarkers.contains { result.contains($0) }
        if sourceHasRequest, !resultHasRequest,
           Double(result.count) < Double(source.count) * 0.80 {
            return false
        }

        // 原句是问句时，结果不能突然以“可以/好的/当然”等答复开头。
        if sourceHasQuestion,
           answerPrefixes.contains(where: { result.hasPrefix($0) }),
           !answerPrefixes.contains(where: { source.hasPrefix($0) }) {
            return false
        }

        return true
    }

    /// 终端命令必须是单行：输入路径会把换行当作回车投递，多行结果可能被 shell 直接执行。
    static func isAcceptableCommand(_ result: String) -> Bool {
        guard result.rangeOfCharacter(from: .newlines) == nil,
              // No tabs either: zsh completion would rewrite the line being typed.
              result.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              result.count <= 1_000,
              !result.contains("```"),
              !result.hasPrefix("$ ") else { return false }
        return true
    }

    /// 跨语言时字符数不可比（中文一字三字节、英文一词多字母），用 UTF-8 字节量判断是否被总结或代答。
    static func isAcceptableTranslation(source: String, result: String, minimumRatio: Double = 0.3) -> Bool {
        if source.count >= 12, Double(result.utf8.count) < Double(source.utf8.count) * minimumRatio {
            return false
        }
        // 只看问号与句末语气词；「怎么」「如何」常出现在陈述句里，译文没有问号也属正常。
        let sourceHasQuestion = ["?", "？", "吗", "呢"].contains { source.contains($0) }
        let resultHasQuestion = translatedQuestionMarkers.contains { result.contains($0) }
        return !sourceHasQuestion || resultHasQuestion
    }
}
