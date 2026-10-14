import Foundation

enum BrushTipRotation: UInt32, Codable, CaseIterable {
    case fixed, direction, stylus
    var name: String { switch self { case .fixed: L10n.text("固定"); case .direction: L10n.text("运笔"); case .stylus: L10n.text("笔倾") } }
}
enum BrushTipSequence: UInt32, Codable, CaseIterable {
    case ordered, random
    var name: String { self == .ordered ? L10n.text("顺序") : L10n.text("随机") }
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
