import Foundation

/// Five monotone Hermite knots per channel. Values are straight RGB; alpha is untouched.
struct LayerCurveEffect: Codable, Equatable {
    var isEnabled = true
    var master: [Double] = [0, 0.25, 0.5, 0.75, 1]
    var red: [Double] = [0, 0.25, 0.5, 0.75, 1]
    var green: [Double] = [0, 0.25, 0.5, 0.75, 1]
    var blue: [Double] = [0, 0.25, 0.5, 0.75, 1]

    enum Channel: Int, CaseIterable { case master, red, green, blue
        var name: String { switch self { case .master: "RGB"; case .red: L10n.text("红"); case .green: L10n.text("绿"); case .blue: L10n.text("蓝") } }
    }
    subscript(_ channel: Channel) -> [Double] {
        get { switch channel { case .master: master; case .red: red; case .green: green; case .blue: blue } }
        set { let values = BrushResponseCurve(enabled: true, outputs: newValue).validated(limit: 1).outputs
            switch channel { case .master: master = values; case .red: red = values; case .green: green = values; case .blue: blue = values }
        }
    }
    func map(_ input: Double, channel: Channel) -> Double {
        BrushResponseCurve(enabled: true, outputs: self[channel]).validated(limit: 1).map(input)
    }
    /// Master first, individual channels second; the GPU uses interpolated LUT samples.
    var lookupTable: [Float] {
        Channel.allCases.flatMap { channel in
            (0...255).map { Float(map(Double($0) / 255, channel: channel)) }
        }
    }
}
