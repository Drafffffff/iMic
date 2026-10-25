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

    public static func isAcceptable(raw: String, polished: String) -> Bool {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !result.isEmpty else { return false }

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
}
