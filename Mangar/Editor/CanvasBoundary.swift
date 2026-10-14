import Foundation
import CoreGraphics

nonisolated struct CanvasBoundary: Codable, Equatable {
    // Upper endpoints; nil denotes positive infinity. A finite lower endpoint is always zero.
    var width: Int?
    var height: Int?
    var startsAtZeroX: Bool? = nil
    var startsAtZeroY: Bool? = nil
    var hasMinimumX: Bool { startsAtZeroX ?? (width != nil) }
    var hasMinimumY: Bool { startsAtZeroY ?? (height != nil) }
    static let unlimited = Self(width: nil, height: nil)
    var finiteRect: CGRect? { guard hasMinimumX, hasMinimumY, let width, let height else { return nil }; return CGRect(x: 0, y: 0, width: width, height: height) }
    var initialRect: CGRect {
        func axis(_ upper: Int?, minimum: Bool) -> (CGFloat, CGFloat) {
            if minimum { return (0,CGFloat(min(upper ?? 2048,2048))) }
            return (upper.map { min(0,CGFloat($0)-2048) } ?? 0,2048)
        }
        let x = axis(width,minimum:hasMinimumX), y = axis(height,minimum:hasMinimumY)
        return CGRect(x:x.0,y:y.0,width:x.1,height:y.1)
    }
    func contains(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && (!hasMinimumX || p.x >= 0) && (width.map { p.x < Double($0) } ?? true) &&
            (!hasMinimumY || p.y >= 0) && (height.map { p.y < Double($0) } ?? true)
    }
    func clip(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return .null }
        let x0 = hasMinimumX ? max(0,rect.minX) : rect.minX, y0 = hasMinimumY ? max(0,rect.minY) : rect.minY
        let x1: CGFloat = width != nil ? min(CGFloat(width!), rect.maxX) : rect.maxX
        let y1: CGFloat = height != nil ? min(CGFloat(height!), rect.maxY) : rect.maxY
        guard x1 > x0, y1 > y0 else { return .null }
        return CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
    }
    func gpuClip(relativeTo origin: SIMD2<Double>) -> SIMD4<Float> {
        SIMD4(hasMinimumX ? Float(-origin.x) : -.infinity, hasMinimumY ? Float(-origin.y) : -.infinity,
              width.map { Float(Double($0)-origin.x) } ?? .infinity,
              height.map { Float(Double($0)-origin.y) } ?? .infinity)
    }
    static func tileIndex(_ pixel: Double) -> Int { Int(floor(pixel / 256)) }
}

enum ProjectPurpose: String, Codable, CaseIterable { case book, unrestricted
    var title: String { L10n.text("project.type.\(rawValue)") }
}
enum PageStructure: String, Codable { case bookSpreads, cards }
struct ProjectCreation {
    var name: String
    var purpose: ProjectPurpose
    var boundary: CanvasBoundary
    var layout: ComicPageLayout?
    var pageCount: Int
    var startingSide: PageStartSide
}
