import Foundation
import CoreGraphics
import Metal

/// Each parent covers four signed child coordinates and stores their GPU-filtered result.
@MainActor final class CanvasTileLOD {
    struct Node: Hashable { var key: TileKey; var level: Int
        var rect: CGRect { let size = 256.0 * pow(2.0,Double(level)); return CGRect(x:Double(key.x)*size,y:Double(key.y)*size,width:size,height:size) }
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let transparent: MTLTexture
    private let white: MTLTexture
    private var cache: [Node:MTLTexture] = [:]
    private var order: [Node] = []
    private var cost = 0
    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, transparent: MTLTexture, white: MTLTexture) throws {
        self.device=device; self.queue=queue; self.transparent=transparent; self.white=white
        pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"downsampleCanvasTile")!)
    }
    func invalidate() { cache.removeAll(); order.removeAll(); cost=0 }
    func texture(_ node: Node, occupied: Set<Node>, leaf: (TileKey)->MTLTexture?) -> MTLTexture? {
        if node.level == 0 { return leaf(node.key) }
        if let value=cache[node] { return value }
        let children=(0..<4).map { i in Node(key:TileKey(layerID:node.key.layerID,x:node.key.x*2+i%2,y:node.key.y*2+i/2,target:node.key.target),level:node.level-1) }
        let fallback=node.key.target == .mask ? white : transparent
        let inputs=children.map { child -> MTLTexture in
            let hasChild=occupied.contains(child)
            return hasChild ? (texture(child,occupied:occupied,leaf:leaf) ?? fallback) : fallback
        }
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:node.key.target == .mask ? .r8Unorm : .rgba8Unorm,width:256,height:256,mipmapped:false)
        d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
        guard let result=device.makeTexture(descriptor:d),let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        for i in 0..<4 { encoder.setTexture(inputs[i],index:i) }; encoder.setTexture(result,index:4)
        encoder.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        while cost + node.key.rawSize > 64*1024*1024 && !order.isEmpty {
            let old=order.removeFirst(); if cache.removeValue(forKey:old) != nil { cost-=old.key.rawSize }
        }
        cache[node]=result; order.append(node); cost+=node.key.rawSize
        return result
    }
}
