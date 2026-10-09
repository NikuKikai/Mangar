import Foundation

enum MangaBrushes {
    static func definition(_ preset: BrushPresetID) -> BrushDefinition {
        switch preset {
        case .pencil:
            BrushDefinition(preset: preset, tip: BrushTipSettings(hardness: 0.75, grain: 0.85, tiltElongation: 0.65))
        case .oilFlat:
            BrushDefinition(preset: preset)
        case .gPen:
            BrushDefinition(preset: preset, deposition: .solidInk)
        case .technicalPen:
            BrushDefinition(preset: preset, tip: BrushTipSettings(timeRate: 60, pooling: 0.6), deposition: .solidInk)
        case .binaryPen:
            BrushDefinition(preset: preset, binary: true, deposition: .solidInk)
        }
    }

    static func dynamics(_ preset: BrushPresetID) -> BrushDynamics {
        var result = BrushDynamics()
        switch preset {
        case .pencil:
            result.size.pressure = BrushResponseCurve(enabled: true,
                outputs: (0...4).map { 0.15 + 0.85 * pow(Double($0) / 4, 0.8) })
            result.size.tilt = BrushResponseCurve(enabled: true,
                outputs: (0...4).map { 1 + 1.25 * Double($0) / 4 })
            result.flow.pressure = BrushResponseCurve(enabled: true, outputs: [0.15, 0.3625, 0.575, 0.7875, 1])
        case .gPen:
            result.size.pressure = BrushResponseCurve(enabled: true,
                outputs: (0...4).map { 0.025 + 0.975 * pow(Double($0) / 4, 1.35) })
        case .technicalPen:
            result.size.speed = BrushResponseCurve(enabled: true, outputs: [1, sqrt(0.75), sqrt(0.5), 0.5, 0.15])
        case .oilFlat:
            result.size.pressure = BrushResponseCurve(enabled: true, outputs: [0.3, 0.475, 0.65, 0.825, 1])
            result.flow.pressure = BrushResponseCurve(enabled: true, outputs: [0.25, 0.4375, 0.625, 0.8125, 1])
        case .binaryPen: break
        }
        return result
    }

    static func stamp(_ preset: BrushPresetID) -> BrushStampSettings {
        if preset == .oilFlat {
            return BrushStampSettings(assetIDs: [BundledBrushTips.oilFlatID], rotation: .direction)
        }
        return BrushStampSettings()
    }

    static func configuration(_ preset: BrushPresetID) -> BrushConfiguration {
        var result = BrushConfiguration()
        result.preset = preset
        switch preset {
        case .pencil:
            result.size = 16; result.flow = 0.18; result.spacing = 0.12
            result.accumulation = .flow
        case .oilFlat:
            result.size = 60; result.flow = 0.7; result.spacing = 0.08
            result.accumulation = .flow
        case .gPen: break
        case .technicalPen:
            result.size = 5; result.flow = 1; result.spacing = 0.15
            result.accumulation = .flow
        case .binaryPen:
            result.size = 8; result.spacing = 0.1
        }
        return result
    }
}
