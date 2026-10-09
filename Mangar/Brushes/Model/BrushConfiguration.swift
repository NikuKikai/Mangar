import Foundation

enum BrushPresetID: String, Codable, CaseIterable {
    case pencil, gPen, technicalPen, binaryPen, oilFlat
    static let oilPresets: [Self] = [.oilFlat]
    static let inkPresets: [Self] = [.gPen, .technicalPen, .binaryPen]
    var icon: String {
        switch self {
        case .pencil: "pencil"
        case .gPen: "fountainpen.tip"
        case .technicalPen: "pencil.tip"
        case .binaryPen: "square.fill"
        case .oilFlat: "paintbrush.fill"
        }
    }
    var name: String {
        switch self {
        case .pencil: "铅笔"
        case .gPen: "G 笔"
        case .technicalPen: "针管笔"
        case .binaryPen: "二值笔"
        case .oilFlat: "平头油画笔"
        }
    }
}

enum BrushAccumulation: UInt32, Codable, CaseIterable {
    case flat, flow, buildUp
    var name: String {
        switch self {
        case .flat: "平涂"
        case .flow: "流量"
        case .buildUp: "叠加"
        }
    }
}

struct BrushConfiguration: Codable, Equatable {
    var preset: BrushPresetID = .gPen
    var size: Double = 12
    var opacity: Double = 1
    var flow: Double = 1
    var spacing: Double = 0.12
    var sizeJitter: Double = 0
    var opacityJitter: Double = 0
    var positionJitter: Double = 0
    var accumulation: BrushAccumulation = .flat
    var red: Double = 0.08
    var green: Double = 0.08
    var blue: Double = 0.09
    // Missing fields in existing app settings resolve to each preset's established behavior.
    var dynamics: BrushDynamics? = nil
    var tip: BrushTipSettings? = nil
    var rendering: BrushRenderingSettings? = nil
    var resourceID: UUID? = nil
    var stamp: BrushStampSettings? = nil
    var stampSettings: BrushStampSettings {
        get { (stamp ?? MangaBrushes.stamp(preset)).validated }
        set { stamp = newValue.validated }
    }

    var renderingSettings: BrushRenderingSettings {
        get {
            if let rendering { return rendering }
            let defaults = MangaBrushes.definition(preset)
            // Preserve the effective behavior of settings saved before rendering was editable.
            return BrushRenderingSettings(deposition: defaults.deposition, binary: defaults.binary,
                                          accumulation: defaults.isSolidInk ? .flat : accumulation)
        }
        set { rendering = newValue }
    }

    var resolvedDynamics: BrushDynamics {
        get { (dynamics ?? MangaBrushes.dynamics(preset)).validated }
        set { dynamics = newValue.validated }
    }
    var tipSettings: BrushTipSettings {
        get { (tip ?? MangaBrushes.definition(preset).tip).validated }
        set { tip = newValue.validated }
    }
    var definition: BrushDefinition {
        var value = MangaBrushes.definition(preset)
        value.tip = tipSettings
        value.deposition = renderingSettings.deposition
        value.binary = renderingSettings.binary
        return value
    }
    func radius(pressure: Double, altitude: Double = .pi / 2, speed: Double = 0) -> Double {
        let d = resolvedDynamics
        let amount = flow * d.flow.value(pressure: pressure, speed: speed, altitude: altitude)
        return size * d.size.value(pressure: pressure, speed: speed, altitude: altitude) *
            definition.inkSize(flow: amount) / 2
    }

    var validated: Self {
        var result = self
        func clamp(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : fallback
        }
        result.size = clamp(size, 1...2000, 12)
        result.spacing = clamp(spacing, 0.025...1, 0.12)
        result.opacity = clamp(opacity, 0...1, 1)
        result.flow = clamp(flow, 0...1, 1)
        result.sizeJitter = clamp(sizeJitter, 0...1, 0)
        result.opacityJitter = clamp(opacityJitter, 0...1, 0)
        result.positionJitter = clamp(positionJitter, 0...1, 0)
        result.red = clamp(red, 0...1, 0)
        result.green = clamp(green, 0...1, 0)
        result.blue = clamp(blue, 0...1, 0)
        result.dynamics = dynamics?.validated
        result.tip = tip?.validated
        result.stamp = stamp?.validated
        return result
    }

    mutating func select(_ preset: BrushPresetID, from defaults: UserDefaults = .standard) {
        guard preset != self.preset || resourceID != nil else { return }
        // Store before switching too, so callers need not depend on a UI observer's timing.
        AppToolPreferences.saveBrush(self, to: defaults)
        self = AppToolPreferences.loadBrush(preset: preset, from: defaults)
        AppToolPreferences.saveBrush(self, to: defaults)
    }
}
