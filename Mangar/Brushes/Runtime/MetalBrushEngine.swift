import Foundation
import CoreGraphics
@preconcurrency import Metal

/// One active transaction. Its output can be promoted without redrawing the stroke.
@MainActor
final class MetalBrushEngine {
    private struct WorkingTile {
        let base: MTLTexture
        let output: MTLTexture
        var coverage: MTLTexture
        var spareCoverage: MTLTexture
        var paintColor: MTLTexture?
        var sparePaintColor: MTLTexture?
        let bounds: MTLBuffer
    }
    private final class Transaction {
        let id: UUID
        let state: MTLBuffer
        let selection: SelectionSnapshot?
        let compiled: CompiledBrush
        var pickupBase: [TileKey: MTLTexture]
        var origin = SIMD2<Double>.zero
        var processed = 0
        var last: StrokeSample?
        var working: [TileKey: WorkingTile] = [:]
        var dirty: [TileKey: CGRect] = [:]
        init(id: UUID, state: MTLBuffer, selection: SelectionSnapshot?, compiled: CompiledBrush, base: [TileKey: MTLTexture]) {
            self.id = id; self.state = state; self.selection = selection; self.compiled = compiled; self.pickupBase = base
        }
    }
    struct Result {
        var tiles: [TileKey: MTLTexture]
        var dirtyBounds: [TileKey: CGRect]
        /// GPU-written local bounds; read only after synchronize().
        var measuredBounds: [TileKey: MTLBuffer]
    }

    private let tipCache = BrushTipTextureCache()
    private let pickupWindow: BrushPickupWindow
    private let emptyCanvas: MTLTexture
    private let emptyPaintColor: MTLTexture
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let generate: MTLComputePipelineState
    private let rebase: MTLComputePipelineState
    private let bin: MTLComputePipelineState
    private let raster: MTLComputePipelineState
    private let fullSelection: MTLTexture
    private let emptySelection: MTLTexture
    // Shared scratch is safe because all brush and document commands use one ordered queue.
    private let dabBuffer: MTLBuffer
    private let dabCountBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let subtileCountBuffer: MTLBuffer
    private var transaction: Transaction?
    private var lastSubmission: MTLCommandBuffer?
    var onTipRadius: ((UUID, CGFloat) -> Void)?
    private var cursorRevision: UInt64 = 0
    private var appliedCursorRevision: UInt64 = 0
    private static let batchSize = 8
    private static let dabCapacity = 1024

    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
        self.device = device; self.queue = queue
        pickupWindow = BrushPickupWindow(device: device)
        emptyCanvas = Self.texture(device, format: .rgba8Unorm, fill: 0)
        emptyPaintColor = Self.texture(device, format: .rgba16Float, fill: 0)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw BrushError.unavailable }
            return try device.makeComputePipelineState(function: function)
        }
        generate = try pipeline("brushGenerate")
        rebase = try pipeline("brushRebase")
        bin = try pipeline("brushBin")
        raster = try pipeline("brushRaster")
        dabBuffer = device.makeBuffer(length: Self.dabCapacity * 64, options: .storageModePrivate)!
        dabCountBuffer = device.makeBuffer(length: 4, options: .storageModePrivate)!
        indexBuffer = device.makeBuffer(length: 256 * Self.dabCapacity * 4, options: .storageModePrivate)!
        subtileCountBuffer = device.makeBuffer(length: 256 * 4, options: .storageModePrivate)!
        fullSelection = Self.texture(device, format: .r8Unorm, fill: 255)
        emptySelection = Self.texture(device, format: .r8Unorm, fill: 0)
    }

    func cancel() { transaction = nil }

    func synchronize() {
        lastSubmission?.waitUntilCompleted()
        if let error = lastSubmission?.error { assertionFailure("Brush GPU failure: \(error)") }
        lastSubmission = nil
    }

    func update(_ stroke: StrokeCommand, base: [TileKey: MTLTexture],
                selection: SelectionSnapshot?, width: Int, height: Int, boundary: CanvasBoundary? = nil, canvasOffset:CGPoint = .zero) -> Result {
        if transaction?.id != stroke.id {
            let state = device.makeBuffer(length: 96, options: .storageModeShared)!
            memset(state.contents(), 0, state.length)
            transaction = Transaction(id: stroke.id, state: state, selection: selection,
                compiled: CompiledBrush(device: device, queue: queue, cache: tipCache, stroke: stroke, capacity: Self.dabCapacity, width: width, height: height), base: base)
        }
        let context = transaction!
        context.pickupBase.merge(base) { existing,_ in existing }
        guard context.processed < stroke.samples.count else { return result(context) }
        // Only input transport is on the CPU. GPU owns spacing, dynamic evaluation and dabs.
        let initialPrevious = context.last
        var inputs: [StrokeSample] = []
        for sample in stroke.samples.dropFirst(context.processed) {
            if let previous = context.last {
                let distance = hypot(sample.x - previous.x, sample.y - previous.y)
                let duration = max(0, sample.time - previous.time)
                let steps = max(1, Int(ceil(max(distance / 8, duration * 120))))
                for step in 1...steps {
                    inputs.append(previous.interpolated(to: sample, fraction: Double(step) / Double(steps)))
                }
            } else { inputs.append(sample) }
            context.last = sample
        }
        context.processed = stroke.samples.count
        guard let command = queue.makeCommandBuffer() else { preconditionFailure("Cannot allocate brush command buffer") }
        command.label = "Brush incremental transaction"
        var previous = initialPrevious
        for start in stride(from: 0, to: inputs.count, by: Self.batchSize) {
            let batch = Array(inputs[start..<min(inputs.count, start + Self.batchSize)])
            let origin = SIMD2<Double>(floor((batch[0].x-canvasOffset.x)/256)*256, floor((batch[0].y-canvasOffset.y)/256)*256)
            if origin != context.origin {
                var delta = SIMD2<Float>(Float(context.origin.x-origin.x), Float(context.origin.y-origin.y))
                let encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(rebase); encoder.setBuffer(context.state, offset: 0, index: 0)
                encoder.setBytes(&delta, length: 8, index: 1)
                encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                encoder.endEncoding(); context.origin = origin
            }
            let gpuInputs = batch.map { BrushGPUInput($0, origin: origin+SIMD2(Double(canvasOffset.x),Double(canvasOffset.y))) }
            let inputBuffer = device.makeBuffer(bytes: gpuInputs, length: gpuInputs.count * MemoryLayout<BrushGPUInput>.stride)!
            let dabs = dabBuffer
            let count = dabCountBuffer
            var uniforms = context.compiled.uniforms
            uniforms.counts.x = UInt32(batch.count)
            uniforms.clip = (boundary ?? CanvasBoundary(width: width, height: height)).gpuClip(relativeTo: origin+SIMD2(Double(canvasOffset.x),Double(canvasOffset.y)))
            if uniforms.medium.x != 0 {
                uniforms.pickupTiles = pickupWindow.encode(command: command,
                    points: (batch + (previous.map { [$0] } ?? [])).map { sample in
                        var p=sample;p.x-=canvasOffset.x;p.y-=canvasOffset.y;return p
                    }, base: context.pickupBase, layer: stroke.layerID,
                    selection: context.selection, empty: emptyCanvas, fullSelection: fullSelection, emptySelection: emptySelection, origin: origin)
            }
            let generator = command.makeComputeCommandEncoder()!
            generator.label = "Generate brush dabs"
            generator.setComputePipelineState(generate)
            generator.setBuffer(inputBuffer, offset: 0, index: 0)
            generator.setBuffer(context.state, offset: 0, index: 1)
            generator.setBuffer(dabs, offset: 0, index: 2)
            generator.setBuffer(count, offset: 0, index: 3)
            generator.setBytes(&uniforms, length: MemoryLayout<BrushGPUUniforms>.stride, index: 4)
            generator.setBuffer(context.compiled.curves, offset: 0, index: 5)
            generator.setTexture(pickupWindow.colors, index: 0)
            generator.setTexture(pickupWindow.selection, index: 1)
            generator.setTexture(context.compiled.tips, index: 2)
            generator.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            generator.endEncoding()

            let reach = context.compiled.maximumReach + 8
            let points = batch + (previous.map { [$0] } ?? [])
            let bounds = CGRect(x: points.map(\.x).min()! - canvasOffset.x - reach, y: points.map(\.y).min()! - canvasOffset.y - reach,
                                width: points.map(\.x).max()! - points.map(\.x).min()! + reach * 2,
                                height: points.map(\.y).max()! - points.map(\.y).min()! + reach * 2)

            previous = batch.last
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            var affected = (boundary ?? CanvasBoundary(width: width, height: height)).clip(bounds.offsetBy(dx:canvasOffset.x,dy:canvasOffset.y)).offsetBy(dx:-canvasOffset.x,dy:-canvasOffset.y)
            if let selection = context.selection, selection.defaultCoverage == 0 {
                affected = affected.intersection(selection.bounds)
            }
            guard !affected.isNull, !affected.isEmpty else { continue }
            let indices = indexBuffer
            let counts = subtileCountBuffer
            let tileSize = CanvasConstants.tileSize
            let minX = Int(floor(affected.minX / CGFloat(tileSize)))
            let minY = Int(floor(affected.minY / CGFloat(tileSize)))
            let maxX = Int(ceil(affected.maxX / CGFloat(tileSize))) - 1
            let maxY = Int(ceil(affected.maxY / CGFloat(tileSize))) - 1
            for ty in minY...maxY {
                for tx in minX...maxX {
                    let selectionKey = SelectionTileKey(x: tx, y: ty)
                    if let selection = context.selection, selection.tileBounds[selectionKey] == nil,
                       (selection.defaultCoverage == 0 || selection.tiles[selectionKey] != nil) { continue }
                    let key = TileKey(layerID: stroke.layerID, x: tx, y: ty, target: stroke.target)
                    var tile: WorkingTile
                    if let existing = context.working[key] { tile = existing }
                    else {
                        let source = base[key] ?? Self.texture(device,
                            format: stroke.target == .mask ? .r8Unorm : .rgba8Unorm,
                            fill: stroke.target == .mask ? 255 : 0)
                        var initial: [UInt32] = [256, 256, 0, 0]
                        let gpuBounds = device.makeBuffer(bytes: &initial, length: 16, options: .storageModeShared)!
                        tile = WorkingTile(base: source,
                            output: Self.texture(device, format: source.pixelFormat, fill: 0),
                            coverage: Self.texture(device, format: .r16Float, fill: 0),
                            spareCoverage: Self.texture(device, format: .r16Float, fill: 0),
                            paintColor: uniforms.medium.x == 0 ? nil : Self.texture(device, format: .rgba16Float, fill: 0),
                            sparePaintColor: uniforms.medium.x == 0 ? nil : Self.texture(device, format: .rgba16Float, fill: 0),
                            bounds: gpuBounds)
                    }
                    uniforms.tile.x = Float(Double(tx * tileSize)-origin.x); uniforms.tile.y = Float(Double(ty * tileSize)-origin.y)
                    uniforms.images.z = UInt32(truncatingIfNeeded: tx * tileSize)
                    uniforms.images.w = UInt32(truncatingIfNeeded: ty * tileSize)
                    let binner = command.makeComputeCommandEncoder()!
                    binner.setComputePipelineState(bin)
                    binner.setBuffer(dabs, offset: 0, index: 0)
                    binner.setBuffer(count, offset: 0, index: 1)
                    binner.setBuffer(indices, offset: 0, index: 2)
                    binner.setBuffer(counts, offset: 0, index: 3)
                    binner.setBytes(&uniforms, length: MemoryLayout<BrushGPUUniforms>.stride, index: 4)
                    binner.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                    binner.endEncoding()
                    let encoder = command.makeComputeCommandEncoder()!
                    encoder.setComputePipelineState(raster)
                    encoder.setTexture(tile.base, index: 0)
                    encoder.setTexture(tile.coverage, index: 1)
                    encoder.setTexture(tile.spareCoverage, index: 2)
                    encoder.setTexture(tile.output, index: 3)
                    encoder.setTexture(context.compiled.tips, index: 5)
                    encoder.setTexture(tile.paintColor ?? emptyPaintColor, index: 6)
                    encoder.setTexture(tile.sparePaintColor ?? emptyPaintColor, index: 7)
                    encoder.setTexture(context.selection?.tiles[selectionKey] ??
                        (context.selection?.defaultCoverage == 0 ? emptySelection : fullSelection), index: 4)
                    encoder.setBuffer(dabs, offset: 0, index: 0)
                    encoder.setBuffer(indices, offset: 0, index: 1)
                    encoder.setBuffer(counts, offset: 0, index: 2)
                    encoder.setBytes(&uniforms, length: MemoryLayout<BrushGPUUniforms>.stride, index: 3)
                    encoder.setBuffer(tile.bounds, offset: 0, index: 4)
                    encoder.dispatchThreads(MTLSize(width: 256, height: 256, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    encoder.endEncoding()
                    swap(&tile.coverage, &tile.spareCoverage)
                    swap(&tile.paintColor, &tile.sparePaintColor)
                    context.working[key] = tile
                    let rect = CGRect(x: tx * tileSize, y: ty * tileSize, width: tileSize, height: tileSize).intersection(affected)
                    context.dirty[key] = (context.dirty[key] ?? .null).union(rect)
                }
            }
        }
        if onTipRadius != nil {
            // Copy before later GPU submissions mutate state; no synchronous cursor readback.
            let cursor = device.makeBuffer(length: 16, options: .storageModeShared)!
            let copy = command.makeBlitCommandEncoder()!
            copy.copy(from: context.state, sourceOffset: 32, to: cursor, destinationOffset: 0, size: 16)
            copy.endEncoding()
            cursorRevision += 1
            let revision = cursorRevision
            let id = stroke.id
            command.addCompletedHandler { [weak self] completed in
                guard completed.status == .completed else { return }
                let radius = cursor.contents().bindMemory(to: Float.self, capacity: 4)[3]
                Task { @MainActor [weak self] in
                    guard let self, self.transaction?.id == id, revision > self.appliedCursorRevision else { return }
                    self.appliedCursorRevision = revision
                    self.onTipRadius?(id, CGFloat(radius))
                }
            }
        }
        command.commit()
        lastSubmission = command
        return result(context)
    }

    func finish(_ stroke: StrokeCommand, base: [TileKey: MTLTexture], selection: SelectionSnapshot?,
                width: Int, height: Int, boundary: CanvasBoundary? = nil, canvasOffset:CGPoint = .zero) -> Result {
        let output = update(stroke, base: base, selection: selection, width: width, height: height, boundary: boundary, canvasOffset:canvasOffset)
        transaction = nil
        return output
    }

    private func result(_ context: Transaction) -> Result {
        Result(tiles: context.working.mapValues(\.output), dirtyBounds: context.dirty,
               measuredBounds: context.working.mapValues(\.bounds))
    }

    private static func texture(_ device: MTLDevice, format: MTLPixelFormat, fill: UInt8) -> MTLTexture {
        let size = CanvasConstants.tileSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        let channels = format == .rgba16Float ? 8 : format == .rgba8Unorm ? 4 : (format == .r16Float ? 2 : 1)
        let data = Data(repeating: fill, count: size * size * channels)
        data.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * channels) }
        return texture
    }
    enum BrushError: Error { case unavailable }
}
