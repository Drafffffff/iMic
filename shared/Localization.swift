import Foundation

/// A single language policy for both apps. Each app owns its compiled resource bundle.
/// Select by the first system/app language, so zh-Hant also uses Simplified Chinese,
/// and an unsupported first language never falls through to a secondary Chinese one.
public enum L10n {
    public static func language(for preferredLanguages: [String]) -> String {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    public static var language: String { language(for: Locale.preferredLanguages) }
    public static var isChinese: Bool { language == "zh-Hans" }
    public static var locale: Locale { Locale(identifier: language) }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments: arguments, bundle: .main, language: language)
    }
    public static func localized(_ key: String, arguments: [CVarArg] = [], bundle: Bundle, language: String) -> String {
        let fallback = key.components(separatedBy: "##").first ?? key
        let english = bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        let selected = bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? english ?? bundle
        let englishText = english?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        #if os(iOS)
        let translated = String(localized: String.LocalizationValue(key), bundle: selected, locale: Locale(identifier: language))
        let value = translated == key ? englishText : translated
        #else
        let value = NSLocalizedString(key, bundle: selected, value: englishText, comment: "")
        #endif
        return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language), arguments: arguments)
    }
    /// Format numbers before substituting %@, avoiding assumptions about Swift integer widths.
    public static func argument<T>(_ value: T) -> String {
        if let number = value as? NSNumber {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter.string(from: number) ?? number.stringValue
        }
        return String(describing: value)
    }
    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
