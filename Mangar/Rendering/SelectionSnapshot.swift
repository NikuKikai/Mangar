import Foundation
import CoreGraphics
import Metal

struct SelectionTileKey: Hashable {
    var x: Int
    var y: Int
}

/// Textures are immutable after publication, so history checkpoints can share them.
struct SelectionSnapshot {
    var defaultCoverage: UInt8
    var tiles: [SelectionTileKey: MTLTexture]
    var tileBounds: [SelectionTileKey: CGRect]
    var bounds: CGRect
    var outlineKeys: Set<SelectionTileKey>
}

