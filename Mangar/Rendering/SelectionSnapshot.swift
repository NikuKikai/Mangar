import Foundation
import CoreGraphics
import Metal

nonisolated struct SelectionTileKey: Hashable, Sendable {
    var x: Int
    var y: Int
}

/// Immutable raw coverage. Constant tiles are flags; inversion is a global bit.
/// Resolved mixed tiles are temporary GPU read caches, shared by history snapshots.
struct SelectionSnapshot {
    private let raw: SelectionStorage
    var isInverted = false
    var defaultCoverage: UInt8 { isInverted ? 255 - raw.defaultCoverage : raw.defaultCoverage }
    var fullKeys: Set<SelectionTileKey> { isInverted ? raw.zeroKeys : raw.fullKeys }
    var zeroKeys: Set<SelectionTileKey> { isInverted ? raw.fullKeys : raw.zeroKeys }
    var tiles: [SelectionTileKey: MTLTexture] { raw.resolvedTiles(inverted:isInverted) }
    var tileBounds: [SelectionTileKey: CGRect] { isInverted ? raw.inverseBounds : raw.bounds }
    var bounds: CGRect { defaultCoverage == 255 ? .infinite : tileBounds.values.reduce(.null) { $0.union($1) } }
    var outlineKeys: Set<SelectionTileKey> {
        var keys: Set<SelectionTileKey> = []
        for key in Set(raw.tiles.keys).union(raw.fullKeys).union(raw.zeroKeys) {
            for y in -1...1 { for x in -1...1 { keys.insert(.init(x:key.x+x,y:key.y+y)) } }
        }
        return keys
    }
    init(defaultCoverage: UInt8, tiles: [SelectionTileKey: MTLTexture], tileBounds: [SelectionTileKey: CGRect], bounds: CGRect, outlineKeys: Set<SelectionTileKey>, fullKeys: Set<SelectionTileKey> = [], zeroKeys: Set<SelectionTileKey> = []) {
        raw = SelectionStorage(defaultCoverage: defaultCoverage, tiles: tiles, bounds: tileBounds, fullKeys: fullKeys, zeroKeys: zeroKeys)
    }
    func inverted() -> Self { var result = self; result.isInverted.toggle(); return result }
}

private final class SelectionStorage {
    let defaultCoverage: UInt8
    let tiles: [SelectionTileKey: MTLTexture]
    let bounds: [SelectionTileKey: CGRect]
    let fullKeys: Set<SelectionTileKey>
    let zeroKeys: Set<SelectionTileKey>
    let constants: SelectionConstants
    private var inverse: [SelectionTileKey: MTLTexture]?
    private var resolved: [Bool:[SelectionTileKey:MTLTexture]] = [:]
    lazy var inverseBounds = Dictionary(uniqueKeysWithValues: (Set(tiles.keys).union(zeroKeys)).map { key in (key,CGRect(x:key.x*256,y:key.y*256,width:256,height:256)) })
    func resolvedTiles(inverted: Bool) -> [SelectionTileKey:MTLTexture] {
        if let cached = resolved[inverted] { return cached }
        var result = inverted ? invertedTiles() : tiles
        for key in inverted ? zeroKeys : fullKeys { result[key] = constants.full }
        for key in inverted ? fullKeys : zeroKeys { result[key] = constants.empty }
        resolved[inverted] = result; return result
    }
    init(defaultCoverage: UInt8, tiles: [SelectionTileKey: MTLTexture], bounds: [SelectionTileKey: CGRect], fullKeys: Set<SelectionTileKey>, zeroKeys: Set<SelectionTileKey>) {
        self.defaultCoverage = defaultCoverage; self.tiles = tiles; self.bounds = bounds
        self.fullKeys = fullKeys; self.zeroKeys = zeroKeys; constants = SelectionConstants.shared
    }
    func invertedTiles() -> [SelectionTileKey: MTLTexture] {
        if let inverse { return inverse }
        guard let command = constants.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return [:] }
        encoder.setComputePipelineState(constants.invert)
        var result: [SelectionTileKey: MTLTexture] = [:]
        for (key, source) in tiles {
            let output = constants.makeTile(fill: 0)
            encoder.setTexture(source,index:0); encoder.setTexture(output,index:1)
            encoder.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            result[key] = output
        }
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed, "Selection resolution failed")
        inverse = result; return result
    }
}

private final class SelectionConstants {
    static let shared = SelectionConstants()
    let device = MTLCreateSystemDefaultDevice()!
    let queue: MTLCommandQueue
    let invert: MTLComputePipelineState
    lazy var full = makeTile(fill: 255)
    lazy var empty = makeTile(fill: 0)
    private init() {
        queue = device.makeCommandQueue()!
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void invertMask(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::write> b [[texture(1)]],uint2 p [[thread_position_in_grid]]) { b.write(float4(1.0-a.read(p).r),p); }
        """
        let library = try! device.makeLibrary(source:source,options:nil)
        invert = try! device.makeComputePipelineState(function:library.makeFunction(name:"invertMask")!)
    }
    func makeTile(fill: UInt8) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:256,height:256,mipmapped:false)
        d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
        let t = device.makeTexture(descriptor:d)!
        let data = Data(repeating:fill,count:256*256)
        data.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256) }
        return t
    }
}
