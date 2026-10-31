import Foundation

/// Shared by onboarding, settings and live recognition. Never display remote messages.
enum BailianIssue: Error, Equatable {
    case invalidKey, plan, permission, ip, billing, activation, quota, inspection, workspace
    case network, ambiguous, address, service(Int), unsupported(String)

    var linkCode: String {
        switch self {
        case .invalidKey: return "cloud_invalidKey"
        case .plan: return "cloud_plan"
        case .permission: return "cloud_permission"
        case .ip: return "cloud_ip"
        case .billing: return "cloud_billing"
        case .activation: return "cloud_activation"
        case .quota: return "cloud_quota"
        case .inspection: return "cloud_inspection"
        case .workspace: return "cloud_workspace"
        case .network: return "cloud_network"
        case .ambiguous: return "cloud_ambiguous"
        case .address: return "cloud_address"
        case .service: return "cloud_service"
        case .unsupported: return "cloud_unsupported"
        }
    }
    var message: String {
        switch self {
        case .invalidKey: return L10n.text("The Key is invalid, deleted, or incomplete. Copy it again. For a sub-workspace, paste the console's Base URL under Advanced options.")
        case .plan: return L10n.text("This looks like a Token Plan or Coding Plan Key. These Keys are for coding tools such as Claude Code. iMic needs a pay-as-you-go API Key. Create one on the Model Studio console's API Key page.")
        case .permission: return L10n.text("This Key or workspace lacks model access. Set Key permissions to All in Model Studio, or select qwen-audio-3.1-asr-flash-message and deepseek-v4.1-flash, and activate the speech model.")
        case .ip: return L10n.text("The Key's IP allowlist blocked this network. Disable IP restrictions in Model Studio or add your network's public IP address.")
        case .billing: return L10n.text("Your account has overdue charges or no free quota remaining. International new-user quota is offered for eligible Singapore models. Complete your account information, add funds, and check Free Quota Only and budget settings before retrying.")
        case .activation: return L10n.text("Model Studio is not activated. Complete your account information, accept the service agreement, and activate the required speech model in the console, then retry.")
        case .quota: return L10n.text("Model Studio rate limit reached. Retry later or check concurrency and usage limits in the console.")
        case .inspection: return L10n.text("Model Studio's content check rejected this input. Adjust the content and record again.")
        case .workspace: return L10n.text("The Key does not match this workspace address or lacks access. Paste the console's Base URL under Advanced options and use that workspace's own Key.")
        case .network: return L10n.text("Cannot connect to Model Studio. Check your network. Office networks may block Alibaba Cloud domains. Retry once connected.")
        case .ambiguous: return L10n.text("Multiple regions accepted this Key, so its region could not be uniquely identified. Paste the console's Base URL under Advanced options.")
        case .address: return L10n.text("Unsupported service address. Paste the official Model Studio pay-as-you-go Base URL (HTTPS, port 443, /compatible-mode/v1). Plan endpoints and other hosts are not supported.")
        case .unsupported(let region): return L10n.text("This Key belongs to %@, which does not currently support iMic's speech model. Select Singapore in Model Studio and create a new Key.", L10n.argument(region))
        case .service(200): return L10n.text("Could not read Model Studio's model list. Retry later or check the console's Base URL under Advanced options.")
        case .service(let status): return L10n.text("Model Studio could not verify your Key (HTTP %@). Retry later or check the console's Base URL under Advanced options.", L10n.argument(status))
        }
    }
    var needsConsole: Bool {
        switch self { case .network, .inspection, .address, .service: return false; default: return true }
    }
    static func code(in data: Data?) -> String {
        guard let data, data.count <= 2_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let error = object["error"] as? [String: Any] ?? object
        return error["code"] as? String ?? error["type"] as? String ?? ""
    }
    static func classify(status: Int = 0, code: String = "", message: String = "", error: Error? = nil) -> BailianIssue {
        // Message is used only to distinguish shared access_denied codes, never stored or shown.
        let c = code.lowercased(), m = message.lowercased()
        if c.contains("ip") && (c.contains("denied") || c.contains("restrict") || c.contains("whitelist"))
            || ((c.contains("accessdenied") || c.contains("access_denied")) && (m.contains(" ip ") || m.contains("ip address"))) { return .ip }
        if c.contains("arrearage") || c.contains("freetieronly") || c.contains("billoverdue") || c.contains("budgetlimit") { return .billing }
        if c.contains("unpurchased") { return .activation }
        if c.contains("workspace") { return .workspace }
        if c.contains("datainspection") || c.contains("data_inspection") { return .inspection }
        if c.contains("throttl") || c.contains("quota") || status == 429 { return .quota }
        if c.contains("accessdenied") || c.contains("access_denied") { return .permission }
        if c.contains("invalidapikey") || c.contains("invalid_api_key") || c.contains("invalid_api-key") || status == 401 { return .invalidKey }
        if c.contains("modelnotfound") || c.contains("model_not_found") || status == 403 { return .permission }
        if error != nil || (status == 0 && code.isEmpty) { return .network }
        return .service(status)
    }
    static func response(status: Int, data: Data?, error: Error?) -> BailianIssue {
        var message = ""
        if let data, data.count <= 2_000_000, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = ((obj["error"] as? [String: Any]) ?? obj)["message"] as? String ?? ""
        }
        return classify(status: status, code: code(in: data), message: message, error: error)
    }
}

/// All credential-bearing Bailian requests share this exact allowlist.
enum BailianAddress {
    static let regions = ["cn-beijing", "ap-southeast-1", "cn-hongkong", "us-east-1"]
    static let hosts = ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "cn-hongkong.dashscope.aliyuncs.com", "dashscope-us.aliyuncs.com"]
    static func region(_ host: String) -> String {
        if let index = hosts.firstIndex(of: host) { return regions[index] }
        return host.split(separator: ".").dropFirst().first.map(String.init) ?? ""
    }
    static func title(_ region: String) -> String {
        ["cn-beijing": L10n.text("China (Beijing)"), "ap-southeast-1": L10n.text("Singapore"), "cn-hongkong": L10n.text("China (Hong Kong)"), "us-east-1": L10n.text("US (Virginia)"), "ap-northeast-1": L10n.text("Japan (Tokyo)"), "eu-central-1": L10n.text("Germany (Frankfurt)")][region] ?? region
    }
    static func supportsASR(_ host: String) -> Bool { ["cn-beijing", "ap-southeast-1"].contains(region(host)) }
    static func isPlan(_ value: String) -> Bool {
        let text = value.lowercased()
        return text.contains("token-plan.") || text.contains("coding.dashscope") || text.contains("coding-intl.dashscope")
    }
    static func allowed(_ host: String) -> Bool {
        if isPlan(host) { return false }
        if hosts.contains(host) { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 5, pieces.suffix(3) == ["maas", "aliyuncs", "com"],
              pieces[0].range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil else { return false }
        if pieces[0] == "trial" { return ["cn-beijing", "ap-southeast-1", "cn-hongkong"].contains(pieces[1]) }
        return (regions + ["ap-northeast-1", "eu-central-1"]).contains(pieces[1])
    }
    static func url(_ value: String, scheme: String, path: String) -> URL? {
        guard !value.contains(where: \.isWhitespace), let c = URLComponents(string: value),
              c.scheme == scheme, let host = c.host, allowed(host),
              c.port == nil || c.port == 443, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path == path else { return nil }
        return c.url
    }
    static func asr(_ host: String) -> String { "wss://\(host)/api-ws/v1/inference" }
    static func polish(_ host: String) -> String { "https://\(host)/compatible-mode/v1/chat/completions" }
    static func baseHost(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPlan(text) { throw BailianIssue.plan }
        guard let url = url(text, scheme: "https", path: "/compatible-mode/v1"), let host = url.host else { throw BailianIssue.address }
        return host
    }
}

/// Only local, bounded classifications cross into UI.
enum CloudFailure: Equatable {
    case key, network, address, service, bailian(BailianIssue)
    static func classify(status: Int = 0, error: Error? = nil, code: String = "", message: String = "") -> CloudFailure {
        from(BailianIssue.classify(status: status, code: code, message: message, error: error))
    }
    static func from(_ issue: BailianIssue) -> CloudFailure {
        switch issue {
        case .invalidKey: return .key
        case .network: return .network
        case .service: return .service
        default: return .bailian(issue)
        }
    }
    var linkCode: String {
        switch self {
        case .key: return "cloud_invalidKey"
        case .network: return "cloud_network"
        case .address: return "cloud_address"
        case .service: return "cloud_service"
        case .bailian(let issue): return issue.linkCode
        }
    }
    var needsConsole: Bool {
        switch self { case .key: return true; case .bailian(let issue): return issue.needsConsole; default: return false }
    }
    func title(service: String) -> String {
        switch self {
        case .key: return service == L10n.text("Model Studio") ? BailianIssue.invalidKey.message : L10n.text("%@ rejected the Key. Copy a valid API Key again.", L10n.argument(service))
        case .network: return service == L10n.text("Model Studio") ? BailianIssue.network.message : L10n.text("Cannot connect to %@. Check your network and retry.", L10n.argument(service))
        case .address: return BailianIssue.address.message
        case .service: return L10n.text("%@ could not complete the request. Please retry later.", L10n.argument(service))
        case .bailian(let issue): return issue.message
        }
    }
}

/// Never forward a Bearer credential through a redirect, including same-host redirects.
final class BailianRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
