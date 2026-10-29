import Foundation

/// Only bounded codes/statuses cross into UI; never display service response bodies.
enum CloudFailure: Equatable {
    case key, network, address, service

    static func classify(status: Int = 0, error: Error? = nil, code: String = "") -> CloudFailure {
        if status == 401 || status == 403 { return .key }
        let value = code.lowercased()
        if ["invalidapikey", "invalid_api_key", "unauthorized", "accessdenied", "invalid_api-key"].contains(where: value.contains) { return .key }
        if ["region", "workspace", "modelnotfound", "model_not_found"].contains(where: value.contains) { return .address }
        if let error = error as NSError?, error.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorDNSLookupFailed].contains(error.code) { return .network }
        return .service
    }
    func title(service: String) -> String {
        switch self {
        case .key: return "\(service)拒绝了 Key"
        case .network: return "无法连接\(service)，检查网络"
        case .address: return "请检查 Key 地域与「高级」中的服务地址"
        case .service: return "\(service)暂时无法完成请求"
        }
    }
}
