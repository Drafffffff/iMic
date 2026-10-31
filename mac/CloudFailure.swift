import Foundation

/// Shared by onboarding, settings and live recognition. Never display remote messages.
enum BailianIssue: Error, Equatable {
    case invalidKey, plan, permission, ip, billing, activation, quota, inspection, workspace
    case network, ambiguous, address, service(Int), unsupported(String)

    var message: String {
        switch self {
        case .invalidKey: return "Key 无效、已被删除或复制不完整。请重新复制；若使用子业务空间，请在「高级选项」粘贴控制台给出的 Base URL。"
        case .plan: return "这看起来是 Token Plan 或 Coding Plan 套餐的 Key。套餐 Key 只能用于 Claude Code 等编程工具，iMic 需要按量付费的 API Key。请在百炼控制台的「API Key」页面创建一个新的 Key。"
        case .permission: return "Key 或业务空间没有模型权限。请在百炼控制台将 Key 权限改为「全部」，或勾选 qwen-audio-3.1-asr-flash-message 和 deepseek-v4.1-flash，并开通语音模型权限。"
        case .ip: return "Key 的 IP 白名单拒绝了当前网络。请在百炼控制台关闭 IP 限制，或加入当前网络的出口 IP。"
        case .billing: return "账号欠费或免费额度已用完。新人免费额度只在北京地域提供；请完成实名认证并充值，检查「免费额度用完即停」与预算设置后重试。"
        case .activation: return "账号尚未开通百炼服务。请在百炼控制台完成实名认证、同意服务协议，并开通所需语音模型后重试。"
        case .quota: return "请求触发百炼限流。请稍后重试，或在控制台检查并发与用量限制。"
        case .inspection: return "百炼内容检查未通过。请调整识别内容后重新录音。"
        case .workspace: return "Key 与业务空间地址不匹配或没有该空间权限。请在「高级选项」粘贴控制台给出的 Base URL，并使用该空间自己的 Key。"
        case .network: return "无法连接百炼。请检查网络；公司网络可能拦截了阿里云域名。恢复网络后重试。"
        case .ambiguous: return "多个地域接受了这个 Key，无法唯一识别。请在「高级选项」粘贴百炼控制台给出的 Base URL。"
        case .address: return "服务地址不受支持。请粘贴百炼官方按量付费 Base URL（HTTPS、443 端口、/compatible-mode/v1），不要填写套餐地址或其他主机。"
        case .unsupported(let region): return "这个 Key 属于\(region)地域，该地域暂不支持 iMic 使用的语音识别模型。请在百炼控制台右上角切换到「华北2（北京）」，重新创建一个 Key。"
        case .service(200): return "百炼返回的模型列表无法解析。请稍后重试，或在「高级选项」检查控制台给出的 Base URL。"
        case .service(let status): return "百炼暂时无法完成验证（HTTP \(status)）。请稍后重试，或在「高级选项」检查控制台给出的 Base URL。"
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
        ["cn-beijing": "华北2（北京）", "ap-southeast-1": "新加坡", "cn-hongkong": "中国香港", "us-east-1": "美国（弗吉尼亚）", "ap-northeast-1": "日本（东京）", "eu-central-1": "德国（法兰克福）"][region] ?? region
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
    var needsConsole: Bool {
        switch self { case .key: return true; case .bailian(let issue): return issue.needsConsole; default: return false }
    }
    func title(service: String) -> String {
        switch self {
        case .key: return service == "百炼" ? BailianIssue.invalidKey.message : "\(service)拒绝了 Key，请重新复制有效的 API Key。"
        case .network: return service == "百炼" ? BailianIssue.network.message : "无法连接\(service)，请检查网络后重试。"
        case .address: return BailianIssue.address.message
        case .service: return "\(service)暂时无法完成请求，请稍后重试。"
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
