import Foundation

enum BrushDeposition: UInt32, Codable {
    case pigment, solidInk
}

/// Frozen execution identity and tip settings; all scalar input dynamics live in BrushDynamics.
struct BrushDefinition: Codable, Equatable {
    var version: Int = 4
    var preset: BrushPresetID
    var tip: BrushTipSettings = BrushTipSettings()
    var binary: Bool = false
    var deposition: BrushDeposition = .pigment

    var isSolidInk: Bool { deposition == .solidInk }
    var timeRate: Double { tip.timeRate }
    func inkSize(flow: Double) -> Double {
        guard isSolidInk else { return 1 }
        return flow > 0 ? min(1, sqrt(flow)) : 0
    }
    /// Conservative scheduling only. Curves may enlarge size above its base value.
    func maximumReach(_ brush: BrushConfiguration) -> Double {
        brush.size * 0.5 * brush.resolvedDynamics.size.maximum * (1 + brush.sizeJitter) *
            (1 + tip.tiltElongation) * (1 + tip.pooling) + brush.size * brush.positionJitter * 1.414214 + 2
    }
}
