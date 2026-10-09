import Foundation

enum BrushTipRotation: UInt32, Codable, CaseIterable {
    case fixed, direction, stylus
    var name: String { switch self { case .fixed: "固定"; case .direction: "运笔"; case .stylus: "笔倾" } }
}
enum BrushTipSequence: UInt32, Codable, CaseIterable {
    case ordered, random
    var name: String { self == .ordered ? "顺序" : "随机" }
}
struct BrushStampSettings: Codable, Equatable {
    var assetIDs: [String] = []
    var aspect: Double = 1
    var angle: Double = 0
    var rotation: BrushTipRotation = .stylus
    var sequence: BrushTipSequence = .ordered
    var validated: Self {
        var value = self
        value.assetIDs = Array(assetIDs.prefix(16))
        value.aspect = aspect.isFinite ? max(0.1, min(4, aspect)) : 1
        value.angle = angle.isFinite ? max(-180, min(180, angle)) : 0
        return value
    }
}
