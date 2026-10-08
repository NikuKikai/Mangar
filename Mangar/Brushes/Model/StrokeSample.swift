import Foundation

struct StrokeSample: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
    /// Seconds relative to the beginning of this stroke.
    var time: Double = 0
    var altitude: Double = .pi / 2
    var azimuth: Double = 0

    func interpolated(to other: Self, fraction t: Double) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        let angleDelta = atan2(sin(other.azimuth - azimuth), cos(other.azimuth - azimuth))
        return Self(x: mix(x, other.x), y: mix(y, other.y),
                    pressure: mix(pressure, other.pressure), time: mix(time, other.time),
                    altitude: mix(altitude, other.altitude), azimuth: azimuth + angleDelta * t)
    }
}
