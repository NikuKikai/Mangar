import Foundation
import CoreGraphics
import Metal

/// GPU even-odd polygon rasterization. A triangle fan toggles stencil samples;
/// MSAA resolve retains fractional edge coverage, including self-intersections.
final class PolygonMaskRasterizer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let parityPipeline: MTLRenderPipelineState
    private let coveragePipeline: MTLRenderPipelineState
    private let toggleStencil: MTLDepthStencilState
    private let testStencil: MTLDepthStencilState
    private let samples: Int

    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
        self.device = device; self.queue = queue
        samples = device.supportsTextureSampleCount(4) ? 4 : 1
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "polygonMaskVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "polygonMaskFragment")
        descriptor.rasterSampleCount = samples
        descriptor.stencilAttachmentPixelFormat = .stencil8
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        descriptor.colorAttachments[0].writeMask = []
        parityPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.colorAttachments[0].writeMask = .all
        coveragePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.depthStencilPassOperation = .invert
        stencil.readMask = 1; stencil.writeMask = 1
        let depth = MTLDepthStencilDescriptor()
        depth.frontFaceStencil = stencil; depth.backFaceStencil = stencil
        toggleStencil = device.makeDepthStencilState(descriptor: depth)!
        stencil.stencilCompareFunction = .notEqual
        stencil.depthStencilPassOperation = .keep
        stencil.writeMask = 0
        depth.frontFaceStencil = stencil; depth.backFaceStencil = stencil
        testStencil = device.makeDepthStencilState(descriptor: depth)!
    }

    func rasterize(_ points: [SIMD2<Float>], canvasSize: CGSize,
                   tileSize: Int) -> [SelectionTileKey: MTLTexture] {
        guard points.count >= 3 else { return [:] }
        let minX = CGFloat(points.map(\.x).min()!)
        let minY = CGFloat(points.map(\.y).min()!)
        let maxX = CGFloat(points.map(\.x).max()!)
        let maxY = CGFloat(points.map(\.y).max()!)
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: canvasSize))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0,
              let command = queue.makeCommandBuffer() else { return [:] }
        var triangles: [SIMD2<Float>] = []
        triangles.reserveCapacity((points.count - 2) * 3)
        for index in 1..<(points.count - 1) {
            triangles.append(points[0]); triangles.append(points[index]); triangles.append(points[index + 1])
        }
        guard let vertices = device.makeBuffer(bytes: triangles,
            length: triangles.count * MemoryLayout<SIMD2<Float>>.stride) else { return [:] }
        let stencilDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .stencil8, width: tileSize, height: tileSize, mipmapped: false)
        stencilDescriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
        stencilDescriptor.sampleCount = samples
        stencilDescriptor.storageMode = .private
        stencilDescriptor.usage = .renderTarget
        guard let stencil = device.makeTexture(descriptor: stencilDescriptor) else { return [:] }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: tileSize, height: tileSize, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        let msaaDescriptor = colorDescriptor.copy() as! MTLTextureDescriptor
        msaaDescriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
        msaaDescriptor.sampleCount = samples
        guard let multisample = device.makeTexture(descriptor: msaaDescriptor) else { return [:] }
        var result: [SelectionTileKey: MTLTexture] = [:]
        let size = CGFloat(tileSize)
        for y in Int(floor(bounds.minY / size))..<Int(ceil(bounds.maxY / size)) {
            for x in Int(floor(bounds.minX / size))..<Int(ceil(bounds.maxX / size)) {
                guard let mask = device.makeTexture(descriptor: colorDescriptor) else { continue }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = samples > 1 ? multisample : mask
                pass.colorAttachments[0].resolveTexture = samples > 1 ? mask : nil
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = samples > 1 ? .multisampleResolve : .store
                pass.stencilAttachment.texture = stencil
                pass.stencilAttachment.loadAction = .clear
                pass.stencilAttachment.storeAction = .dontCare
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
                var uniforms = SIMD4<Float>(Float(x * tileSize), Float(y * tileSize), Float(tileSize), Float(tileSize))
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.setCullMode(.none)
                encoder.setStencilReferenceValue(0)
                encoder.setRenderPipelineState(parityPipeline)
                encoder.setDepthStencilState(toggleStencil)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
                // Only cover the real canvas, including partially occupied edge tiles.
                let left = Float(max(0, x * tileSize))
                let top = Float(max(0, y * tileSize))
                let right = min(Float(canvasSize.width), Float((x + 1) * tileSize))
                let bottom = min(Float(canvasSize.height), Float((y + 1) * tileSize))
                let cover: [SIMD2<Float>] = [SIMD2(left, top), SIMD2(right, top), SIMD2(left, bottom),
                    SIMD2(left, bottom), SIMD2(right, top), SIMD2(right, bottom)]
                encoder.setVertexBytes(cover, length: cover.count * MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.setRenderPipelineState(coveragePipeline)
                encoder.setDepthStencilState(testStencil)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
                result[SelectionTileKey(x: x, y: y)] = mask
            }
        }
        // Consumers use the same queue and synchronize after their own bounds reduction.
        command.commit()
        return result
    }
}
