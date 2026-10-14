import Foundation

enum BrushParameter: String, Codable, CaseIterable, Identifiable {
    case size, flow, opacity
    var id: String { rawValue }
    var name: String {
        switch self { case .size: L10n.text("大小"); case .flow: L10n.text("流量 / 出墨量"); case .opacity: L10n.text("不透明度") }
    }
    var outputLimit: Double { self == .size ? 3 : 1 }
}

enum BrushDynamicInput: String, Codable, CaseIterable, Identifiable {
    case pressure, speed, tilt
    var id: String { rawValue }
    var name: String {
        switch self { case .pressure: L10n.text("压力"); case .speed: L10n.text("速度"); case .tilt: L10n.text("倾斜") }
    }
}

/// Five editable output knots; supports increasing, decreasing and peaked smooth curves.
struct BrushResponseCurve: Codable, Equatable {
    var enabled = false
    var outputs: [Double] = [0, 0.25, 0.5, 0.75, 1]

    func validated(limit: Double) -> Self {
        guard outputs.count == 5, outputs.allSatisfy(\.isFinite) else { return Self() }
        var curve = self
        curve.outputs = outputs.map { min(limit, max(0, $0)) }
        return curve
    }
    func tangent(at index: Int) -> Double {
        if index == 0 { return outputs[1] - outputs[0] }
        if index == 4 { return outputs[4] - outputs[3] }
        let left = outputs[index] - outputs[index - 1]
        let right = outputs[index + 1] - outputs[index]
        guard left * right > 0 else { return 0 }
        return 2 * left * right / (left + right)
    }
    func map(_ input: Double) -> Double {
        guard enabled else { return 1 }
        let position = min(1, max(0, input.isFinite ? input : 0)) * 4
        let index = min(3, Int(position)), t = position - Double(index)
        let a = outputs[index], b = outputs[index + 1]
        let m = tangent(at: index), n = tangent(at: index + 1)
        let value = (((2*a - 2*b + m + n)*t + (-3*a + 3*b - 2*m - n))*t + m)*t + a
        return min(max(a,b), max(min(a,b), value))
    }
    var maximum: Double { enabled ? outputs.max() ?? 1 : 1 }
}

struct BrushParameterDynamics: Codable, Equatable {
    var pressure = BrushResponseCurve()
    var speed = BrushResponseCurve(outputs: [1, 0.75, 0.5, 0.25, 0])
    var tilt = BrushResponseCurve()
    var isEnabled: Bool { pressure.enabled || speed.enabled || tilt.enabled }
    var maximum: Double { pressure.maximum * speed.maximum * tilt.maximum }
    subscript(_ input: BrushDynamicInput) -> BrushResponseCurve {
        get { switch input { case .pressure: pressure; case .speed: speed; case .tilt: tilt } }
        set { switch input { case .pressure: pressure = newValue; case .speed: speed = newValue; case .tilt: tilt = newValue } }
    }
    func value(pressure: Double, speed: Double, altitude: Double) -> Double {
        self.pressure.map(pressure) * self.speed.map(max(0, speed) / (max(0, speed) + 40)) *
            tilt.map(1 - sin(min(.pi / 2, max(0, altitude))))
    }
    func validated(limit: Double) -> Self {
        Self(pressure: pressure.validated(limit: limit), speed: speed.validated(limit: limit), tilt: tilt.validated(limit: limit))
    }
}

struct BrushDynamics: Codable, Equatable {
    var size = BrushParameterDynamics()
    var flow = BrushParameterDynamics()
    var opacity = BrushParameterDynamics()
    subscript(_ parameter: BrushParameter) -> BrushParameterDynamics {
        get { switch parameter { case .size: size; case .flow: flow; case .opacity: opacity } }
        set { switch parameter { case .size: size = newValue; case .flow: flow = newValue; case .opacity: opacity = newValue } }
    }
    var validated: Self {
        Self(size: size.validated(limit: 3), flow: flow.validated(limit: 1), opacity: opacity.validated(limit: 1))
    }
}
