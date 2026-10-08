import Foundation

/// Current tool settings belong to the app; recorded strokes retain their own brush copy.
enum AppToolPreferences {
    private static let pressureCurveKey = "Mangar.tools.pressureCurve.v1"
    private static let presetKey = "Mangar.tools.colorPresets.v1"
    private static let transparentKey = "Mangar.tools.transparentColor.v1"
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
    static func loadPressureCurve(from defaults: UserDefaults = .standard) -> PressureCurve {
        guard let data = defaults.data(forKey: pressureCurveKey),
              let curve = try? JSONDecoder().decode(PressureCurve.self, from: data), curve.isValid else {
            return .linear
        }
        return curve
    }

    static func savePressureCurve(_ curve: PressureCurve, to defaults: UserDefaults = .standard) {
        guard curve.isValid, let data = try? JSONEncoder().encode(curve) else { return }
        defaults.set(data, forKey: pressureCurveKey)
    }

    static func loadColorPresets(from defaults: UserDefaults = .standard) -> [AppColor] {
        if let data = defaults.data(forKey: presetKey),
           let colors = try? JSONDecoder().decode([AppColor].self, from: data),
           colors.count == 16, colors.allSatisfy(\.isValid) { return colors }
        let values: [UInt32] = [0x000000, 0x555555, 0xaaaaaa, 0xffffff,
            0x883333, 0xcc6644, 0xddaa55, 0xeedd99,
            0x335577, 0x4488aa, 0x559977, 0x99bb88,
            0x664488, 0xaa6699, 0xcc9999, 0xddd5c5]
        return values.map { AppColor(red: Double(($0 >> 16) & 255) / 255,
            green: Double(($0 >> 8) & 255) / 255, blue: Double($0 & 255) / 255, opacity: 1) }
    }

    static func saveColorPresets(_ colors: [AppColor], to defaults: UserDefaults = .standard) {
        guard colors.count == 16, colors.allSatisfy(\.isValid),
              let data = try? JSONEncoder().encode(colors) else { return }
        defaults.set(data, forKey: presetKey)
    }

    static func loadTransparentColor(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: transparentKey)
    }
    static func saveTransparentColor(_ selected: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(selected, forKey: transparentKey)
    }

}

struct AppColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    init(_ brush: RoundBrush) {
        self.init(red: brush.red, green: brush.green, blue: brush.blue, opacity: brush.opacity)
    }
    var isValid: Bool { [red, green, blue, opacity].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}
