import Foundation

/// Each preset retains its own tool parameters. Drawing RGB is shared across tools.
struct BrushPresetLibrary: Codable {
    var selected: BrushPresetID = .gPen
    var configurations: [String: BrushConfiguration] = [:]
    var color = AppColor(BrushConfiguration())

    func configuration(for preset: BrushPresetID? = nil) -> BrushConfiguration {
        let id = preset ?? selected
        var brush = configurations[id.rawValue]?.validated ?? MangaBrushes.configuration(id)
        brush.preset = id
        brush.red = color.red; brush.green = color.green; brush.blue = color.blue
        return brush
    }

    mutating func store(_ brush: BrushConfiguration) {
        let value = brush.validated
        selected = value.preset
        configurations[value.preset.rawValue] = value
        color = AppColor(value)
    }
}
