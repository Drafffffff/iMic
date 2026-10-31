import AppKit
import ApplicationServices

struct InputPermissionState {
    let accessibility:Bool
    let posting:Bool
    var allowed:Bool {accessibility && posting}
    var message:String {
        if allowed{return L10n.text("Allowed · Automatic typing available")}
        if accessibility{return L10n.text("Accessibility enabled · Typing permission has not taken effect")}
        return L10n.text("Not authorized · Add the app, then enable its switch")
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
