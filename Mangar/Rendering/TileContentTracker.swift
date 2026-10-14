import Foundation
import CoreGraphics
import Metal

/// Actual occupied bounds, independent of dirty bounds. Missing R8 masks are white.
@MainActor
final class TileContentTracker {
    private struct Measurement {
        let texture: MTLTexture
        let buffer: MTLBuffer
        let command: MTLCommandBuffer
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var pending: [TileKey: Measurement] = [:]
    private var lastCommand: MTLCommandBuffer?
    var onReady: (() -> Void)?

    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
        self.device = device; self.queue = queue
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "tileContentBounds")!)
    }
    func record(_ textures: [TileKey: MTLTexture], width: Int, height: Int, boundary: CanvasBoundary? = nil) {
        guard !textures.isEmpty, let command = queue.makeCommandBuffer() else { return }
        command.label = "Measure actual tile content"
        for (key, texture) in textures {
            let initial: [UInt32] = [256, 256, 0, 0]
            guard let buffer = device.makeBuffer(bytes: initial, length: 16),
                  let encoder = command.makeComputeCommandEncoder() else { continue }
            var isMask: UInt32 = key.target == .mask ? 1 : 0
            var valid = SIMD2<UInt32>(256, 256)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&isMask, length: 4, index: 0)
            encoder.setBuffer(buffer, offset: 0, index: 1)
            encoder.setBytes(&valid, length: 8, index: 2)
            encoder.dispatchThreads(MTLSize(width: 256, height: 256, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            pending[key] = Measurement(texture: texture, buffer: buffer, command: command)
        }
        command.addCompletedHandler { [weak self] completed in
            guard completed.status == .completed else { return }
            Task { @MainActor [weak self] in self?.onReady?() }
        }
        lastCommand = command
        command.commit()
    }
    func invalidate(layerID: UUID? = nil, target: LayerEditTarget? = nil) {
        if let layerID { pending = pending.filter { $0.key.layerID != layerID || (target != nil && $0.key.target != target) } }
        else { pending.removeAll() }
    }
    func synchronize() { lastCommand?.waitUntilCompleted() }

    /// Only completed measurements of the currently published texture can retire a tile.
    @discardableResult
    func resolve(tiles: inout [TileKey: MTLTexture], bounds: inout [TileKey: CGRect],
                 dirty: inout [TileKey: CGRect]) -> Set<UUID> {
        var changed = Set<UUID>()
        for (key, measurement) in pending where measurement.command.status == .completed {
            pending.removeValue(forKey: key)
            guard let current = tiles[key], current === measurement.texture else { continue }
            let p = measurement.buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            changed.insert(key.layerID)
            if p[0] < p[2], p[1] < p[3] {
                bounds[key] = CGRect(x: key.x * 256 + Int(p[0]), y: key.y * 256 + Int(p[1]),
                                     width: Int(p[2] - p[0]), height: Int(p[3] - p[1]))
            } else {
                tiles.removeValue(forKey: key)
                bounds.removeValue(forKey: key)
                // Keep deletion dirty so the atomic project manifest drops its old file.
                dirty[key] = (dirty[key] ?? .null).union(CGRect(x: key.x * 256, y: key.y * 256, width: 256, height: 256))
            }
        }
        return changed
    }
}
