import Foundation

enum DeepSeekConfiguration {
    static let model = "deepseek-flash"
    static let endpoint = "https://api.deepseek.com/chat/completions"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "deepseekEnabled") as? Bool ?? false
    }
    static var modelName: String {
        let value = UserDefaults.standard.string(forKey: "deepseekModel") ?? model
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model : value
    }
    static var options: PolishOptions {
        let defaults = UserDefaults.standard
        return PolishOptions(
            strength: defaults.string(forKey: "deepseekStrength").flatMap(PolishStrength.init(rawValue:)) ?? PolishOptions.default.strength,
            scenario: defaults.string(forKey: "deepseekScenario").flatMap(PolishScenario.init(rawValue:)) ?? PolishOptions.default.scenario
        )
    }
}

/// DeepSeek 官方 Chat Completions 润色。失败时调用方保留原始 ASR 文本。
enum DeepSeekClient {

    static func polish(
        text: String,
        key: String,
        model: String,
        endpoint: String,
        options: PolishOptions,
        completion: @escaping (String?) -> Void
    ) {
        guard !text.isEmpty, !key.isEmpty,
              let url = URL(string: endpoint) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": options.systemPrompt],
                ["role": "user", "content": "<transcript>\n\(text)\n</transcript>"]
            ],
            "temperature": 0,
            "top_p": 0.1,
            "stream": false,
            "max_tokens": 2048
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let started = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = object["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                result = clean(content)
            } else {
                result = nil
                IMicLog.write(
                    "mac.deepseek",
                    "failed ms=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(error?.localizedDescription ?? "invalid response")"
                )
            }
            let accepted = result.map { DeepSeekPolicy.isAcceptable(raw: text, polished: $0) } ?? false
            if let result, !accepted {
                IMicLog.write(
                    "mac.deepseek",
                    "rejected in=\(text.count) out=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
                )
            } else if let result {
                IMicLog.write(
                    "mac.deepseek",
                    "ok in=\(text.count) out=\(result.count) ms=\(Int(Date().timeIntervalSince(started) * 1000)) model=\(model)"
                )
            }
            DispatchQueue.main.async { completion(accepted ? result : nil) }
        }.resume()
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```") {
            var lines = value.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                lines.removeLast()
                value = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }
}
