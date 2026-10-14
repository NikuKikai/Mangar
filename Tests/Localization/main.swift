import Foundation

@main
struct LocalizationChecks {
    static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        let strings = root["strings"] as! [String: [String: Any]]
        let suiteName = "Mangar.localization.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        precondition(AppLanguage.stored(in: defaults) == .system)
        let appBundle = Bundle(url: app)!
        for choice in AppLanguage.allCases {
            defaults.set(choice.rawValue, forKey: AppLanguage.preferenceKey)
            precondition(AppLanguage.stored(in: defaults) == choice, "Language persistence")
            if choice != .system {
                let source = choice.bundle(in: appBundle)
                let expected = choice == .chinese ? "应用设定" : choice == .japanese ? "アプリ設定" : "App Settings"
                precondition(L10n.text("settings.title", bundle: source) == expected, "Override bundle")
            }
        }
        defaults.set("invalid", forKey: AppLanguage.preferenceKey)
        precondition(AppLanguage.stored(in: defaults) == .system, "Unknown language fallback")
        print("PASS app language persistence, explicit language bundles, system/default fallback")
        for language in ["zh-Hans", "ja", "en"] {
            guard let bundle = Bundle(url: app.appendingPathComponent(language + ".lproj")) else { fatalError("Missing language bundle: \(language)") }
            for (key, entry) in strings {
                let locales = entry["localizations"] as! [String: [String: Any]]
                let unit = locales[language]!["stringUnit"] as! [String: String]
                precondition(L10n.text(key, bundle: bundle) == unit["value"], "Missing compiled translation: \(language) / \(key)")
            }
            let opacity = L10n.format("当前颜色 · 不透明度 %@%%", values: ["42"], bundle: bundle)
            precondition(opacity.contains("42%") && !opacity.contains("%@"), "Percent formatting: \(language)")
            let name = "My Project 100% 漫画"
            let deletion = L10n.format("“%@”及其所有页面将被删除，此操作无法撤销。", values: [name], bundle: bundle)
            precondition(deletion.contains(name), "User name was altered: \(language)")
            let file = L10n.format("Mangar-第%@页-%@.png", values: ["2", "abc"], bundle: bundle)
            precondition(file.contains("2") && file.contains("abc") && file.hasSuffix(".png"), "Filename format: \(language)")
            print("PASS \(language): \(strings.count) compiled translations, percent formatting, user content, export filename")
        }
    }
}
