import Foundation

enum BrushMedium: UInt32, Codable, CaseIterable {
    case dry, oil, watercolor
    var name: String { switch self { case .dry: "普通"; case .oil: "油彩"; case .watercolor: "水彩" } }
}
struct BrushWetSettings: Codable, Equatable {
    var medium: BrushMedium = .dry
    var pickup: Double = 0.55
    var mixing: Double = 1
    var load: Double = 1
    var persistence: Double = 0.7
    var dilution: Double = 0.6
    var granulation: Double = 0.25
    var edgeDarkening: Double = 0.3
    var validated: Self {
        var result = self
        for key in [\Self.pickup, \Self.mixing, \Self.load, \Self.persistence, \Self.dilution, \Self.granulation, \Self.edgeDarkening] {
            let value = result[keyPath: key]
            result[keyPath: key] = value.isFinite ? max(0, min(1, value)) : 0
        }
        return result
    }
}
