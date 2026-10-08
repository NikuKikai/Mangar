import Foundation
import CoreGraphics

struct ShapeColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = ShapeColor(red: 1, green: 1, blue: 1)
    var premultiplied: SIMD4<Float> {
        SIMD4<Float>(Float(red * alpha), Float(green * alpha), Float(blue * alpha), Float(alpha))
    }
}

/// A graphic layer owns a shape rather than raster tiles. Additional geometry can
/// extend this enum without adding more special-purpose layer kinds.
enum LayerShape: Codable, Equatable {
    case rect(bounds: CGRect, fill: ShapeColor)

    var bounds: CGRect {
        get { switch self { case .rect(let bounds, _): return bounds } }
        set { switch self { case .rect(_, let fill): self = .rect(bounds: newValue, fill: fill) } }
    }
    var fill: ShapeColor {
        switch self { case .rect(_, let fill): return fill }
    }
}
