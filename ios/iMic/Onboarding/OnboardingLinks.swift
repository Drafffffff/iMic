import Foundation

enum OnboardingLinks {
    static var home: URL { URL(string: "https://drafffffff.github.io/iMic/" + (L10n.isChinese ? "" : "en/"))! }
    static var download: URL { URL(string: "?from=ios#download", relativeTo: home)!.absoluteURL }
}
