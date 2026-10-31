import Foundation

/// Read-only lookup of literal `export NAME=value` assignments in shell startup files.
/// Apps opened from Finder do not inherit the login shell's environment, so a key that
/// works in Terminal has to be found here. Files are parsed, never executed or sourced.
struct ShellCredentials {
    let home:URL
    private let names:[String]
    private let allowCustomToken:Bool
    static let files:[(path:String,fish:Bool)]=[
        (".zshenv",false),(".zprofile",false),(".zshrc",false),
        (".bash_profile",false),(".bashrc",false),(".profile",false),
        (".config/fish/config.fish",true)
    ]
    init(home:URL, names:[String]=["DASHSCOPE_API_KEY","BAILIAN_API_KEY"], allowCustomToken:Bool=false) {
        self.home=home
        self.names=names
        self.allowCustomToken=allowCustomToken
    }
    /// Parse a pasted literal; never evaluate shell syntax or expand variables.
    static func clean(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: #"^(?:export\s+)?DASHSCOPE_API_KEY\s*=\s*"#, options: .regularExpression) {
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (left, right) in [("\"", "\""), ("'", "'"), ("“", "”")] {
            if value.count >= 2, value.hasPrefix(left), value.hasSuffix(right) {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return value
    }
    static func valid(_ key:String)->Bool {
        key.hasPrefix("sk-") && key.count>10 && key.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
    static func validToken(_ key:String)->Bool {
        // A Bearer token is a literal header value, never shell or header syntax.
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            $0.value>32 && $0.value<127 && $0 != "'"
        }
    }
    private func validKey(_ key:String)->Bool {
        allowCustomToken ? Self.validToken(key):Self.valid(key)
    }
    private func assignment(_ line:String,_ name:String,fish:Bool=false)->String? {
        let pattern=fish ? "^\\s*set\\s+(?:-[gx]+\\s+)+\(name)\\s+(.*)$":"^\\s*(?:export\\s+)?\(name)\\s*=\\s*(.*)$"
        let regex=try! NSRegularExpression(pattern:pattern)
        let range=NSRange(line.startIndex...,in:line)
        guard let match=regex.firstMatch(in:line,range:range),let capture=Range(match.range(at:1),in:line) else{return nil}
        return String(line[capture])
    }
    private func literal(_ value:String)->String? {
        // Read literal assignments only. Never execute or source shell files.
        let pattern="^(?:'([^']*)'|\"([^\"\\\\$`]*)\"|([A-Za-z0-9_-]+))\\s*(?:#.*)?$"
        let regex=try! NSRegularExpression(pattern:pattern)
        guard let match=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else{return nil}
        for i in 1...3 {if let range=Range(match.range(at:i),in:value) {return String(value[range])}}
        return nil
    }
    /// The process environment wins (launchctl / terminal launches), then shell files.
    func resolve(environment:[String:String]=ProcessInfo.processInfo.environment)->ResolvedCredential? {
        for name in names {
            if let key=environment[name],validKey(key) {return ResolvedCredential(key:key,source:.environment(name))}
        }
        for (path,fish) in Self.files {
            guard let data=try? Data(contentsOf:home.appendingPathComponent(path)),data.count<=2_000_000,
                  let text=String(data:data,encoding:.utf8) else{continue}
            for name in names {
                // Last assignment has shell precedence, including an explicit clear.
                if let value=text.components(separatedBy:"\n").reversed().compactMap({assignment($0,name,fish:fish)}).first,
                   let key=literal(value) {
                    if key.isEmpty {break}
                    if validKey(key) {return ResolvedCredential(key:key,source:.shell(path:"~/"+path,name:name))}
                }
            }
        }
        return nil
    }
    func load(environment:[String:String]=ProcessInfo.processInfo.environment)->String {
        resolve(environment:environment)?.key ?? ""
    }
}

enum CredentialSource:Equatable {
    case app
    case environment(String)
    case shell(path:String,name:String)

    /// Short technical tag shown beside the key.
    var tag:String {
        switch self {
        case .app:return "APP CONFIG"
        case .environment(let name):return "ENV · \(name)"
        case .shell(let path,let name):return "\(path) · \(name)"
        }
    }
    var isExternal:Bool {self != .app}
}

struct ResolvedCredential:Equatable {
    let key:String
    let source:CredentialSource
}

/// iMic's own key file. Plain JSON readable only by the current user, like `gh` or `aws`
/// configs; the Keychain is avoided because ad-hoc rebuilds would prompt for a password.
struct CredentialFile {
    let url:URL
    static var defaultURL:URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iMic/credentials.json")
    }
    private struct Stored:Codable {
        var version=1
        var keys:[String:String]=[:]
    }
    private func read()->Stored {
        guard let data=try? Data(contentsOf:url),data.count<=64_000,
              let stored=try? JSONDecoder().decode(Stored.self,from:data) else{return Stored()}
        return stored
    }
    func key(_ account:String)->String? {
        read().keys[account].flatMap{$0.isEmpty ? nil:$0}
    }
    /// An empty key removes iMic's own entry; external sources are never touched.
    func set(_ key:String?,for account:String)throws {
        var stored=read()
        if let key=key,!key.isEmpty {stored.keys[account]=key} else {stored.keys.removeValue(forKey:account)}
        let directory=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(stored)
        // Create with 0600 before any secret is written, then replace atomically.
        let temporary=directory.appendingPathComponent(".credentials.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else{
            throw NSError(domain:"iMic.Credentials",code:2)
        }
        do {
            let handle=try FileHandle(forWritingTo:temporary)
            try handle.write(contentsOf:data);try handle.close()
            if FileManager.default.fileExists(atPath:url.path) {
                _ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)
            } else {
                try FileManager.default.moveItem(at:temporary,to:url)
            }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        } catch {
            try? FileManager.default.removeItem(at:temporary)
            throw error
        }
    }
}

/// One lookup path for every provider: iMic's file, then environment, then shell files.
/// Sources never fill in for another provider.
enum PolishCredentials {
    static func valid(_ key: String, for provider: PolishProvider) -> Bool {
        provider == .custom ? ShellCredentials.validToken(key) : ShellCredentials.valid(key)
    }
    static func account(for provider: PolishProvider) -> String {
        switch provider {
        case .deepseek: return "deepseek"
        case .bailian: return "bailian"
        case .custom: return "custom"
        }
    }
    static func names(for provider: PolishProvider) -> [String] {
        switch provider {
        case .deepseek: return ["DEEPSEEK_API_KEY"]
        case .bailian: return ["DASHSCOPE_API_KEY", "BAILIAN_API_KEY"]
        case .custom: return ["IMIC_CUSTOM_POLISH_API_KEY"]
        }
    }
    static func resolve(
        for provider: PolishProvider,
        file: CredentialFile = CredentialFile(url: CredentialFile.defaultURL),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedCredential? {
        if let key = file.key(account(for: provider)), valid(key, for: provider) {
            return ResolvedCredential(key: key, source: .app)
        }
        return ShellCredentials(home: home, names: names(for: provider), allowCustomToken: provider == .custom)
            .resolve(environment: environment)
    }
    static func load(
        for provider: PolishProvider,
        file: CredentialFile = CredentialFile(url: CredentialFile.defaultURL),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        resolve(for: provider, file: file, home: home, environment: environment)?.key ?? ""
    }
    static func save(
        _ key: String, for provider: PolishProvider,
        file: CredentialFile = CredentialFile(url: CredentialFile.defaultURL)
    ) -> Bool {
        guard key.isEmpty || valid(key, for: provider) else { return false }
        do { try file.set(key, for: account(for: provider)); return true } catch { return false }
    }
}

/// Checks a Bailian key with a read-only model listing on the same host as recognition.
/// No audio or text is sent.
enum BailianKeyCheck {
    enum Result:Equatable {
        case valid
        case rejected
        case unreachable(String)
    }
    static func url(forASREndpoint endpoint:String)->URL? {
        guard let url = BailianAddress.url(endpoint, scheme: "wss", path: "/api-ws/v1/inference"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host else { return nil }
        var check=URLComponents()
        check.scheme="https";check.host=host;check.port=parts.port
        check.path="/compatible-mode/v1/models"
        return check.url
    }
    static func request(key:String,asrEndpoint:String)->URLRequest? {
        guard ShellCredentials.valid(key),let url=url(forASREndpoint:asrEndpoint) else{return nil}
        var request=URLRequest(url:url,timeoutInterval:10)
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        return request
    }
    static func classify(status:Int)->Result {
        switch status {
        case 200..<300:return .valid
        case 401,403:return .rejected
        default:return .unreachable("百炼返回 HTTP \(status)")
        }
    }
    @discardableResult
    static func run(key:String,asrEndpoint:String,session:URLSession = SettingsValidation.session,
                    completion:@escaping(Result)->Void)->URLSessionDataTask? {
        guard let request=request(key:key,asrEndpoint:asrEndpoint) else{
            completion(.rejected);return nil
        }
        let task=session.dataTask(with:request){_,response,error in
            let result:Result
            if let status=(response as? HTTPURLResponse)?.statusCode {result=classify(status:status)}
            else {result = .unreachable(BailianIssue.network.message)}
            DispatchQueue.main.async{completion(result)}
        }
        task.resume()
        return task
    }
}

/// The Bailian key drives recognition and, by default, polish.
enum MicCredentials {
    static func resolve()->ResolvedCredential? {PolishCredentials.resolve(for:.bailian)}
    static func load()->String {resolve()?.key ?? ""}
    static func save(_ key:String)->Bool {PolishCredentials.save(key,for:.bailian)}
}
