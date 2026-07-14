import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case japanese = "ja"
    case english = "en"

    static func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let identifier = preferredLanguages.first else { return .english }
        return Locale(identifier: identifier).language.languageCode?.identifier == "ja" ? .japanese : .english
    }
}

enum L10n {
    static var language: AppLanguage { AppLanguage.resolve() }

    /// SwiftPM executables use `Bundle.module`, while the signed `.app`
    /// package keeps the generated resource bundle in Contents/Resources so
    /// it remains a valid macOS bundle. Prefer that packaged location.
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QuadFinder_QuadFinder.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func tr(_ key: String, language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        guard let path = resources.path(forResource: selected.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        String(format: tr(key, language: language), locale: Locale.current, arguments: arguments)
    }
}
