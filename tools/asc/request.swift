// Private-key material and JWT exist only inside this process. Never returned or logged.
import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@main struct Request {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let obj = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let path = obj["path"] as! String
            let method = obj["method"] as! String
            guard path.hasPrefix("/v"), !path.contains("://"),
                  ["GET", "POST", "PATCH"].contains(method),
                  let url = URL(string: "https://api.appstoreconnect.apple.com" + path),
                  url.host == "api.appstoreconnect.apple.com" else { throw Failure.invalidRequest }
            let keyID = "0N62MERQLNT3"
            let keyURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
            let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: keyURL, encoding: .utf8))
            func b64(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let now = Int(Date().timeIntervalSince1970)
            let header = b64(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"], options: .sortedKeys))
            let payload = b64(try JSONSerialization.data(withJSONObject: ["sub": "user", "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"], options: .sortedKeys))
            let message = header + "." + payload
            let signature = try key.signature(for: Data(message.utf8))
            var request = URLRequest(url: url, timeoutInterval: 45)
            request.httpMethod = method
            request.setValue("Bearer " + message + "." + b64(signature.rawRepresentation), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body = obj["body"] { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            // Do not return request headers, upload URLs, credentials, or JWT.
            let result: [String: Any] = ["status": http.statusCode,
                                       "body": String(data: data, encoding: .utf8) ?? "",
                                       "retryAfter": http.value(forHTTPHeaderField: "Retry-After") ?? ""]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
        } catch {
            // Error interpolation could expose credential material; emit a constant only.
            FileHandle.standardError.write(Data("ASC request failed locally (credential, input, signing or transport).\n".utf8))
            exit(1)
        }
    }
    enum Failure: Error { case invalidRequest }
}
