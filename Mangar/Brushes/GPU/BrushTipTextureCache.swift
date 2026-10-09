import Foundation
import CoreGraphics
import Metal

/// Bounded device-local cache; command buffers retain textures evicted during later strokes.
final class BrushTipTextureCache {
    private var textures: [String: MTLTexture] = [:]
    private var order: [String] = []
    func texture(assets: [BrushTipAsset], device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        let key = assets.map(\.id).joined(separator: ":")
        if let texture = textures[key] {
            order.removeAll { $0 == key }; order.append(key); return texture
        }
        let extent = assets.map { max($0.width, $0.height) }.max() ?? 1
        // Transparent gutter avoids clamped edge pixels bleeding beyond the stamp.
        let side = assets.isEmpty ? 1 : extent + 2
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray; descriptor.pixelFormat = .r8Unorm
        descriptor.width = side; descriptor.height = side; descriptor.arrayLength = max(1, assets.count)
        descriptor.mipmapLevelCount = Int(floor(log2(Double(side)))) + 1
        descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        for layer in 0..<descriptor.arrayLength {
            var pixels = [UInt8](repeating: assets.isEmpty ? 255 : 0, count: side * side)
            if !assets.isEmpty {
                let asset = assets[layer]
                let provider = CGDataProvider(data: asset.coverage as CFData)!
                let image = CGImage(width: asset.width, height: asset.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: asset.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                pixels.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                    context.interpolationQuality = .high
                    let scale = Double(extent) / Double(max(asset.width, asset.height))
                    let w = Double(asset.width) * scale, h = Double(asset.height) * scale
                    context.draw(image, in: CGRect(x: (Double(side)-w)/2, y: (Double(side)-h)/2, width: w, height: h))
                }
            }
            pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, slice: layer,
                    withBytes: bytes.baseAddress!, bytesPerRow: side, bytesPerImage: side * side)
            }
        }
        if descriptor.mipmapLevelCount > 1 {
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeBlitCommandEncoder()!
            encoder.generateMipmaps(for: texture); encoder.endEncoding(); command.commit()
        }
        textures[key] = texture; order.append(key)
        // At most 32 MiB (8 x 16 x 1026² would be too much); use actual texture size.
        func cost(_ item: MTLTexture) -> Int { item.width * item.height * item.arrayLength * 4 / 3 }
        while order.count > 1 && textures.values.reduce(0, { $0 + cost($1) }) > 32 * 1024 * 1024 {
            textures.removeValue(forKey: order.removeFirst())
        }
        return texture
    }
}
