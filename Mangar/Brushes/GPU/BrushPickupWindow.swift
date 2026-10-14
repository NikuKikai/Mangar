import Foundation
import CoreGraphics
import Metal

/// Reused 4x4 tile window. Copies and generation are ordered on the document queue.
final class BrushPickupWindow {
    let colors: MTLTexture
    let selection: MTLTexture
    init(device: MTLDevice) {
        func array(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray; d.pixelFormat = format
            d.width = 256; d.height = 256; d.arrayLength = 16
            d.storageMode = .private; d.usage = [.shaderRead]
            return device.makeTexture(descriptor: d)!
        }
        colors = array(.rgba8Unorm); selection = array(.r8Unorm)
    }
    func encode(command: MTLCommandBuffer, points: [StrokeSample], base: [TileKey: MTLTexture],
                layer: UUID, selection snapshot: SelectionSnapshot?, empty: MTLTexture,
                fullSelection: MTLTexture, emptySelection: MTLTexture, origin: SIMD2<Double> = .zero) -> SIMD4<Int32> {
        let minX = Int(floor((points.map(\.x).min()! - 129) / 256))
        let minY = Int(floor((points.map(\.y).min()! - 129) / 256))
        let maxX = Int(floor((points.map(\.x).max()! + 129) / 256))
        let maxY = Int(floor((points.map(\.y).max()! + 129) / 256))
        let columns = maxX - minX + 1, rows = maxY - minY + 1
        precondition(columns <= 4 && rows <= 4, "Pickup window exceeds bounded microbatch")
        let encoder = command.makeBlitCommandEncoder()!
        encoder.label = "Frozen layer and selection pickup window"
        for row in 0..<rows {
            for column in 0..<columns {
                let x = minX + column, y = minY + row, slice = row * columns + column
                let source = base[TileKey(layerID: layer, x: x, y: y)] ?? empty
                let mask = snapshot?.tiles[SelectionTileKey(x: x, y: y)] ??
                    (snapshot?.defaultCoverage == 0 ? emptySelection : fullSelection)
                for (from, to) in [(source, colors), (mask, selection)] {
                    encoder.copy(from: from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: 256, height: 256, depth: 1), to: to, destinationSlice: slice,
                        destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
        }
        encoder.endEncoding()
        return SIMD4(Int32(minX - Int(origin.x / 256)), Int32(minY - Int(origin.y / 256)), Int32(columns), Int32(rows))
    }
}
