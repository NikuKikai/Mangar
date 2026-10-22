import SwiftUI

/// Artwork metrics are independent of the square control target. Use native
/// symbol typography so a badge cannot shrink its primary shape to fit a box.
struct ControlSymbolArtwork {
    var pointSize: CGFloat
    var offset: CGSize = .zero

    static func metrics(for name: String, pointSize: CGFloat = 13) -> Self {
        let unit = pointSize / 13
        switch name {
        case "folder.badge.plus":
            // Native symbol typography already aligns this body's horizontal
            // center. Only compensate the badge's small vertical projection.
            return Self(pointSize: pointSize, offset: CGSize(width: 0, height: -0.5 * unit))
        case "rectangle.badge.plus":
            return Self(pointSize: pointSize, offset: CGSize(width: 0, height: 1.25 * unit))
        case "rectangle.dashed.badge.record":
            return Self(pointSize: pointSize, offset: CGSize(width: 0.5 * unit, height: 1.25 * unit))
        case "lock.open", "lock.open.fill":
            // Keep the lock body stationary when its shackle opens to the right.
            return Self(pointSize: pointSize, offset: CGSize(width: 2.75 * unit, height: 0))
        case "plus.square":
            return Self(pointSize: pointSize * 14 / 13)
        case "trash":
            return Self(pointSize: pointSize * 12 / 13)
        case "drop.halffull":
            return Self(pointSize: pointSize * 14 / 13)
        case "square.and.arrow.down":
            return Self(pointSize: pointSize, offset: CGSize(width: 0, height: -unit))
        case "rotate.left":
            return Self(pointSize: pointSize, offset: CGSize(width: 0.5 * unit, height: -2 * unit))
        default:
            return Self(pointSize: pointSize)
        }
    }
}

struct ControlSymbol: View {
    let name: String
    var pointSize: CGFloat = 13
    var body: some View {
        let artwork = ControlSymbolArtwork.metrics(for: name, pointSize: pointSize)
        Image(systemName: name)
            .font(.system(size: artwork.pointSize, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .offset(artwork.offset)
    }
}
