import Foundation

struct BrushTipSettings: Codable, Equatable {
    var hardness: Double = 1
    var grain: Double = 0
    var tiltElongation: Double = 0
    var timeRate: Double = 0
    var pooling: Double = 0

    var validated: Self {
        func clamp(_ value: Double, _ maximum: Double) -> Double {
            value.isFinite ? max(0, min(maximum, value)) : 0
        }
        return Self(hardness: clamp(hardness, 1), grain: clamp(grain, 1),
                    tiltElongation: clamp(tiltElongation, 2), timeRate: clamp(timeRate, 240), pooling: clamp(pooling, 1))
    }
}
