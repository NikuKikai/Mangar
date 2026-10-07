import Foundation

/// Current tool settings belong to the app; recorded strokes retain their own brush copy.
enum AppToolPreferences {
    private static let brushKey = "Mangar.tools.roundBrush.v1"

    static func loadBrush(from defaults: UserDefaults = .standard) -> RoundBrush {
        guard let data = defaults.data(forKey: brushKey),
              let brush = try? JSONDecoder().decode(RoundBrush.self, from: data) else {
            return RoundBrush()
        }
        return brush
    }

    static func saveBrush(_ brush: RoundBrush, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(brush) else { return }
        defaults.set(data, forKey: brushKey)
    }
}
