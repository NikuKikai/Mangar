import Foundation
import Metal

private final class BucketMaskBuffer { var values = [UInt8](repeating: 0, count: 256 * 256) }

extension MetalCanvasRenderer {
    func commitBucketFill(_ fill: BucketFillCommand) {
        let size = CanvasConstants.tileSize
        var coverage: [SelectionTileKey: BucketMaskBuffer] = [:]
        for span in fill.spans where span.y >= 0 && span.y < page.height && span.x1 > span.x0 {
            let first = max(0, span.x0), end = min(page.width, span.x1)
            guard first < end else { continue }
            for tx in (first / size)...((end - 1) / size) {
                let key = SelectionTileKey(x: tx, y: span.y / size)
                let mask = coverage[key] ?? BucketMaskBuffer()
                coverage[key] = mask
                let x0 = max(first, tx * size) - tx * size, x1 = min(end, (tx + 1) * size) - tx * size
                for x in x0..<x1 { mask.values[(span.y % size) * size + x] = 255 }
            }
        }
        let masks = coverage.mapValues { mask -> MTLTexture in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            let texture = device.makeTexture(descriptor: descriptor)!
            mask.values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size) }
            return texture
        }
        commitRegionFill(LassoFillCommand(layerID: fill.layerID, points: [], brush: fill.brush, target: fill.target, erases: fill.erases), masks: masks)
    }
}
