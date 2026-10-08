import Foundation

/// Fixed input knots with monotonic output values; applied once before recording samples.
struct PressureCurve: Codable, Equatable {
    var outputs: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static let linear = PressureCurve()
    static let soft = PressureCurve(outputs: [0, 0.5, 0.75, 0.9, 1])
    static let firm = PressureCurve(outputs: [0, 0.1, 0.25, 0.5, 1])

    var isValid: Bool {
        outputs.count == 5 && outputs.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && zip(outputs, outputs.dropFirst()).allSatisfy { $0 <= $1 }
    }

    func map(_ pressure: Double) -> Double {
        guard pressure.isFinite else { return 0 }
        let position = min(1, max(0, pressure)) * 4
        let index = min(3, Int(position))
        let t = position - Double(index)
        let start = outputs[index]
        let end = outputs[index + 1]
        let first = tangent(at: index)
        let last = tangent(at: index + 1)
        // Monotone cubic Hermite interpolation: continuous tangents at each knot.
        let a = 2 * start - 2 * end + first + last
        let b = -3 * start + 3 * end - 2 * first - last
        let value = ((a * t + b) * t + first) * t + start
        return min(end, max(start, value))
    }

    /// Slopes in knot-interval units, also used for the graph's exact Bezier segments.
    func tangent(at index: Int) -> Double {
        if index == 0 { return outputs[1] - outputs[0] }
        if index == 4 { return outputs[4] - outputs[3] }
        let left = outputs[index] - outputs[index - 1]
        let right = outputs[index + 1] - outputs[index]
        guard left > 0, right > 0 else { return 0 }
        // Harmonic means preserve monotonicity, including flat portions of the curve.
        return 2 * left * right / (left + right)
    }

    mutating func movePoint(_ index: Int, to value: Double) {
        guard outputs.indices.contains(index), value.isFinite else { return }
        let lower = index == 0 ? 0 : outputs[index - 1]
        let upper = index == 4 ? 1 : outputs[index + 1]
        outputs[index] = min(upper, max(lower, value))
    }
}
