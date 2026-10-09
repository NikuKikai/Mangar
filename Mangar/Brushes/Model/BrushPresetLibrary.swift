import Foundation

/// Each preset retains its own tool parameters. Drawing RGB is shared across tools.
struct BrushPresetLibrary: Codable {
    var selected: BrushPresetID = .gPen
    var selectedResourceID: UUID? = nil
    var customConfigurations: [String: BrushConfiguration]? = nil
    var configurations: [String: BrushConfiguration] = [:]
    var color = AppColor(BrushConfiguration())

    func configuration(for preset: BrushPresetID? = nil) -> BrushConfiguration {
        let id = preset ?? selected
        var brush: BrushConfiguration
        if preset == nil, let resourceID = selectedResourceID,
           let saved = customConfigurations?[resourceID.uuidString] { brush = saved.validated }
        else { brush = configurations[id.rawValue]?.validated ?? MangaBrushes.configuration(id) }
        if brush.resourceID == nil { brush.preset = id }
        brush.red = color.red; brush.green = color.green; brush.blue = color.blue
        return brush
    }

    mutating func store(_ brush: BrushConfiguration) {
        let value = brush.validated
        selected = value.preset
        selectedResourceID = value.resourceID
        if let id = value.resourceID {
            if customConfigurations == nil { customConfigurations = [:] }
            customConfigurations?[id.uuidString] = value
        } else { configurations[value.preset.rawValue] = value }
        color = AppColor(value)
    }
}
