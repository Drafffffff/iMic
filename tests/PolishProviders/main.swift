import Foundation
import XCTest

private final class PolishResponseProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private enum ASRTestEndpoint { static let value = "wss://dashscope.aliyuncs.com/api-ws/v1/inference" }

final class PolishProviderTests: XCTestCase {
    private let raw = "帮我整理一下明天的会议安排，可以吗？"
    private let officialKey = "sk-official-test-secret"
    private let bailianKey = "sk-bailian-test-secret"
    private let customKey = "local.token+/=test"
    private var home: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        suite = "iMic.polish.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: home)
        PolishResponseProtocol.handler = nil
    }

    private func response(content: String? = nil, reasoning: String? = nil, finish: String = "stop") throws -> Data {
        var message: [String: Any] = [:]
        if let content { message["content"] = content }
        if let reasoning { message["reasoning_content"] = reasoning }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
    }

    func testOldPreferencesMigrateAndNewSelectionsSurviveReload() {
        XCTAssertEqual(DeepSeekConfiguration.options(in: defaults), .default)
        defaults.set("command", forKey: "polishOutput")
        XCTAssertTrue(DeepSeekConfiguration.options(in: defaults).isCommand)
        defaults.set("original", forKey: "polishOutput")
        XCTAssertEqual(DeepSeekConfiguration.options(in: defaults).output, .chinese)
        defaults.set("dubbed", forKey: "polishMode")
        defaults.set("sarcastic", forKey: "polishTone")
        defaults.set("japanese", forKey: "polishOutput")
        let options = DeepSeekConfiguration.options(in: defaults)
        XCTAssertEqual(options.mode, .dubbed)
        XCTAssertEqual(options.tone, .sarcastic)
        XCTAssertEqual(options.output, .japanese)
    }

    func testNewModesUseRealRequestAndResultPolicy() throws {
        for mode in PolishMode.allCases {
            let options = PolishOptions(output: .korean, mode: mode, tone: .moe)
            let request = try DeepSeekClient.request(text: raw, key: officialKey, model: "deepseek-flash",
                endpoint: PolishProvider.deepseek.defaultEndpoint, provider: .deepseek, options: options)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["temperature"] as? Double, options.temperature)
            XCTAssertEqual(body["top_p"] as? Double, options.topP)
        }
        let terminal = PolishOptions(output: .japanese, mode: .terminal, tone: .rant)
        XCTAssertEqual(DeepSeekClient.acceptedContent(data: try response(content: "ls -la"), status: 200,
            raw: "列出当前目录所有文件包括隐藏的", options: terminal), "ls -la")
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(content: "ls\npwd"), status: 200,
            raw: "列出当前目录", options: terminal))
        XCTAssertEqual(DeepSeekClient.acceptedContent(data: try response(content: "今日劳甚，欲早归。"), status: 200,
            raw: "我今天实在是觉得特别特别疲惫，所以我想要比平时更早一点下班回去。",
            options: PolishOptions(mode: .classical)), "今日劳甚，欲早归。")
    }

    func testExistingOfficialSettingsSurviveProviderRoundTrip() throws {
        defaults.set("existing-official-model", forKey: "deepseekModel")
        defaults.set(true, forKey: "deepseekEnabled")
        defaults.set("heavy", forKey: "deepseekStrength")
        defaults.set("email", forKey: "deepseekScenario")
        DeepSeekConfiguration.migrateDefaultProvider(in: defaults, hasDeepSeekKey: { true })
        let originalProvider = DeepSeekConfiguration.provider(in: defaults)
        XCTAssertEqual(originalProvider, .deepseek)
        let originalRequest = try DeepSeekClient.request(
            text: raw, key: officialKey,
            model: DeepSeekConfiguration.modelName(for: originalProvider, defaults: defaults),
            endpoint: DeepSeekConfiguration.endpoint(for: originalProvider, defaults: defaults),
            provider: originalProvider, options: .default
        )
        DeepSeekConfiguration.save(provider: .bailian, model: "deepseek-v4-pro", endpoint: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions", defaults: defaults)
        defaults.set(PolishProvider.bailian.rawValue, forKey: "polishProvider")
        DeepSeekConfiguration.save(provider: .custom, model: "local-model", endpoint: "http://127.0.0.1:1234/v1/chat/completions", defaults: defaults)
        defaults.set(PolishProvider.custom.rawValue, forKey: "polishProvider")
        defaults.set(originalProvider.rawValue, forKey: "polishProvider")
        let restored = try DeepSeekClient.request(
            text: raw, key: officialKey,
            model: DeepSeekConfiguration.modelName(for: DeepSeekConfiguration.provider(in: defaults), defaults: defaults),
            endpoint: DeepSeekConfiguration.endpoint(for: DeepSeekConfiguration.provider(in: defaults), defaults: defaults),
            provider: DeepSeekConfiguration.provider(in: defaults), options: .default
        )
        XCTAssertEqual(restored.url, originalRequest.url)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: restored.httpBody!) as? NSDictionary,
            try JSONSerialization.jsonObject(with: originalRequest.httpBody!) as? NSDictionary
        )
        XCTAssertTrue(defaults.bool(forKey: "deepseekEnabled"))
        XCTAssertEqual(defaults.string(forKey: "deepseekStrength"), "heavy")
        XCTAssertEqual(defaults.string(forKey: "deepseekScenario"), "email")
        XCTAssertEqual(DeepSeekConfiguration.modelName(for: .bailian, defaults: defaults), "deepseek-v4-pro")
        XCTAssertEqual(DeepSeekConfiguration.endpoint(for: .custom, defaults: defaults), "http://127.0.0.1:1234/v1/chat/completions")
    }

    private var file: CredentialFile { CredentialFile(url: home.appendingPathComponent("Support/credentials.json")) }

    func testNewInstallsDefaultToBailianPolish() {
        XCTAssertEqual(DeepSeekConfiguration.provider(in: defaults), .bailian)
        DeepSeekConfiguration.migrateDefaultProvider(in: defaults, hasDeepSeekKey: { false })
        XCTAssertEqual(defaults.string(forKey: "polishProvider"), "bailian")
        // An explicit choice is never rewritten.
        defaults.set("custom", forKey: "polishProvider")
        DeepSeekConfiguration.migrateDefaultProvider(in: defaults, hasDeepSeekKey: { true })
        XCTAssertEqual(DeepSeekConfiguration.provider(in: defaults), .custom)
    }

    func testProviderCredentialStoresStaySeparateInAppFile() throws {
        XCTAssertTrue(PolishCredentials.save(officialKey, for: .deepseek, file: file))
        XCTAssertTrue(PolishCredentials.save(bailianKey, for: .bailian, file: file))
        XCTAssertTrue(PolishCredentials.save(customKey, for: .custom, file: file))
        XCTAssertEqual(PolishCredentials.resolve(for: .deepseek, file: file, home: home, environment: [:]),
                       ResolvedCredential(key: officialKey, source: .app))
        XCTAssertEqual(PolishCredentials.load(for: .bailian, file: file, home: home, environment: [:]), bailianKey)
        XCTAssertEqual(PolishCredentials.load(for: .custom, file: file, home: home, environment: [:]), customKey)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(PolishCredentials.save("sk-updated-official-key", for: .deepseek, file: file))
        XCTAssertEqual(PolishCredentials.load(for: .bailian, file: file, home: home, environment: [:]), bailianKey)
        XCTAssertEqual(PolishCredentials.load(for: .custom, file: file, home: home, environment: [:]), customKey)
        XCTAssertTrue(PolishCredentials.save("", for: .custom, file: file))
        XCTAssertTrue(PolishCredentials.load(for: .custom, file: file, home: home, environment: [:]).isEmpty)
        XCTAssertEqual(PolishCredentials.load(for: .bailian, file: file, home: home, environment: [:]), bailianKey)
        XCTAssertFalse(PolishCredentials.save("not-a-key", for: .bailian, file: file))
        // iMic never writes shell startup files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
    }

    func testAppFileWinsThenEnvironmentThenShellFiles() throws {
        let shellKey = "sk-shell-test-secret"
        let envKey = "sk-env-test-secret"
        try Data("export DASHSCOPE_API_KEY='\(shellKey)'\n".utf8).write(to: home.appendingPathComponent(".zprofile"))
        XCTAssertEqual(PolishCredentials.resolve(for: .bailian, file: file, home: home, environment: [:]),
                       ResolvedCredential(key: shellKey, source: .shell(path: "~/.zprofile", name: "DASHSCOPE_API_KEY")))
        XCTAssertEqual(PolishCredentials.resolve(for: .bailian, file: file, home: home, environment: ["BAILIAN_API_KEY": envKey]),
                       ResolvedCredential(key: envKey, source: .environment("BAILIAN_API_KEY")))
        XCTAssertTrue(PolishCredentials.save(bailianKey, for: .bailian, file: file))
        XCTAssertEqual(PolishCredentials.resolve(for: .bailian, file: file, home: home, environment: ["BAILIAN_API_KEY": envKey]),
                       ResolvedCredential(key: bailianKey, source: .app))
        // Removing iMic's copy falls back to the external key and never edits it.
        XCTAssertTrue(PolishCredentials.save("", for: .bailian, file: file))
        XCTAssertEqual(PolishCredentials.resolve(for: .bailian, file: file, home: home, environment: [:])?.source,
                       .shell(path: "~/.zprofile", name: "DASHSCOPE_API_KEY"))
        let fish = home.appendingPathComponent(".config/fish")
        try FileManager.default.createDirectory(at: fish, withIntermediateDirectories: true)
        try Data("set -gx DEEPSEEK_API_KEY \(officialKey)\n".utf8).write(to: fish.appendingPathComponent("config.fish"))
        XCTAssertEqual(PolishCredentials.load(for: .deepseek, file: file, home: home, environment: [:]), officialKey)
    }

    func testBailianEnvironmentKeyCannotFillOtherProviderCredentials() {
        let environment = ["BAILIAN_API_KEY": bailianKey, "DASHSCOPE_API_KEY": bailianKey]
        XCTAssertEqual(PolishCredentials.load(for: .bailian, file: file, home: home, environment: environment), bailianKey)
        XCTAssertTrue(PolishCredentials.load(for: .deepseek, file: file, home: home, environment: environment).isEmpty)
        XCTAssertTrue(PolishCredentials.load(for: .custom, file: file, home: home, environment: environment).isEmpty)
    }

    func testBailianKeyCheckUsesRecognitionHostAndClassifiesResponses() throws {
        let request = try XCTUnwrap(BailianKeyCheck.request(
            key: bailianKey, asrEndpoint: "wss://ws-1.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"))
        XCTAssertEqual(request.url?.absoluteString, "https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(bailianKey)")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(BailianKeyCheck.request(key: "bad key", asrEndpoint: ASRTestEndpoint.value))
        XCTAssertNil(BailianKeyCheck.request(key: bailianKey, asrEndpoint: "https://dashscope.aliyuncs.com"))
        XCTAssertEqual(BailianKeyCheck.classify(status: 200), .valid)
        XCTAssertEqual(BailianKeyCheck.classify(status: 401), .rejected)
        XCTAssertEqual(BailianKeyCheck.classify(status: 403), .rejected)
        XCTAssertEqual(BailianKeyCheck.classify(status: 503), .unreachable("百炼返回 HTTP 503"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        PolishResponseProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let done = expectation(description: "check")
        BailianKeyCheck.run(key: bailianKey, asrEndpoint: ASRTestEndpoint.value, session: session) { result in
            XCTAssertEqual(result, .rejected)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testExecutableShellAssignmentIsNeverReadAsCredential() throws {
        let marker = home.appendingPathComponent("must-not-exist")
        let text = "export DEEPSEEK_API_KEY=\"$(touch \(marker.path))\"\n"
        try Data(text.utf8).write(to: home.appendingPathComponent(".zshrc"))
        XCTAssertTrue(PolishCredentials.load(for: .deepseek, file: file, home: home, environment: [:]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(PolishCredentials.valid("token\nInjected: header", for: .custom))
        XCTAssertFalse(PolishCredentials.valid("token'escape", for: .custom))
    }


    func testInvalidAndPlaintextRemoteEndpointsAreRejectedBeforeRequest() throws {
        for endpoint in ["", "https://service.example/v1", "http://service.example/v1/chat/completions", "http://127.0.0.1.example/v1/chat/completions", "https://user:secret@service.example/v1/chat/completions", "https://service.example/v1/chat/completions?key=secret", "https://{workspace}.example/v1/chat/completions"] {
            XCTAssertThrowsError(try DeepSeekClient.request(text: raw, key: customKey, model: "local", endpoint: endpoint, provider: .custom, options: .default))
        }
        for endpoint in ["http://127.0.0.1:1234/v1/chat/completions", "http://[::1]:1234/v1/chat/completions"] {
            let request = try DeepSeekClient.request(text: raw, key: customKey, model: "local", endpoint: endpoint, provider: .custom, options: .default)
            XCTAssertEqual(request.url?.scheme, "http")
        }
        for provider in [PolishProvider.deepseek, .bailian] {
            XCTAssertThrowsError(try DeepSeekClient.request(text: raw, key: officialKey, model: "model", endpoint: "https://other.example/v1/chat/completions", provider: provider, options: .default))
        }
        XCTAssertThrowsError(try DeepSeekClient.request(text: raw, key: customKey, model: "", endpoint: "https://service.example/v1/chat/completions", provider: .custom, options: .default))
        XCTAssertThrowsError(try DeepSeekClient.request(text: raw, key: "", model: "local", endpoint: "https://service.example/v1/chat/completions", provider: .custom, options: .default))
    }

    func testResponseUsesOnlyFinalContentAndRetainsSafetyPolicy() throws {
        XCTAssertEqual(DeepSeekClient.acceptedContent(data: try response(content: raw, reasoning: "private thought"), status: 200, raw: raw), raw)
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(reasoning: raw), status: 200, raw: raw))
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(content: "<think>private thought</think>" + raw), status: 200, raw: raw))
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(content: "好的，我已经安排好了。"), status: 200, raw: raw))
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(content: raw, finish: "length"), status: 200, raw: raw))
        XCTAssertNil(DeepSeekClient.acceptedContent(data: try response(content: raw), status: 401, raw: raw))
        XCTAssertNil(DeepSeekClient.acceptedContent(data: Data("bad json".utf8), status: 200, raw: raw))
    }

    func testCommandOutputStripsWrappersButRejectsMultipleLines() throws {
        let spoken = "切到 main 分支然后拉最新代码"
        for content in ["git switch main && git pull", "`git switch main && git pull`",
                        "$ git switch main && git pull", "```zsh\ngit switch main && git pull\n```"] {
            XCTAssertEqual(DeepSeekClient.acceptedContent(
                data: try response(content: content), status: 200, raw: spoken, output: .command),
                "git switch main && git pull", content)
        }
        XCTAssertEqual(DeepSeekClient.cleanCommand("echo `date`"), "echo `date`")
        XCTAssertNil(DeepSeekClient.acceptedContent(
            data: try response(content: "git switch main\ngit pull"), status: 200, raw: spoken, output: .command))
        XCTAssertNil(DeepSeekClient.acceptedContent(
            data: try response(content: "```\ngit switch main\ngit pull\n```"), status: 200, raw: spoken, output: .command))
    }

    func testRequestUsesOutputSpecificPrompt() throws {
        for output in [PolishOutput.english, .command] {
            let request = try DeepSeekClient.request(
                text: "列出当前目录", key: "sk-test-1234567890", model: "deepseek-flash",
                endpoint: PolishProvider.deepseek.defaultEndpoint, provider: .deepseek,
                options: PolishOptions(output: output))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["content"], PolishOptions(output: output).systemPrompt)
        }
    }

    func testEmptyToolMetadataAcceptsTextButActualToolCallsAreRejected() throws {
        for toolCalls in [NSNull(), []] as [Any] {
            let object: [String: Any] = ["choices": [[
                "finish_reason": "stop",
                "message": ["content": raw, "tool_calls": toolCalls, "function_call": NSNull()]
            ]]]
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(DeepSeekClient.acceptedContent(data: data, status: 200, raw: raw), raw)
        }
        for metadata: [String: Any] in [
            ["tool_calls": [["id": "call-1", "type": "function"]]],
            ["function_call": ["name": "perform_action", "arguments": "{}"]]
        ] {
            let message = metadata.merging(["content": raw]) { _, content in content }
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": message]]
            ])
            XCTAssertNil(DeepSeekClient.acceptedContent(data: data, status: 200, raw: raw))
        }
    }

    func testClientFallsBackOnHTTPAndNetworkFailure() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for outcome in [503, -1] {
            let done = expectation(description: "polish \(outcome)")
            let data = try response(content: raw)
            PolishResponseProtocol.handler = { _ in
                if outcome == -1 { throw URLError(.notConnectedToInternet) }
                return (outcome, data)
            }
            DeepSeekClient.polish(text: raw, key: customKey, model: "custom", endpoint: "https://custom.example/v1/chat/completions", provider: .custom, options: .default, session: session) { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertNil(result)
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
        }
    }
}

let suite = XCTestSuite(forTestCaseClass: PolishProviderTests.self)
suite.run()
guard let result = suite.testRun, result.executionCount > 0 else {
    fatalError("未发现润色来源行为测试")
}
exit(result.totalFailureCount == 0 ? 0 : 1)
