import Foundation

enum SettingsValidation {
    enum Failure: Error, Equatable {
        case rejected, network, http(Int), bailian(BailianIssue)
        var message: String {
            switch self {
            case .rejected: return BailianIssue.invalidKey.message
            case .bailian(let issue): return issue.message
            case .network: return L10n.text("Cannot connect to the service. Check your network and retry.")
            case .http(let status): return L10n.text("Verification failed (HTTP %@). Check the service address and region.", L10n.argument(status))
            }
        }
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: BailianRedirectPolicy(), delegateQueue: nil)
    }()

    static func asrURL(_ value: String) -> URL? {
        BailianAddress.url(value, scheme: "wss", path: "/api-ws/v1/inference")
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
        case 401: return .failure(.rejected)
        case 403: return .failure(.bailian(.permission))
        default: return .failure(.http(status))
        }
    }

    @discardableResult
    static func runBailian(key: String, endpoint: String,
                          completion: @escaping (Result<Void, Failure>) -> Void) -> URLSessionDataTask? {
        guard let request = BailianKeyCheck.request(key: key, asrEndpoint: endpoint) else {
            completion(.failure(.bailian(.address))); return nil
        }
        return run(request, completion: completion)
    }

    @discardableResult
    static func run(_ request: URLRequest, session: URLSession? = nil,
                    completion: @escaping (Result<Void, Failure>) -> Void) -> URLSessionDataTask {
        let task = (session ?? Self.session).dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Void, Failure> = error == nil && status == 200 ? .success(())
                : .failure(.bailian(BailianIssue.response(status: status, data: data, error: error)))
            DispatchQueue.main.async { completion(result) }
        }
        task.resume(); return task
    }
}


/// Owns one generation of requests, including a wall-clock deadline. Main-queue confined.
final class BailianDiscovery {
    private var tasks: [URLSessionDataTask] = []
    private var deadline: DispatchWorkItem?
    private var stopped = false
    private var responses: [String: (Int, Data?, Error?)] = [:]
    func cancel() {
        stopped = true; deadline?.cancel(); deadline = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
    }
    deinit { tasks.forEach { $0.cancel() }; deadline?.cancel() }

    struct Selection: Equatable {
        let host: String
        let asrListed: Bool
        let polishListed: Bool
        var region: String { BailianAddress.title(BailianAddress.region(host)) }
        var message: String {
            var text = L10n.text("Detected: %@.", L10n.argument(region))
            if !asrListed { text += L10n.text("The model list does not include the speech model. Access will be confirmed on first recognition.") }
            if !polishListed { text += L10n.text("This Key cannot use the polish model yet. You can enable it later in Settings.") }
            return text
        }
        func apply(_ defaults: UserDefaults = MacPreferences.defaults) {
            defaults.set(BailianAddress.asr(host), forKey: "asrEndpoint")
            defaults.set(BailianAddress.polish(host), forKey: PolishProvider.bailian.endpointKey)
            defaults.set(BailianAddress.region(host), forKey: "bailian.detectedRegion")
            if !polishListed { defaults.set(false, forKey: "deepseekEnabled") }
        }
    }

    @discardableResult
    static func start(key: String, baseURL: String = "", session: URLSession = SettingsValidation.session,
                      timeout: TimeInterval = 7.8,
                      progress: @escaping (String) -> Void = { _ in },
                      completion: @escaping (Result<Selection, BailianIssue>) -> Void) -> BailianDiscovery {
        let operation = BailianDiscovery()
        let hosts: [String]
        do {
            if BailianAddress.isPlan(key) { throw BailianIssue.plan }
            guard ShellCredentials.valid(key) else { throw BailianIssue.invalidKey }
            hosts = baseURL.isEmpty ? BailianAddress.hosts : [try BailianAddress.baseHost(baseURL)]
        } catch {
            DispatchQueue.main.async { if !operation.stopped { completion(.failure(error as? BailianIssue ?? .address)) } }
            return operation
        }
        progress(L10n.text("Detecting region…"))
        let finish = {
            guard !operation.stopped else { return }
            let responses = operation.responses
            operation.cancel()
            progress(L10n.text("Checking model access…"))
            // Complete on the next turn so both progress stages can be rendered.
            DispatchQueue.main.async {
                let accepted = hosts.filter { responses[$0]?.0 == 200 }
                if accepted.count > 1 { completion(.failure(.ambiguous)); return }
                if let host = accepted.first, let data = responses[host]?.1,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]] {
                    guard BailianAddress.supportsASR(host) else {
                        completion(.failure(.unsupported(BailianAddress.title(BailianAddress.region(host))))); return
                    }
                    let models = list.compactMap { $0["id"] as? String }
                    completion(.success(Selection(host: host,
                        asrListed: models.contains("qwen-audio-3.1-asr-flash-message"),
                        polishListed: models.contains(PolishProvider.bailian.defaultModel))))
                    return
                }
                if !accepted.isEmpty { completion(.failure(.service(200))); return }
                if hosts.allSatisfy({ responses[$0]?.0 == 401 }) {
                    let suspect = key.hasPrefix("sk-sp-") || key.hasPrefix("sk-ws-")
                    completion(.failure(suspect ? .plan : .invalidKey)); return
                }
                // Prefer a specific actionable rejection over a different region's 401.
                for host in hosts {
                    if let (status, data, error) = responses[host], status != 401, status != 0 {
                        completion(.failure(BailianIssue.response(status: status, data: data, error: error))); return
                    }
                }
                completion(.failure(.network))
            }
        }
        let deadline = DispatchWorkItem(block: finish)
        operation.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + min(7.8, max(0.01, timeout)), execute: deadline)
        for host in hosts {
            var request = URLRequest(url: URL(string: "https://\(host)/compatible-mode/v1/models")!, timeoutInterval: min(7.5, timeout))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let task = session.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard !operation.stopped else { return }
                    operation.responses[host] = ((response as? HTTPURLResponse)?.statusCode ?? 0, data, error)
                    if operation.responses.count == hosts.count { finish() }
                }
            }
            operation.tasks.append(task); task.resume()
        }
        return operation
    }
}
