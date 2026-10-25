import Foundation

struct ShellCredentials {
    let home:URL
    private let names:[String]
    private let allowCustomToken:Bool
    init(home:URL, names:[String]=["DASHSCOPE_API_KEY","BAILIAN_API_KEY"], allowCustomToken:Bool=false) {
        self.home=home
        self.names=names
        self.allowCustomToken=allowCustomToken
    }
    var config:URL {home.appendingPathComponent(".zshrc").resolvingSymlinksInPath()}
    static func valid(_ key:String)->Bool {
        key.hasPrefix("sk-") && key.count>10 && key.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
    static func validToken(_ key:String)->Bool {
        // A Bearer token is a literal shell value, never executable shell syntax.
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
    func load(environment:[String:String]=ProcessInfo.processInfo.environment)->String {
        let sources=[(".zshrc",false),(".bashrc",false),(".config/fish/config.fish",true)]
        for (path,fish) in sources {
            guard let data=try? Data(contentsOf:home.appendingPathComponent(path)),data.count<=2_000_000,
                  let text=String(data:data,encoding:.utf8) else{continue}
            for name in names {
                // Last assignment has shell precedence, including an explicit clear.
                if let value=text.components(separatedBy:"\n").reversed().compactMap({assignment($0,name,fish:fish)}).first,
                   let key=literal(value) {
                    if key.isEmpty || validKey(key) {return key}
                }
            }
        }
        return names.compactMap{environment[$0]}.first(where:validKey) ?? ""
    }
    func save(_ key:String, name:String)throws {
        guard (key.isEmpty || validKey(key)), names.contains(name) else{throw NSError(domain:"iMic.Credentials",code:1)}
        let file=config
        let existing=FileManager.default.fileExists(atPath:file.path) ? try String(contentsOf:file,encoding:.utf8):""
        var lines=existing.components(separatedBy:"\n")
        let export="export \(name)='\(key)'"
        if let index=lines.lastIndex(where:{assignment($0,name) != nil}),
           let value=assignment(lines[index],name),literal(value) != nil {
            let indent=String(lines[index].prefix(while:{$0==" " || $0=="\t"}))
            lines[index]=indent+export
        } else {
            if lines.last=="" {lines.removeLast()}
            lines.append(export);lines.append("")
        }
        let data=Data(lines.joined(separator:"\n").utf8)
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }

    func save(_ key:String)throws {
        try save(key, name:"DASHSCOPE_API_KEY")
    }
}
enum MicCredentials {
    private static let store=ShellCredentials(home:FileManager.default.homeDirectoryForCurrentUser)
    static func load()->String {store.load()}
    static func save(_ key:String)->Bool {do {try store.save(key);return true}catch{return false}}
}

enum PolishCredentials {
    static func valid(_ key: String, for provider: PolishProvider) -> Bool {
        provider == .custom ? ShellCredentials.validToken(key) : ShellCredentials.valid(key)
    }
    static func load(
        for provider: PolishProvider,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        store(for: provider, home: home).load(environment: environment)
    }
    static func save(
        _ key: String, for provider: PolishProvider,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        do {
            try store(for: provider, home: home).save(key, name: names(for: provider)[0])
            return true
        } catch { return false }
    }
    private static func names(for provider: PolishProvider) -> [String] {
        switch provider {
        case .deepseek: return ["DEEPSEEK_API_KEY"]
        case .bailian: return ["DASHSCOPE_API_KEY", "BAILIAN_API_KEY"]
        case .custom: return ["IMIC_CUSTOM_POLISH_API_KEY"]
        }
    }
    private static func store(for provider: PolishProvider, home: URL) -> ShellCredentials {
        ShellCredentials(home: home, names: names(for: provider), allowCustomToken: provider == .custom)
    }
}
