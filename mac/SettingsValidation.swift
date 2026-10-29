import Foundation

/// No redirect can forward a credential to another host.
private final class SettingsRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum SettingsValidation {
    enum Failure: Error, Equatable {
        case rejected, network, http(Int)
        var message: String {
            switch self {
            case .rejected: return "服务拒绝了这个 Key，请检查 Key 与地域。"
            case .network: return "无法连接服务，请检查网络后重试。"
            case .http(let status): return "验证失败（HTTP \(status)），请检查服务地址与地域。"
            }
        }
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: SettingsRedirectPolicy(), delegateQueue: nil)
    }()

    static func asrURL(_ value: String) -> URL? {
        guard let c = URLComponents(string: value), c.scheme == "wss",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path == "/api-ws/v1/inference",
              !value.contains(where: { $0.isWhitespace }),
              let check = BailianKeyCheck.url(forASREndpoint: value),
              (try? DeepSeekClient.validatedURL(provider: .bailian, model: "validation",
                endpoint: check.deletingLastPathComponent().appendingPathComponent("chat/completions").absoluteString)) != nil
        else { return nil }
        return c.url
    }

    static func request(provider: PolishProvider, key: String, model: String, endpoint: String) throws -> URLRequest {
        let chat = try DeepSeekClient.validatedURL(provider: provider, model: model, endpoint: endpoint)
        guard PolishCredentials.valid(key, for: provider) else { throw PolishConfigurationError.key }
        // A read-only listing: no dictated content, generated text, or paid inference.
        let url = chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func classify(status: Int, error: Error?) -> Result<Void, Failure> {
        if error != nil { return .failure(.network) }
        switch status {
        case 200..<300: return .success(())
        case 401, 403: return .failure(.rejected)
        default: return .failure(.http(status))
        }
    }

    @discardableResult
    static func runBailian(key: String, endpoint: String,
                          completion: @escaping (Result<Void, Failure>) -> Void) -> URLSessionDataTask? {
        BailianKeyCheck.run(key: key, asrEndpoint: endpoint, session: session) { result in
            switch result {
            case .valid: completion(.success(()))
            case .rejected: completion(.failure(.rejected))
            case .unreachable: completion(.failure(.network))
            }
        }
    }

    @discardableResult
    static func run(_ request: URLRequest, session: URLSession? = nil,
                    completion: @escaping (Result<Void, Failure>) -> Void) -> URLSessionDataTask {
        let task = (session ?? Self.session).dataTask(with: request) { _, response, error in
            let result = classify(status: (response as? HTTPURLResponse)?.statusCode ?? 0, error: error)
            DispatchQueue.main.async { completion(result) }
        }
        task.resume(); return task
    }
}
