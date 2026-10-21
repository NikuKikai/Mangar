import Foundation
import CoreGraphics

/// Grab the lower-right circumference at pen-down, then resize around a fixed
/// screen-space center. Moving around that center never changes the radius.
struct BrushSizeDrag {
    let center: CGPoint
    let viewportZoom: CGFloat

    init(origin: CGPoint, initialSize: Double, viewportZoom: CGFloat) {
        self.viewportZoom = max(viewportZoom, 1e-12)
        let diagonalOffset = CGFloat(initialSize) * self.viewportZoom / (2 * sqrt(2))
        center = CGPoint(x: origin.x-diagonalOffset, y: origin.y-diagonalOffset)
    }

    func size(at point: CGPoint) -> Double {
        let radius = hypot(point.x-center.x, point.y-center.y)
        return min(2000, max(1, Double(radius / viewportZoom) * 2))
    }
}
