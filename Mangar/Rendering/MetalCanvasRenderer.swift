import Foundation
import Metal
import MetalKit
import UIKit

private struct GPUDab {
    var center: SIMD2<Float>
    var radius: Float
    var opacity: Float
}

private struct StampUniforms {
    var color: SIMD4<Float>
    var tileOrigin: SIMD2<Float>
    var dabCount: UInt32
    var mode: UInt32
}

private struct QuadUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var viewport: SIMD2<Float>
    var zoom: Float
    var rotation: Float
    var pan: SIMD2<Float>
}

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

private struct SelectionOpUniforms {
    var rect: SIMD4<Float>
    var tileOrigin: SIMD2<Float>
    var operation: UInt32
    var padding: UInt32 = 0
}

private struct SelectionOutlineUniforms {
    var tileOrigin: SIMD2<Float>
    var canvasSize: SIMD2<Float>
    var zoom: Float
    var phase: Float
}

private struct RectOutlineUniforms {
    var rect: SIMD4<Float>
    var zoom: Float
    var phase: Float
}

@MainActor
private final class SelectionDisplayLinkTarget: NSObject {
    weak var renderer: MetalCanvasRenderer?
    init(renderer: MetalCanvasRenderer) { self.renderer = renderer }
    @objc func tick() { renderer?.view?.setNeedsDisplay() }
}

@MainActor
final class MetalCanvasRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stampPipeline: MTLComputePipelineState
    private let nonAccumulatingStampPipeline: MTLComputePipelineState
    private let selectionEditPipeline: MTLComputePipelineState
    private let selectionBoundsPipeline: MTLComputePipelineState
    private let paintBoundsPipeline: MTLComputePipelineState
    private let tilePipeline: MTLRenderPipelineState
    private let paperPipeline: MTLRenderPipelineState
    private let checkerPipeline: MTLRenderPipelineState
    private let selectionOutlinePipeline: MTLRenderPipelineState
    private let selectionRectPipeline: MTLRenderPipelineState
    private let emptyMask: MTLTexture
    private let fullMask: MTLTexture
    private var tiles: [TileKey: MTLTexture] = [:]
    private var previewTiles: [TileKey: MTLTexture] = [:]
    private var previewCoverageTiles: [TileKey: MTLTexture] = [:]
    private var previewDabCount = 0
    private var thumbnailCache: [UUID: UIImage] = [:]
    private var emptyThumbnailLayers: Set<UUID> = []
    private(set) var selection: SelectionSnapshot?
    private var selectionPreviewRect: CGRect?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: SelectionDisplayLinkTarget?
    private(set) var dirtyBounds: [TileKey: CGRect] = [:]
    weak var view: MTKView?
    var page: PageRecord
    var zoom: CGFloat = 1
    var rotation: CGFloat = 0
    var pan: CGPoint = .zero
    private var didFit = false

    init(page: PageRecord) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let shaderURL = Bundle.main.url(forResource: "BrushShaderSource", withExtension: "txt") else {
            throw RendererError.unavailable
        }
        let shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let stamp = library.makeFunction(name: "stampRound"),
              let nonAccumulatingStamp = library.makeFunction(name: "stampRoundNonAccumulating"),
              let selectionEdit = library.makeFunction(name: "editSelection"),
              let selectionBounds = library.makeFunction(name: "selectionTileBounds"),
              let paintBounds = library.makeFunction(name: "paintTileBounds"),
              let vertex = library.makeFunction(name: "tileVertex"),
              let tileFragment = library.makeFunction(name: "tileFragment"),
              let paperFragment = library.makeFunction(name: "paperFragment"),
              let checkerFragment = library.makeFunction(name: "checkerFragment"),
              let selectionOutlineFragment = library.makeFunction(name: "selectionOutlineFragment"),
              let selectionRectFragment = library.makeFunction(name: "selectionRectOutlineFragment") else {
            throw RendererError.unavailable
        }
        self.device = device
        self.queue = queue
        self.stampPipeline = try device.makeComputePipelineState(function: stamp)
        self.nonAccumulatingStampPipeline = try device.makeComputePipelineState(function: nonAccumulatingStamp)
        self.selectionEditPipeline = try device.makeComputePipelineState(function: selectionEdit)
        self.selectionBoundsPipeline = try device.makeComputePipelineState(function: selectionBounds)
        self.paintBoundsPipeline = try device.makeComputePipelineState(function: paintBounds)
        self.emptyMask = Self.makeMaskTile(device: device, fill: 0)
        self.fullMask = Self.makeMaskTile(device: device, fill: 255)

        let tileDescriptor = MTLRenderPipelineDescriptor()
        tileDescriptor.vertexFunction = vertex
        tileDescriptor.fragmentFunction = tileFragment
        tileDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let attachment = tileDescriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.tilePipeline = try device.makeRenderPipelineState(descriptor: tileDescriptor)

        let paperDescriptor = MTLRenderPipelineDescriptor()
        paperDescriptor.vertexFunction = vertex
        paperDescriptor.fragmentFunction = paperFragment
        paperDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.paperPipeline = try device.makeRenderPipelineState(descriptor: paperDescriptor)
        paperDescriptor.fragmentFunction = checkerFragment
        self.checkerPipeline = try device.makeRenderPipelineState(descriptor: paperDescriptor)
        let outlineDescriptor = MTLRenderPipelineDescriptor()
        outlineDescriptor.vertexFunction = vertex
        outlineDescriptor.fragmentFunction = selectionOutlineFragment
        outlineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.selectionOutlinePipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        outlineDescriptor.fragmentFunction = selectionRectFragment
        self.selectionRectPipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        self.page = page
        super.init()
    }

    deinit { displayLink?.invalidate() }

    enum RendererError: LocalizedError {
        case unavailable, exportFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: "Metal 不可用或 shader 文件缺失。"
            case .exportFailed: "无法生成 PNG 图像。"
            }
        }
    }

    func attach(_ view: MTKView) {
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        if displayLink == nil {
            let target = SelectionDisplayLinkTarget(renderer: self)
            let link = CADisplayLink(target: target, selector: #selector(SelectionDisplayLinkTarget.tick))
            link.preferredFramesPerSecond = 20
            link.add(to: .main, forMode: .common)
            displayLinkTarget = target
            displayLink = link
        }
        updateSelectionAnimation()
        fitIfNeeded(viewSize: view.bounds.size)
        view.setNeedsDisplay()
    }

    func fitIfNeeded(viewSize: CGSize) {
        guard !didFit, viewSize.width > 0, viewSize.height > 0 else { return }
        zoom = min(viewSize.width / CGFloat(page.width),
                   viewSize.height / CGFloat(page.height)) * 0.92
        rotation = 0
        pan = CGPoint(x: (viewSize.width - CGFloat(page.width) * zoom) / 2,
                      y: (viewSize.height - CGFloat(page.height) * zoom) / 2)
        didFit = true
        view?.setNeedsDisplay()
    }

    func resetViewport() {
        didFit = false
        if let view { fitIfNeeded(viewSize: view.bounds.size) }
    }

    func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        let dx = viewPoint.x - pan.x
        let dy = viewPoint.y - pan.y
        let c = cos(rotation)
        let s = sin(rotation)
        return CGPoint(x: (dx * c + dy * s) / zoom,
                       y: (-dx * s + dy * c) / zoom)
    }

    func rotatedScaledPoint(_ canvasPoint: CGPoint) -> CGPoint {
        let x = canvasPoint.x * zoom
        let y = canvasPoint.y * zoom
        let c = cos(rotation)
        let s = sin(rotation)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    func isInsideCanvas(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < CGFloat(page.width) && point.y < CGFloat(page.height)
    }

    func clearPreview() {
        previewTiles.removeAll()
        previewCoverageTiles.removeAll()
        previewDabCount = 0
        view?.setNeedsDisplay()
    }

    func preview(_ stroke: StrokeCommand) {
        let allDabs = makeDabs(stroke)
        if allDabs.count < previewDabCount {
            previewTiles.removeAll()
            previewCoverageTiles.removeAll()
            previewDabCount = 0
        }
        guard allDabs.count > previewDabCount else { return }
        var updated = previewTiles
        var coverage = previewCoverageTiles
        stamp(Array(allDabs.dropFirst(previewDabCount)), brush: stroke.brush,
              layerID: stroke.layerID, mode: stroke.tool, into: &updated,
              coverage: &coverage, copyingCommitted: true)
        previewTiles = updated
        previewCoverageTiles = coverage
        previewDabCount = allDabs.count
        view?.setNeedsDisplay()
    }

    func commit(_ stroke: StrokeCommand) {
        thumbnailCache.removeValue(forKey: stroke.layerID)
        emptyThumbnailLayers.remove(stroke.layerID)
        previewTiles.removeAll()
        previewCoverageTiles.removeAll()
        previewDabCount = 0
        var updated = tiles
        var coverage: [TileKey: MTLTexture] = [:]
        stamp(makeDabs(stroke), brush: stroke.brush, layerID: stroke.layerID,
              mode: stroke.tool, into: &updated,
              coverage: &coverage, copyingCommitted: false)
        tiles = updated
        view?.setNeedsDisplay()
    }

    func removeTiles(for layerID: UUID) {
        thumbnailCache.removeValue(forKey: layerID)
        emptyThumbnailLayers.remove(layerID)
        tiles = tiles.filter { $0.key.layerID != layerID }
        previewTiles = previewTiles.filter { $0.key.layerID != layerID }
        previewCoverageTiles = previewCoverageTiles.filter { $0.key.layerID != layerID }
        dirtyBounds = dirtyBounds.filter { $0.key.layerID != layerID }
        view?.setNeedsDisplay()
    }

    func snapshot() -> [TileKey: Data] {
        var result: [TileKey: Data] = [:]
        for (key, texture) in tiles {
            result[key] = bytes(of: texture)
        }
        return result
    }

    func restore(_ snapshot: [TileKey: Data]) {
        thumbnailCache.removeAll()
        emptyThumbnailLayers.removeAll()
        tiles.removeAll()
        previewTiles.removeAll()
        previewCoverageTiles.removeAll()
        previewDabCount = 0
        dirtyBounds.removeAll()
        selection = nil
        selectionPreviewRect = nil
        updateSelectionAnimation()
        for (key, data) in snapshot where data.count == Self.bytesPerTile {
            let texture = newTile()
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                        CanvasConstants.tileSize),
                                mipmapLevel: 0, withBytes: base,
                                bytesPerRow: CanvasConstants.tileSize * 4)
            }
            tiles[key] = texture
        }
        view?.setNeedsDisplay()
    }

    private static var bytesPerTile: Int { CanvasConstants.tileSize * CanvasConstants.tileSize * 4 }

    private func bytes(of texture: MTLTexture) -> Data {
        var data = Data(count: Self.bytesPerTile)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: CanvasConstants.tileSize * 4,
                             from: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                   CanvasConstants.tileSize), mipmapLevel: 0)
        }
        return data
    }

    /// Fits only non-transparent pixels into the preview; the page size is irrelevant.
    func thumbnail(for layerID: UUID) -> UIImage? {
        if let cached = thumbnailCache[layerID] { return cached }
        if emptyThumbnailLayers.contains(layerID) { return nil }
        let layerTiles = tiles.filter { $0.key.layerID == layerID }
        guard !layerTiles.isEmpty, let boundsCommand = queue.makeCommandBuffer() else {
            emptyThumbnailLayers.insert(layerID)
            return nil
        }
        let tileSize = CanvasConstants.tileSize
        let initial = [UInt32(tileSize), UInt32(tileSize), 0, 0]
        var reductions: [(TileKey, MTLBuffer)] = []
        for (key, texture) in layerTiles {
            guard let buffer = device.makeBuffer(bytes: initial,
                                                  length: MemoryLayout<UInt32>.stride * 4),
                  let encoder = boundsCommand.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(paintBoundsPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: tileSize, height: tileSize, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            reductions.append((key, buffer))
        }
        boundsCommand.commit()
        boundsCommand.waitUntilCompleted()
        guard boundsCommand.status == .completed else { return nil }
        var bounds = CGRect.null
        for (key, buffer) in reductions {
            let values = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            guard values[0] < values[2], values[1] < values[3] else { continue }
            bounds = bounds.union(CGRect(x: key.x * tileSize + Int(values[0]),
                                         y: key.y * tileSize + Int(values[1]),
                                         width: Int(values[2] - values[0]),
                                         height: Int(values[3] - values[1])))
        }
        bounds = bounds.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        guard !bounds.isNull, !bounds.isEmpty else {
            emptyThumbnailLayers.insert(layerID)
            return nil
        }
        let size = 48
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(tilePipeline)
        let zoom = Float(min(CGFloat(size - 2) / bounds.width,
                             CGFloat(size - 2) / bounds.height))
        let pan = SIMD2<Float>(Float((CGFloat(size) - bounds.width * CGFloat(zoom)) / 2 - bounds.minX * CGFloat(zoom)),
                               Float((CGFloat(size) - bounds.height * CGFloat(zoom)) / 2 - bounds.minY * CGFloat(zoom)))
        for (key, texture) in layerTiles {
            let x = key.x * tileSize
            let y = key.y * tileSize
            var quad = QuadUniforms(origin: SIMD2<Float>(Float(x), Float(y)),
                                    size: SIMD2<Float>(Float(min(tileSize, page.width - x)),
                                                       Float(min(tileSize, page.height - y))),
                                    viewport: SIMD2<Float>(Float(size), Float(size)),
                                    zoom: zoom, rotation: 0, pan: pan)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var pixels = Data(count: size * size * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: size * 4,
                            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: size, height: size,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        thumbnailCache[layerID] = thumbnail
        return thumbnail
    }

    private func newTile() -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: CanvasConstants.tileSize,
            height: CanvasConstants.tileSize, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        let clear = Data(count: Self.bytesPerTile)
        clear.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                    CanvasConstants.tileSize),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: CanvasConstants.tileSize * 4)
        }
        return texture
    }

    private func newCoverageTile() -> MTLTexture {
        Self.makeMaskTile(device: device, fill: 0)
    }

    private static func makeMaskTile(device: MTLDevice, fill: UInt8) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: CanvasConstants.tileSize,
            height: CanvasConstants.tileSize, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        let bytes = Data(repeating: fill, count: CanvasConstants.tileSize * CanvasConstants.tileSize)
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                    CanvasConstants.tileSize),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: CanvasConstants.tileSize)
        }
        return texture
    }

    func restoreSelection(_ snapshot: SelectionSnapshot?) {
        selection = snapshot
        selectionPreviewRect = nil
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    func previewSelection(from start: CGPoint, to end: CGPoint) {
        let x0 = max(0, min(CGFloat(page.width), min(start.x, end.x)))
        let y0 = max(0, min(CGFloat(page.height), min(start.y, end.y)))
        let x1 = max(0, min(CGFloat(page.width), max(start.x, end.x)))
        let y1 = max(0, min(CGFloat(page.height), max(start.y, end.y)))
        selectionPreviewRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    func clearSelectionPreview() {
        selectionPreviewRect = nil
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    func applySelection(_ command: SelectionCommand) {
        clearSelectionPreview()
        switch command {
        case .clear:
            selection = nil
        case .selectAll:
            selection = SelectionSnapshot(defaultCoverage: 255, tiles: [:], tileBounds: [:],
                                          bounds: CGRect(x: 0, y: 0, width: page.width, height: page.height),
                                          outlineKeys: [])
        case .invert:
            editSelection(rect: nil, mode: nil)
        case .rectangle(let rect, let mode):
            editSelection(rect: CGRect(x: rect.x, y: rect.y,
                                       width: rect.width, height: rect.height), mode: mode)
        }
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    private func updateSelectionAnimation() {
        displayLink?.isPaused = selectionPreviewRect == nil &&
            !(selection.map { $0.defaultCoverage != 0 || !$0.tileBounds.isEmpty } ?? false)
    }

    private func selectionKeys(in rect: CGRect) -> Set<SelectionTileKey> {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
        let size = CGFloat(CanvasConstants.tileSize)
        let minX = Int(floor(clipped.minX / size))
        let minY = Int(floor(clipped.minY / size))
        let maxX = min((page.width - 1) / CanvasConstants.tileSize,
                       Int(ceil(clipped.maxX / size)) - 1)
        let maxY = min((page.height - 1) / CanvasConstants.tileSize,
                       Int(ceil(clipped.maxY / size)) - 1)
        guard minX <= maxX, minY <= maxY else { return [] }
        return Set((minY...maxY).flatMap { y in
            (minX...maxX).map { x in SelectionTileKey(x: x, y: y) }
        })
    }

    private func editSelection(rect: CGRect?, mode requestedMode: SelectionCombineMode?) {
        let old = selection
        let mode: SelectionCombineMode? = old == nil && requestedMode == .intersect
            ? .replace : requestedMode
        let oldDefault: UInt8 = old?.defaultCoverage ?? (mode == .subtract ? 255 : 0)
        let newDefault: UInt8 = mode == nil ? 255 - oldDefault
            : (mode == .replace || mode == .intersect ? 0 : oldDefault)
        let rectKeys = rect.map(selectionKeys(in:)) ?? []
        let keys: Set<SelectionTileKey> = mode == nil ? Set(old?.tiles.keys ?? [:].keys)
            : rectKeys
        var newTiles: [SelectionTileKey: MTLTexture] =
            (mode == .replace || mode == .intersect || mode == nil) ? [:] : (old?.tiles ?? [:])
        var newBounds: [SelectionTileKey: CGRect] =
            (mode == .replace || mode == .intersect || mode == nil) ? [:] : (old?.tileBounds ?? [:])
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        var reductions: [(SelectionTileKey, MTLBuffer)] = []
        let tileSize = CanvasConstants.tileSize
        let operation: UInt32
        switch mode {
        case .replace: operation = 0
        case .add: operation = 1
        case .subtract: operation = 2
        case .intersect: operation = 3
        case nil: operation = 4
        }
        let rectangle = rect ?? .zero
        for key in keys {
            let source = old?.tiles[key] ?? (oldDefault == 0 ? emptyMask : fullMask)
            let output = Self.makeMaskTile(device: device, fill: 0)
            let initial = [UInt32(tileSize), UInt32(tileSize), 0, 0]
            guard let boundsBuffer = device.makeBuffer(bytes: initial,
                length: MemoryLayout<UInt32>.stride * initial.count),
                let edit = commandBuffer.makeComputeCommandEncoder() else { continue }
            var uniforms = SelectionOpUniforms(
                rect: SIMD4<Float>(Float(rectangle.minX), Float(rectangle.minY),
                                   Float(rectangle.maxX), Float(rectangle.maxY)),
                tileOrigin: SIMD2<Float>(Float(key.x * tileSize), Float(key.y * tileSize)),
                operation: operation)
            edit.setComputePipelineState(selectionEditPipeline)
            edit.setTexture(source, index: 0)
            edit.setTexture(output, index: 1)
            edit.setBytes(&uniforms, length: MemoryLayout<SelectionOpUniforms>.stride, index: 0)
            edit.dispatchThreads(MTLSize(width: tileSize, height: tileSize, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            edit.endEncoding()
            if let bounds = commandBuffer.makeComputeCommandEncoder() {
                bounds.setComputePipelineState(selectionBoundsPipeline)
                bounds.setTexture(output, index: 0)
                bounds.setBuffer(boundsBuffer, offset: 0, index: 0)
                bounds.dispatchThreads(MTLSize(width: tileSize, height: tileSize, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                bounds.endEncoding()
                newTiles[key] = output
                reductions.append((key, boundsBuffer))
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return }
        for (key, buffer) in reductions {
            let values = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            if values[0] < values[2], values[1] < values[3] {
                newBounds[key] = CGRect(x: key.x * tileSize + Int(values[0]),
                                        y: key.y * tileSize + Int(values[1]),
                                        width: Int(values[2] - values[0]),
                                        height: Int(values[3] - values[1]))
            } else {
                newBounds.removeValue(forKey: key)
                if newDefault == 0 { newTiles.removeValue(forKey: key) }
            }
        }
        let canvasBounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        let bounds = newDefault == 255 ? canvasBounds
            : newBounds.values.reduce(CGRect.null) { $0.union($1) }
        var outlineKeys: Set<SelectionTileKey> = []
        if newDefault == 0 {
            for key in newBounds.keys {
                outlineKeys.insert(key)
                outlineKeys.insert(SelectionTileKey(x: key.x - 1, y: key.y))
                outlineKeys.insert(SelectionTileKey(x: key.x + 1, y: key.y))
                outlineKeys.insert(SelectionTileKey(x: key.x, y: key.y - 1))
                outlineKeys.insert(SelectionTileKey(x: key.x, y: key.y + 1))
            }
        }
        selection = SelectionSnapshot(defaultCoverage: newDefault, tiles: newTiles,
                                      tileBounds: newBounds, bounds: bounds,
                                      outlineKeys: outlineKeys)
    }

    private func stamp(_ dabs: [GPUDab], brush: RoundBrush, layerID: UUID, mode: DrawingTool,
                       into destination: inout [TileKey: MTLTexture],
                       coverage: inout [TileKey: MTLTexture],
                       copyingCommitted: Bool) {
        guard !dabs.isEmpty, let commandBuffer = queue.makeCommandBuffer() else { return }
        let size = CanvasConstants.tileSize
        let radius = dabs.map(\.radius).max() ?? 0
        var minX = max(0, Int(floor(Double(dabs.map(\.center.x).min()! - radius) / Double(size))))
        var minY = max(0, Int(floor(Double(dabs.map(\.center.y).min()! - radius) / Double(size))))
        var maxX = min((page.width - 1) / size,
                       Int(floor(Double(dabs.map(\.center.x).max()! + radius) / Double(size))))
        var maxY = min((page.height - 1) / size,
                       Int(floor(Double(dabs.map(\.center.y).max()! + radius) / Double(size))))
        if let selection, selection.defaultCoverage == 0 {
            guard !selection.bounds.isNull else { return }
            minX = max(minX, Int(floor(selection.bounds.minX / CGFloat(size))))
            minY = max(minY, Int(floor(selection.bounds.minY / CGFloat(size))))
            maxX = min(maxX, Int(ceil(selection.bounds.maxX / CGFloat(size))) - 1)
            maxY = min(maxY, Int(ceil(selection.bounds.maxY / CGFloat(size))) - 1)
        }
        guard minX <= maxX, minY <= maxY else { return }
        for ty in minY...maxY {
            for tx in minX...maxX {
                let key = TileKey(layerID: layerID, x: tx, y: ty)
                let maskKey = SelectionTileKey(x: tx, y: ty)
                if let selection, selection.tileBounds[maskKey] == nil,
                   (selection.defaultCoverage == 0 || selection.tiles[maskKey] != nil) {
                    continue
                }
                let mask = selection?.tiles[maskKey] ??
                    (selection?.defaultCoverage == 0 ? emptyMask : fullMask)
                let origin = SIMD2<Float>(Float(tx * size), Float(ty * size))
                let localDabs = dabs.filter {
                    $0.center.x + $0.radius >= origin.x &&
                    $0.center.y + $0.radius >= origin.y &&
                    $0.center.x - $0.radius < origin.x + Float(size) &&
                    $0.center.y - $0.radius < origin.y + Float(size)
                }
                guard !localDabs.isEmpty else { continue }
                guard let dabBuffer = device.makeBuffer(bytes: localDabs,
                                                        length: localDabs.count * MemoryLayout<GPUDab>.stride) else {
                    continue
                }
                let source = brush.buildsOpacity
                    ? (destination[key] ?? (copyingCommitted ? tiles[key] : nil) ?? newTile())
                    : (tiles[key] ?? newTile())
                let output = newTile()
                var uniforms = StampUniforms(
                    color: SIMD4<Float>(Float(brush.red), Float(brush.green),
                                        Float(brush.blue), 1),
                    tileOrigin: origin, dabCount: UInt32(localDabs.count),
                    mode: mode == .eraser ? 1 : 0)
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
                if brush.buildsOpacity {
                    encoder.setComputePipelineState(stampPipeline)
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(output, index: 1)
                    encoder.setTexture(mask, index: 2)
                } else {
                    let previousCoverage = coverage[key] ?? newCoverageTile()
                    let nextCoverage = newCoverageTile()
                    encoder.setComputePipelineState(nonAccumulatingStampPipeline)
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(previousCoverage, index: 1)
                    encoder.setTexture(output, index: 2)
                    encoder.setTexture(nextCoverage, index: 3)
                    encoder.setTexture(mask, index: 4)
                    coverage[key] = nextCoverage
                }
                encoder.setBuffer(dabBuffer, offset: 0, index: 0)
                encoder.setBytes(&uniforms, length: MemoryLayout<StampUniforms>.stride, index: 1)
                encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
                destination[key] = output
                if !copyingCommitted {
                    let tileRect = CGRect(x: tx * size, y: ty * size, width: size, height: size)
                    let strokeRect = CGRect(x: CGFloat(dabs.map(\.center.x).min()! - radius),
                                            y: CGFloat(dabs.map(\.center.y).min()! - radius),
                                            width: CGFloat(dabs.map(\.center.x).max()! - dabs.map(\.center.x).min()! + radius * 2),
                                            height: CGFloat(dabs.map(\.center.y).max()! - dabs.map(\.center.y).min()! + radius * 2))
                    var changed = tileRect.intersection(strokeRect)
                    if let selection, selection.defaultCoverage == 0,
                       let selectedBounds = selection.tileBounds[maskKey] {
                        changed = changed.intersection(selectedBounds)
                    }
                    if !changed.isNull {
                        dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(changed)
                    }
                }
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func makeDabs(_ stroke: StrokeCommand) -> [GPUDab] {
        guard let first = stroke.samples.first else { return [] }
        var state = stroke.seed == 0 ? 1 : stroke.seed
        func random() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state & 0x00ff_ffff) / Float(0x0100_0000)
        }
        func dab(_ point: StrokeSample) -> GPUDab {
            let brush = stroke.brush
            let sizeFactor = 1 + (Double(random()) * 2 - 1) * brush.sizeJitter
            let opacityFactor = 1 + (Double(random()) * 2 - 1) * brush.opacityJitter
            let jitterX = (Double(random()) * 2 - 1) * brush.positionJitter * brush.size
            let jitterY = (Double(random()) * 2 - 1) * brush.positionJitter * brush.size
            return GPUDab(center: SIMD2<Float>(Float(point.x + jitterX), Float(point.y + jitterY)),
                          radius: Float(max(0.5, brush.size * max(0.05, point.pressure) * sizeFactor / 2)),
                          opacity: Float(min(1, max(0, brush.opacity * opacityFactor))))
        }
        var result = [dab(first)]
        var distanceSinceDab = 0.0
        var previous = first
        for current in stroke.samples.dropFirst() {
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let length = hypot(dx, dy)
            if length > 0 {
                // Use the smaller pressure-adjusted diameter across this input segment.
                // A shrinking tip can otherwise leave visible gaps before the next sample.
                let segmentDiameter = max(1, stroke.brush.size *
                    max(0.05, min(previous.pressure, current.pressure)))
                var along = 0.0
                while along < length {
                    let lastDiameter = Double(result.last!.radius) * 2
                    let step = max(0.5, stroke.brush.spacing * min(lastDiameter, segmentDiameter))
                    let advance = max(0, step - distanceSinceDab)
                    if along + advance > length {
                        distanceSinceDab += length - along
                        break
                    }
                    along += advance
                    let t = along / length
                    result.append(dab(StrokeSample(x: previous.x + dx * t,
                                                   y: previous.y + dy * t,
                                                   pressure: previous.pressure + (current.pressure - previous.pressure) * t)))
                    distanceSinceDab = 0
                }
            }
            previous = current
        }
        return result
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        fitIfNeeded(viewSize: view.bounds.size)
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        render(pass: pass, commandBuffer: commandBuffer,
               viewport: view.drawableSize,
               zoom: Float(zoom * view.contentScaleFactor),
               rotation: Float(rotation), includeChecker: true,
               pan: SIMD2<Float>(Float(pan.x * view.contentScaleFactor),
                                 Float(pan.y * view.contentScaleFactor)))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func render(pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer,
                        viewport: CGSize, zoom: Float, rotation: Float,
                        includeChecker: Bool, pan: SIMD2<Float>) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vp = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
        var paper = QuadUniforms(origin: .zero,
                                 size: SIMD2<Float>(Float(page.width), Float(page.height)),
                                 viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
        if includeChecker {
            encoder.setRenderPipelineState(checkerPipeline)
            encoder.setVertexBytes(&paper, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        for layer in page.layers where page.isEffectivelyVisible(layer.id) {
            if layer.kind == .solidWhite {
                encoder.setRenderPipelineState(paperPipeline)
                encoder.setVertexBytes(&paper, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                continue
            }
            guard layer.kind == .paint else { continue }
            encoder.setRenderPipelineState(tilePipeline)
            let keys = Set(tiles.keys.filter { $0.layerID == layer.id })
                .union(previewTiles.keys.filter { $0.layerID == layer.id })
            for key in keys {
                guard let texture = previewTiles[key] ?? tiles[key] else { continue }
                let origin = SIMD2<Float>(Float(key.x * CanvasConstants.tileSize),
                                          Float(key.y * CanvasConstants.tileSize))
                var quad = QuadUniforms(origin: origin,
                                        size: SIMD2<Float>(Float(min(CanvasConstants.tileSize, page.width - key.x * CanvasConstants.tileSize)),
                                                           Float(min(CanvasConstants.tileSize, page.height - key.y * CanvasConstants.tileSize))),
                                        viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        if includeChecker {
            drawSelectionOutline(encoder: encoder, viewport: vp, zoom: zoom,
                                 rotation: rotation, pan: pan)
        }
        encoder.endEncoding()
    }

    private func drawSelectionOutline(encoder: MTLRenderCommandEncoder,
                                      viewport: SIMD2<Float>, zoom: Float,
                                      rotation: Float, pan: SIMD2<Float>) {
        let phase = Float(CACurrentMediaTime() * 3).truncatingRemainder(dividingBy: 2)
        if let selection {
            let size = CanvasConstants.tileSize
            let c = cos(rotation)
            let s = sin(rotation)
            let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(viewport.x, 0),
                           SIMD2<Float>(0, viewport.y), viewport]
            let canvasCorners = corners.map { point -> SIMD2<Float> in
                let delta = point - pan
                return SIMD2<Float>((delta.x * c + delta.y * s) / zoom,
                                    (-delta.x * s + delta.y * c) / zoom)
            }
            let minX = max(0, Int(floor((canvasCorners.map(\.x).min()! - 2) / Float(size))))
            let minY = max(0, Int(floor((canvasCorners.map(\.y).min()! - 2) / Float(size))))
            let maxX = min((page.width - 1) / size,
                           Int(floor((canvasCorners.map(\.x).max()! + 2) / Float(size))))
            let maxY = min((page.height - 1) / size,
                           Int(floor((canvasCorners.map(\.y).max()! + 2) / Float(size))))
            if minX <= maxX, minY <= maxY {
                let fallback = selection.defaultCoverage == 0 ? emptyMask : fullMask
                encoder.setRenderPipelineState(selectionOutlinePipeline)
                for y in minY...maxY {
                    for x in minX...maxX {
                        let key = SelectionTileKey(x: x, y: y)
                        if selection.defaultCoverage == 0 &&
                           !selection.outlineKeys.contains(key) { continue }
                        let origin = SIMD2<Float>(Float(x * size), Float(y * size))
                        var quad = QuadUniforms(origin: origin,
                            size: SIMD2<Float>(Float(min(size, page.width - x * size)),
                                               Float(min(size, page.height - y * size))),
                            viewport: viewport, zoom: zoom, rotation: rotation, pan: pan)
                        var uniforms = SelectionOutlineUniforms(
                            tileOrigin: origin,
                            canvasSize: SIMD2<Float>(Float(page.width), Float(page.height)),
                            zoom: zoom, phase: phase)
                        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                        encoder.setFragmentBytes(&uniforms,
                            length: MemoryLayout<SelectionOutlineUniforms>.stride, index: 0)
                        encoder.setFragmentTexture(selection.tiles[key] ?? fallback, index: 0)
                        encoder.setFragmentTexture(selection.tiles[SelectionTileKey(x: x - 1, y: y)] ?? fallback, index: 1)
                        encoder.setFragmentTexture(selection.tiles[SelectionTileKey(x: x + 1, y: y)] ?? fallback, index: 2)
                        encoder.setFragmentTexture(selection.tiles[SelectionTileKey(x: x, y: y - 1)] ?? fallback, index: 3)
                        encoder.setFragmentTexture(selection.tiles[SelectionTileKey(x: x, y: y + 1)] ?? fallback, index: 4)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    }
                }
            }
        }
        if let rect = selectionPreviewRect, rect.width >= 0.5, rect.height >= 0.5 {
            let x0 = Float(floor(rect.minX + 0.5))
            let y0 = Float(floor(rect.minY + 0.5))
            let x1 = Float(floor(rect.maxX + 0.5))
            let y1 = Float(floor(rect.maxY + 0.5))
            guard x1 > x0, y1 > y0 else { return }
            var quad = QuadUniforms(origin: SIMD2<Float>(x0 - 1, y0 - 1),
                                    size: SIMD2<Float>(x1 - x0 + 2, y1 - y0 + 2),
                                    viewport: viewport, zoom: zoom, rotation: rotation, pan: pan)
            var uniforms = RectOutlineUniforms(rect: SIMD4<Float>(x0, y0, x1, y1),
                                               zoom: zoom, phase: phase)
            encoder.setRenderPipelineState(selectionRectPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms,
                length: MemoryLayout<RectOutlineUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    func sampleColor(at point: CGPoint) -> SIMD3<Float>? {
        guard isInsideCanvas(point) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        render(pass: pass, commandBuffer: commandBuffer,
               viewport: CGSize(width: 1, height: 1), zoom: 1, rotation: 0,
               includeChecker: false,
               pan: SIMD2<Float>(-Float(floor(point.x)), -Float(floor(point.y))))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: 4,
                            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        guard pixel[3] > 0 else { return nil }
        let alpha = Float(pixel[3]) / 255
        return SIMD3<Float>(min(1, Float(pixel[2]) / 255 / alpha),
                            min(1, Float(pixel[1]) / 255 / alpha),
                            min(1, Float(pixel[0]) / 255 / alpha))
    }

    func exportPNG() throws -> Data {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: page.width, height: page.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { throw RendererError.exportFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        render(pass: pass, commandBuffer: commandBuffer,
               viewport: CGSize(width: page.width, height: page.height),
               zoom: 1, rotation: 0, includeChecker: false, pan: .zero)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let rowBytes = page.width * 4
        var pixels = Data(count: rowBytes * page.height)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, page.width, page.height), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        guard let image = CGImage(width: page.width, height: page.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let png = UIImage(cgImage: image).pngData() else {
            throw RendererError.exportFailed
        }
        return png
    }
}
