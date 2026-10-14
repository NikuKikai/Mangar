import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese = "zh-Hans", japanese = "ja", english = "en"
    static let preferenceKey = "Mangar.application.language.v1"
    static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
    var name: String {
        switch self {
        case .system: L10n.text("language.system")
        case .chinese: "简体中文"
        case .japanese: "日本語"
        case .english: "English"
        }
    }
    var locale: Locale { self == .system ? .current : Locale(identifier: rawValue) }
    private static let mainBundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        allCases.filter { $0 != .system }.compactMap { language in
            guard let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language.rawValue, bundle)
        })
    func bundle(in source: Bundle = .main) -> Bundle {
        if source.bundleURL == Bundle.main.bundleURL { return Self.mainBundles[rawValue] ?? source }
        guard self != .system, let url = source.url(forResource: rawValue, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return source }
        return localized
    }
}
