import Foundation
import CoreGraphics

/// Page presentation is independent of project purpose and page arrangement.
nonisolated enum PageSurfaceKind: String, Codable, CaseIterable {
    case normal, sphere
    var title: String {
        switch self {
        case .normal: return L10n.text("page.surface.normal")
        case .sphere: return L10n.text("page.surface.sphere")
        }
    }
}
nonisolated enum SphereOutsideFill: String, Codable, CaseIterable {
    case white, black, transparent
    var title: String {
        switch self {
        case .white: return L10n.text("page.surface.fill.white")
        case .black: return L10n.text("page.surface.fill.black")
        case .transparent: return L10n.text("page.surface.fill.transparent")
        }
    }
    var color: SIMD4<Float> {
        switch self {
        case .white: return SIMD4(1,1,1,1)
        case .black: return SIMD4(0,0,0,1)
        case .transparent: return .zero
        }
    }
}
nonisolated struct PageSurface: Codable, Equatable {
    var kind: PageSurfaceKind = .normal
    var radius: Double = 1024
    var outsideFill: SphereOutsideFill = .transparent
    static let normal = Self()
    var validRadius: Double { radius.isFinite ? min(1_000_000_000, max(1, radius)) : 1024 }
    var sourceRadius: Double { validRadius * .pi / 2 }
    var normalized: Self { var value=self; value.radius=validRadius; return value }
    /// Orthographic hemisphere projection, with arc length in canvas pixels.
    func sourceOffset(projected: CGPoint) -> CGPoint? {
        let r = hypot(projected.x, projected.y)
        guard r <= validRadius else { return nil }
        let factor = r > 0 ? validRadius * asin(min(1, r / validRadius)) / r : 1
        return CGPoint(x: projected.x * factor, y: projected.y * factor)
    }
}

extension PageSurface {
    nonisolated private enum CodingKeys: String,CodingKey { case kind,radius,outsideFill }
    nonisolated init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy: CodingKeys.self)
        kind=try values.decode(PageSurfaceKind.self,forKey: .kind)
        radius=try values.decodeIfPresent(Double.self,forKey: .radius) ?? 1024
        outsideFill=try values.decodeIfPresent(SphereOutsideFill.self,forKey: .outsideFill) ?? .transparent
    }
}
