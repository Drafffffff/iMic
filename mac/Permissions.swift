import AppKit
import ApplicationServices

struct InputPermissionState {
    let accessibility:Bool
    let posting:Bool
    var allowed:Bool {accessibility && posting}
    var message:String {
        if allowed{return "已允许 · 可以自动输入"}
        if accessibility{return "辅助功能已开启 · 输入授权尚未生效"}
        return "尚未授权 · 添加应用后，请开启旁边的开关"
    }
}

enum PermissionApplication {
    static func resolve(running:URL?,bundle:URL)->URL? {
        for candidate in [running,bundle].compactMap({$0}) where candidate.isFileURL && candidate.pathExtension.lowercased()=="app" {
            return candidate.standardizedFileURL
        }
        return nil
    }
    static var current:URL? {resolve(running:NSRunningApplication.current.bundleURL,bundle:Bundle.main.bundleURL)}
}
