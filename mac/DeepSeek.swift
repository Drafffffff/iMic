import Foundation

enum PolishProvider: String, CaseIterable {
    case deepseek, bailian, custom

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek 官方"
        case .bailian: return "百炼 DeepSeek"
        case .custom: return "自定义兼容服务"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return DeepSeekConfiguration.model
        case .bailian: return "deepseek-v4.1-flash"
        case .custom: return ""
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .bailian: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .custom: return ""
        }
    }

    var modelKey: String { self == .deepseek ? "deepseekModel" : "polish.\(rawValue).model" }
    var endpointKey: String { "polish.\(rawValue).endpoint" }
}

enum DeepSeekConfiguration {
    static let model = "deepseek-flash"
    static var provider: PolishProvider { provider(in: .standard) }
    static func provider(in defaults: UserDefaults) -> PolishProvider {
        defaults.string(forKey: "polishProvider").flatMap(PolishProvider.init(rawValue:)) ?? .bailian
    }
    /// One Bailian key covers recognition and polish, so new installs default to Bailian.
    /// Older installs that never saved a source kept the implicit DeepSeek default;
    /// pin it once when they already have an official DeepSeek key.
    static func migrateDefaultProvider(in defaults: UserDefaults = .standard, hasDeepSeekKey: () -> Bool) {
        guard defaults.string(forKey: "polishProvider") == nil else { return }
        defaults.set((hasDeepSeekKey() ? PolishProvider.deepseek : .bailian).rawValue, forKey: "polishProvider")
    }
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "deepseekEnabled") as? Bool ?? false
    }
    static var modelName: String { modelName(for: provider) }
    static func modelName(for provider: PolishProvider, defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: provider.modelKey) ?? provider.defaultModel
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the old official-model fallback, never apply it to a custom service.
        return cleaned.isEmpty && provider == .deepseek ? model : cleaned
    }
    static func endpoint(for provider: PolishProvider, defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: provider.endpointKey) ?? provider.defaultEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func save(provider: PolishProvider, model: String, endpoint: String, defaults: UserDefaults = .standard) {
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.modelKey)
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.endpointKey)
    }
    static var options: PolishOptions { options(in: .standard) }
    static func options(in defaults: UserDefaults) -> PolishOptions {
        return PolishOptions(
            strength: defaults.string(forKey: "deepseekStrength").flatMap(PolishStrength.init(rawValue:)) ?? PolishOptions.default.strength,
            scenario: defaults.string(forKey: "deepseekScenario").flatMap(PolishScenario.init(rawValue:)) ?? PolishOptions.default.scenario,
            output: defaults.string(forKey: "polishOutput").flatMap(PolishOutput.init(rawValue:)) ?? .chinese,
            mode: defaults.string(forKey: "polishMode").flatMap(PolishMode.init(rawValue:)),
            tone: defaults.string(forKey: "polishTone").flatMap(PolishTone.init(rawValue:)) ?? .normal
        )
    }
}

enum PolishConfigurationError: String, LocalizedError {
    case model = "请填写润色模型名称"
    case endpoint = "请填写完整的 https:// 主机/路径/chat/completions 地址，不含账号、查询参数或占位符"
    case plaintext = "远程服务必须使用 HTTPS；HTTP 仅允许 127.0.0.1 或 [::1] 本机联调"
    case officialHost = "DeepSeek 官方来源只能使用 api.deepseek.com 的 HTTPS 地址"
    case bailianHost = "百炼来源只能使用百炼 DashScope 或业务空间专属 HTTPS 地址"
    case key = "请填写当前来源的有效 API Key"
    var errorDescription: String? { rawValue }
}

private final class PolishRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A configured service must never redirect a credential to another destination.
        completionHandler(nil)
    }
}

/// OpenAI-compatible 润色。保留既有内部名称；失败时调用方保留原始 ASR 文本。
enum DeepSeekClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: PolishRedirectPolicy(), delegateQueue: nil)
    }()

    static func validatedURL(provider: PolishProvider, model: String, endpoint: String) throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishConfigurationError.model
        }
        guard !endpoint.isEmpty, endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.contains(where: { $0.isWhitespace || $0 == "{" || $0 == "}" }),
              let parts = URLComponents(string: endpoint),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasSuffix("/chat/completions"),
              let url = parts.url else { throw PolishConfigurationError.endpoint }
        let local = host == "127.0.0.1" || host == "[::1]" || host == "::1"
        guard parts.scheme == "https" || (provider == .custom && parts.scheme == "http" && local) else {
            throw PolishConfigurationError.plaintext
        }
        switch provider {
        case .deepseek:
            guard host == "api.deepseek.com", parts.port == nil || parts.port == 443 else {
                throw PolishConfigurationError.officialHost
            }
        case .bailian:
            let dashscope = ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com",
                             "dashscope-us.aliyuncs.com", "cn-hongkong.dashscope.aliyuncs.com"]
            let workspace = host.range(
                of: #"^[a-z0-9-]+\.(cn-beijing|ap-southeast-1|us-east-1|eu-central-1|ap-northeast-1|cn-hongkong)\.maas\.aliyuncs\.com$"#,
                options: .regularExpression
            ) != nil
            guard (dashscope.contains(host) || workspace),
                  parts.port == nil || parts.port == 443,
                  parts.path == "/compatible-mode/v1/chat/completions" else {
                throw PolishConfigurationError.bailianHost
            }
        case .custom: break
        }
        return url
    }

    static func request(
        text: String, key: String, model: String, endpoint: String,
        provider: PolishProvider, options: PolishOptions
    ) throws -> URLRequest {
        let url = try validatedURL(provider: provider, model: model, endpoint: endpoint)
        guard PolishCredentials.valid(key, for: provider) else { throw PolishConfigurationError.key }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": options.systemPrompt],
                ["role": "user", "content": "<transcript>\n\(text)\n</transcript>"]
            ],
            "temperature": options.temperature,
            "top_p": options.topP,
            "stream": false,
            "max_tokens": 2048
        ]
        switch provider {
        case .deepseek: body["thinking"] = ["type": "disabled"]
        case .bailian: body["enable_thinking"] = false
        case .custom: break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    @discardableResult
    static func polish(
        text: String, key: String, model: String, endpoint: String,
        provider: PolishProvider, options: PolishOptions,
        session: URLSession? = nil,
        completion: @escaping (String?) -> Void
    ) -> URLSessionDataTask? {
        guard !text.isEmpty,
              let request = try? request(text: text, key: key, model: model, endpoint: endpoint, provider: provider, options: options) else {
            IMicLog.write("mac.polish", "skipped provider=\(provider.rawValue) reason=invalid_configuration")
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        let started = Date()
        let modelIsSafe = model.count <= 80 && model != key && !model.hasPrefix("sk-")
            && model.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 47 || $0 == 58 || $0 == 95
            }
        let diagnosticModel = modelIsSafe ? model : "redacted"
        let task = (session ?? Self.session).dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = error == nil ? acceptedContent(data: data, status: status, raw: text, options: options) : nil
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            // Never log endpoints, response bodies, error descriptions or credentials.
            let code = (error as NSError?)?.code ?? 0
            IMicLog.write("mac.polish", "\(result == nil ? "fallback" : "ok") provider=\(provider.rawValue) model=\(diagnosticModel) status=\(status) code=\(code) in=\(text.count) out=\(result?.count ?? 0) ms=\(milliseconds)")
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    static func acceptedContent(data: Data?, status: Int, raw: String, output: PolishOutput = .original, options: PolishOptions? = nil) -> String? {
        guard (200..<300).contains(status), let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first, choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any] else { return nil }
        let toolCalls = message["tool_calls"]
        let functionCall = message["function_call"]
        guard toolCalls == nil || toolCalls is NSNull || (toolCalls as? [Any])?.isEmpty == true,
              functionCall == nil || functionCall is NSNull,
              let content = message["content"] as? String else { return nil }
        // reasoning_content is deliberately ignored. Reject inline thinking rather than insert it.
        let result = (options?.isCommand ?? (output == .command)) ? cleanCommand(content) : clean(content)
        guard result.range(of: #"</?(think|thinking|reasoning)(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              (options.map { DeepSeekPolicy.isAcceptable(raw: raw, polished: result, options: $0) }
                ?? DeepSeekPolicy.isAcceptable(raw: raw, polished: result, output: output)) else { return nil }
        return result
    }

    /// 去掉模型常见的包装（代码围栏、行内反引号、`$ ` 提示符）。不合并多行：
    /// 多行结果交给策略拒绝，避免把模型的多条建议悄悄拼成一条命令。
    static func cleanCommand(_ text: String) -> String {
        var value = clean(text)
        if value.count >= 2, value.first == "`", value.last == "`",
           !value.dropFirst().dropLast().contains("`") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("$ ") {
            value = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return value
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
