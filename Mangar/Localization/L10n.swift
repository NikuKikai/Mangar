import Foundation

/// App override or system language is resolved by Bundle; document strings are never keys.
nonisolated enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        let source = bundle.bundleURL == Bundle.main.bundleURL ? AppLanguage.stored().bundle() : bundle
        return source.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.stored().locale))
    }
    static func format(_ key: String, _ values: String...) -> String {
        format(key, values: values)
    }
    static func format(_ key: String, values: [String], bundle: Bundle = .main) -> String {
        String(format: text(key, bundle: bundle), locale: AppLanguage.stored().locale,
               arguments: values.map { $0 as CVarArg })
    }
}
