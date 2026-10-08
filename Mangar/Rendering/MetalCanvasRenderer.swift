import Foundation
import Metal
import MetalKit
import UIKit

private struct QuadUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var viewport: SIMD2<Float>
    var zoom: Float
    var rotation: Float
    var pan: SIMD2<Float>
}

private struct LayerCompositeUniforms {
    var opacity: Float
    var mode: UInt32
    var solid: UInt32 = 0
    var padding: UInt32 = 0
    var tone: SIMD4<Float> = .zero
    var canvasMap: SIMD4<Float> = .zero
    var solidColor: SIMD4<Float> = SIMD4<Float>(repeating: 1)
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

private struct GuideUniforms {
    var rect: SIMD4<Float>
    var zoomAndPadding: SIMD4<Float>
    var color: SIMD4<Float>
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
    private let maskFillPipeline: MTLComputePipelineState
    private let maskViewPipeline: MTLRenderPipelineState
    private var maskViewTargets: [Int: MTLTexture] = [:]
    private var maskThumbnailCache: [UUID: UIImage] = [:]
    private let brushChanges = BrushChangeTracker()
    private let brushEngine: MetalBrushEngine
    private let polygonRasterizer: PolygonMaskRasterizer
    private let clearLayerPipeline: MTLComputePipelineState
    private let lassoFillPipeline: MTLComputePipelineState
    private let lassoLinePipeline: MTLRenderPipelineState
    private let selectionEditPipeline: MTLComputePipelineState
    private let selectionBoundsPipeline: MTLComputePipelineState
    private let paintBoundsPipeline: MTLComputePipelineState
    private let usesRasterOrderGroups: Bool
    private var groupBackdrops: [Int: MTLTexture] = [:]
    private let layerCompositePipeline: MTLRenderPipelineState
    private var groupTargets: [Int: MTLTexture] = [:]
    private let tilePipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let checkerPipeline: MTLRenderPipelineState
    private let selectionOutlinePipeline: MTLRenderPipelineState
    private let selectionRectPipeline: MTLRenderPipelineState
    private let pageGuidePipeline: MTLRenderPipelineState
    private let emptyMask: MTLTexture
    private let fullMask: MTLTexture
    private var tiles: [TileKey: MTLTexture] = [:]
    private var previewTiles: [TileKey: MTLTexture] = [:]
    private var previewStrokeID: UUID?
    private(set) var previewTipRadius: CGFloat?
    private var thumbnailCache: [UUID: UIImage] = [:]
    private var emptyThumbnailLayers: Set<UUID> = []
    private(set) var selection: SelectionSnapshot?
    private var lassoPreviewBuffer: MTLBuffer?
    private var lassoPreviewPoints: [SIMD2<Float>] = []
    private var selectionPreviewRect: CGRect?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: SelectionDisplayLinkTarget?
    private(set) var dirtyBounds: [TileKey: CGRect] = [:]
    weak var view: MTKView?
    var viewportTintLayerID: UUID?
    var viewportTintTarget: LayerEditTarget = .content
    var page: PageRecord
    var zoom: CGFloat = 1
    var rotation: CGFloat = 0
    var pan: CGPoint = .zero
    private var didFit = false
    private var viewportVisible = true

    init(page: PageRecord) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let shaderURL = Bundle.main.url(forResource: "BrushShaderSource", withExtension: "txt") else {
            throw RendererError.unavailable
        }
        let usesRasterOrderGroups = device.areRasterOrderGroupsSupported
        var shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
        if !usesRasterOrderGroups {
            shaderSource = shaderSource.replacingOccurrences(of: ", raster_order_group(0)", with: "")
        }
        guard let brushURL = Bundle.main.url(forResource: "BrushKernels", withExtension: "txt") else {
            throw RendererError.unavailable
        }
        shaderSource += "\n" + (try String(contentsOf: brushURL, encoding: .utf8))
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let clearLayer = library.makeFunction(name: "clearLayer"),
              let maskFill = library.makeFunction(name: "fillLassoLayerMask"),
              let maskView = library.makeFunction(name: "maskValueFragment"),
              let lassoFill = library.makeFunction(name: "fillLasso"),
              let lassoLineVertex = library.makeFunction(name: "lassoLineVertex"),
              let lassoLineFragment = library.makeFunction(name: "lassoLineFragment"),
              let selectionEdit = library.makeFunction(name: "editSelection"),
              let selectionBounds = library.makeFunction(name: "selectionTileBounds"),
              let paintBounds = library.makeFunction(name: "paintTileBounds"),
              let vertex = library.makeFunction(name: "tileVertex"),
              let tileFragment = library.makeFunction(name: "tileFragment"),
              let layerCompositeFragment = library.makeFunction(name: usesRasterOrderGroups
                ? "layerCompositeFragment" : "layerCompositeFallbackFragment"),
              let shapeFragment = library.makeFunction(name: "shapeFragment"),
              let checkerFragment = library.makeFunction(name: "checkerFragment"),
              let selectionOutlineFragment = library.makeFunction(name: "selectionOutlineFragment"),
              let selectionRectFragment = library.makeFunction(name: "selectionRectOutlineFragment"),
              let pageGuideFragment = library.makeFunction(name: "pageGuideFragment") else {
            throw RendererError.unavailable
        }
        self.device = device
        self.usesRasterOrderGroups = usesRasterOrderGroups
        self.queue = queue
        self.clearLayerPipeline = try device.makeComputePipelineState(function: clearLayer)
        self.maskFillPipeline = try device.makeComputePipelineState(function: maskFill)
        let maskDescriptor = MTLRenderPipelineDescriptor()
        maskDescriptor.vertexFunction = vertex
        maskDescriptor.fragmentFunction = maskView
        maskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        self.maskViewPipeline = try device.makeRenderPipelineState(descriptor: maskDescriptor)
        self.brushEngine = try MetalBrushEngine(device: device, queue: queue, library: library)
        self.polygonRasterizer = try PolygonMaskRasterizer(device: device, queue: queue, library: library)
        self.lassoFillPipeline = try device.makeComputePipelineState(function: lassoFill)
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

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.vertexFunction = vertex
        compositeDescriptor.fragmentFunction = layerCompositeFragment
        compositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.layerCompositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)

        let shapeDescriptor = MTLRenderPipelineDescriptor()
        shapeDescriptor.vertexFunction = vertex
        shapeDescriptor.fragmentFunction = shapeFragment
        shapeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let shapeAttachment = shapeDescriptor.colorAttachments[0]!
        shapeAttachment.isBlendingEnabled = true
        shapeAttachment.sourceRGBBlendFactor = .one
        shapeAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        shapeAttachment.sourceAlphaBlendFactor = .one
        shapeAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.shapePipeline = try device.makeRenderPipelineState(descriptor: shapeDescriptor)
        shapeDescriptor.fragmentFunction = checkerFragment
        self.checkerPipeline = try device.makeRenderPipelineState(descriptor: shapeDescriptor)
        let outlineDescriptor = MTLRenderPipelineDescriptor()
        outlineDescriptor.vertexFunction = vertex
        outlineDescriptor.fragmentFunction = selectionOutlineFragment
        outlineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.selectionOutlinePipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        outlineDescriptor.fragmentFunction = selectionRectFragment
        self.selectionRectPipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        outlineDescriptor.fragmentFunction = pageGuideFragment
        self.pageGuidePipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        let lineDescriptor = MTLRenderPipelineDescriptor()
        lineDescriptor.vertexFunction = lassoLineVertex
        lineDescriptor.fragmentFunction = lassoLineFragment
        lineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.lassoLinePipeline = try device.makeRenderPipelineState(descriptor: lineDescriptor)
        self.page = page
        super.init()
        brushEngine.onTipRadius = { [weak self] id, radius in
            guard let self, self.previewStrokeID == id else { return }
            self.previewTipRadius = radius
            (self.view as? CanvasSurface)?.refreshBrushCursor()
        }
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

    /// Remove rotation around the visible viewport's center, preserving its canvas anchor and zoom.
    func straightenViewport() {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let anchor = canvasPoint(from: center)
        rotation = 0
        let mapped = rotatedScaledPoint(anchor)
        pan = CGPoint(x: center.x - mapped.x, y: center.y - mapped.y)
        (view as? CanvasSurface)?.refreshBrushCursor()
        view.setNeedsDisplay()
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
        brushEngine.cancel()
        previewStrokeID = nil
        previewTipRadius = nil
        previewTiles.removeAll()
        view?.setNeedsDisplay()
    }

    func preview(_ stroke: StrokeCommand) {
        let result = brushEngine.update(stroke, base: tiles, selection: selection, width: page.width, height: page.height)
        previewTiles = result.tiles
        if previewStrokeID != stroke.id, let last = stroke.samples.last {
            previewTipRadius = CGFloat(stroke.brush.radius(pressure: last.pressure, altitude: last.altitude))
        }
        previewStrokeID = stroke.id
        view?.setNeedsDisplay()
    }

    func commit(_ stroke: StrokeCommand) {
        let result = brushEngine.finish(stroke, base: tiles, selection: selection, width: page.width, height: page.height)
        brushChanges.record(result, tiles: tiles, dirty: dirtyBounds)
        for (key, texture) in result.tiles { tiles[key] = texture }
        for (key, bounds) in result.dirtyBounds {
            dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(bounds)
        }
        previewStrokeID = nil
        previewTipRadius = nil
        previewTiles.removeAll()
        maskThumbnailCache.removeValue(forKey: stroke.layerID)
        thumbnailCache.removeValue(forKey: stroke.layerID)
        emptyThumbnailLayers.remove(stroke.layerID)
        view?.setNeedsDisplay()
    }

    func removeTiles(for layerID: UUID) {
        brushChanges.invalidate(layerID: layerID)
        maskThumbnailCache.removeValue(forKey: layerID)
        thumbnailCache.removeValue(forKey: layerID)
        emptyThumbnailLayers.remove(layerID)
        tiles = tiles.filter { $0.key.layerID != layerID }
        previewTiles = previewTiles.filter { $0.key.layerID != layerID }
        dirtyBounds = dirtyBounds.filter { $0.key.layerID != layerID }
        view?.setNeedsDisplay()
    }

    func removeTiles(for layerID: UUID, target: LayerEditTarget) {
        brushChanges.invalidate(layerID: layerID)
        thumbnailCache.removeValue(forKey: layerID)
        emptyThumbnailLayers.remove(layerID)
        maskThumbnailCache.removeValue(forKey: layerID)
        tiles = tiles.filter { $0.key.layerID != layerID || $0.key.target != target }
        previewTiles = previewTiles.filter { $0.key.layerID != layerID || $0.key.target != target }
        dirtyBounds = dirtyBounds.filter { $0.key.layerID != layerID || $0.key.target != target }
        view?.setNeedsDisplay()
    }

    func snapshot() -> [TileKey: Data] {
        prepareForReadback()
        var result: [TileKey: Data] = [:]
        for (key, texture) in tiles {
            result[key] = bytes(of: texture)
        }
        return result
    }

    var tileKeys: Set<TileKey> { Set(tiles.keys) }
    var dirtyTileKeys: Set<TileKey> { Set(dirtyBounds.keys) }

    func snapshot(keys: Set<TileKey>) -> [TileKey: Data] {
        prepareForReadback()
        var result: [TileKey: Data] = [:]
        for key in keys {
            if let texture = tiles[key] { result[key] = bytes(of: texture) }
        }
        return result
    }

    func prepareForReadback() {
        brushEngine.synchronize()
        brushChanges.resolve(tiles: &tiles, dirty: &dirtyBounds)
    }

    func clearSavedDirtyTiles() { dirtyBounds.removeAll(); brushChanges.invalidate() }

    func markAllTilesDirty() {
        brushChanges.invalidate()
        for key in tiles.keys { dirtyBounds[key] = .infinite }
    }

    func restore(_ snapshot: [TileKey: Data]) {
        brushEngine.cancel()
        brushChanges.invalidate()
        previewStrokeID = nil
        previewTipRadius = nil
        thumbnailCache.removeAll()
        maskThumbnailCache.removeAll()
        emptyThumbnailLayers.removeAll()
        tiles.removeAll()
        previewTiles.removeAll()
        dirtyBounds.removeAll()
        selection = nil
        selectionPreviewRect = nil
        lassoPreviewPoints = []
        lassoPreviewBuffer = nil
        updateSelectionAnimation()
        for (key, data) in snapshot where data.count == key.rawSize {
            let texture = newTile(target: key.target)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                        CanvasConstants.tileSize),
                                mipmapLevel: 0, withBytes: base,
                                bytesPerRow: CanvasConstants.tileSize * key.target.bytesPerPixel)
            }
            tiles[key] = texture
        }
        view?.setNeedsDisplay()
    }

    private static var bytesPerTile: Int { CanvasConstants.tileSize * CanvasConstants.tileSize * 4 }

    private func bytes(of texture: MTLTexture) -> Data {
        let channels = texture.pixelFormat == .r8Unorm ? 1 : 4
        var data = Data(count: CanvasConstants.tileSize * CanvasConstants.tileSize * channels)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: CanvasConstants.tileSize * channels,
                             from: MTLRegionMake2D(0, 0, CanvasConstants.tileSize,
                                                   CanvasConstants.tileSize), mipmapLevel: 0)
        }
        return data
    }

    /// Fits only non-transparent pixels into the preview; the page size is irrelevant.
    func thumbnail(for layerID: UUID) -> UIImage? {
        if let cached = thumbnailCache[layerID] { return cached }
        if emptyThumbnailLayers.contains(layerID) { return nil }
        let layerTiles = tiles.filter { $0.key.layerID == layerID && $0.key.target == .content }
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

    private func newTile(target: LayerEditTarget = .content) -> MTLTexture {
        if target == .mask { return Self.makeMaskTile(device: device, fill: 255) }
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
        lassoPreviewPoints = []
        lassoPreviewBuffer = nil
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

    func previewLasso(_ points: [SelectionPoint]) {
        selectionPreviewRect = nil
        lassoPreviewPoints = points.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        if lassoPreviewPoints.count >= 3 { lassoPreviewPoints.append(lassoPreviewPoints[0]) }
        lassoPreviewBuffer = lassoPreviewPoints.isEmpty ? nil : device.makeBuffer(bytes: lassoPreviewPoints,
            length: lassoPreviewPoints.count * MemoryLayout<SIMD2<Float>>.stride)
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    func clearSelectionPreview() {
        selectionPreviewRect = nil
        lassoPreviewPoints = []
        lassoPreviewBuffer = nil
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
        case .lasso(let points, let mode):
            let masks = polygonMasks(points)
            editSelection(rect: nil, mode: mode, masks: masks)
        case .rectangle(let rect, let mode):
            editSelection(rect: CGRect(x: rect.x, y: rect.y,
                                       width: rect.width, height: rect.height), mode: mode)
        }
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    private func updateSelectionAnimation() {
        displayLink?.isPaused = !viewportVisible || (selectionPreviewRect == nil && lassoPreviewPoints.isEmpty &&
            !(selection.map { $0.defaultCoverage != 0 || !$0.tileBounds.isEmpty } ?? false)
        )
    }

    func setViewportVisible(_ visible: Bool) {
        viewportVisible = visible
        updateSelectionAnimation()
        if visible { view?.setNeedsDisplay() }
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

    private func editSelection(rect: CGRect?, mode requestedMode: SelectionCombineMode?,
                               masks: [SelectionTileKey: MTLTexture]? = nil) {
        let old = selection
        let mode: SelectionCombineMode? = old == nil && requestedMode == .intersect
            ? .replace : requestedMode
        let oldDefault: UInt8 = old?.defaultCoverage ?? (mode == .subtract ? 255 : 0)
        let newDefault: UInt8 = mode == nil ? 255 - oldDefault
            : (mode == .replace || mode == .intersect ? 0 : oldDefault)
        let rectKeys = masks.map { Set($0.keys) } ?? rect.map(selectionKeys(in:)) ?? []
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
                operation: operation, padding: masks == nil ? 0 : 1)
            edit.setComputePipelineState(selectionEditPipeline)
            edit.setTexture(source, index: 0)
            edit.setTexture(output, index: 1)
            edit.setTexture(masks?[key] ?? emptyMask, index: 2)
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

    private func polygonMasks(_ points: [SelectionPoint]) -> [SelectionTileKey: MTLTexture] {
        polygonRasterizer.rasterize(points.map { SIMD2<Float>(Float($0.x), Float($0.y)) },
            canvasSize: CGSize(width: page.width, height: page.height), tileSize: CanvasConstants.tileSize)
    }

    func commitClear(_ clear: ClearLayerCommand) {
        brushChanges.invalidate(layerID: clear.layerID)
        // Missing content tiles are transparent; missing mask tiles are white.
        // Clearing the whole target can therefore release its sparse allocation.
        guard let selection else {
            removeTiles(for: clear.layerID, target: clear.target)
            return
        }
        guard let command = queue.makeCommandBuffer() else { return }
        let size = CanvasConstants.tileSize
        var pending: [(TileKey, MTLTexture, MTLBuffer)] = []
        for (key, source) in tiles where key.layerID == clear.layerID && key.target == clear.target {
            let selectionKey = SelectionTileKey(x: key.x, y: key.y)
            if selection.tileBounds[selectionKey] == nil &&
                (selection.defaultCoverage == 0 || selection.tiles[selectionKey] != nil) { continue }
            let selected = selection.tiles[selectionKey] ?? (selection.defaultCoverage == 0 ? emptyMask : fullMask)
            let initial = [UInt32(size), UInt32(size), 0, 0]
            guard let bounds = device.makeBuffer(bytes: initial, length: 16),
                  let encoder = command.makeComputeCommandEncoder() else { continue }
            let output = newTile(target: clear.target)
            var isMask: UInt32 = clear.target == .mask ? 1 : 0
            encoder.setComputePipelineState(clearLayerPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(selected, index: 1)
            encoder.setTexture(output, index: 2)
            encoder.setBytes(&isMask, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.setBuffer(bounds, offset: 0, index: 1)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            pending.append((key, output, bounds))
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return }
        for (key, output, buffer) in pending {
            let bounds = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            guard bounds[0] < bounds[2], bounds[1] < bounds[3] else { continue }
            tiles[key] = output
            let changed = CGRect(x: key.x * size + Int(bounds[0]), y: key.y * size + Int(bounds[1]),
                width: Int(bounds[2] - bounds[0]), height: Int(bounds[3] - bounds[1]))
            dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(changed)
        }
        thumbnailCache.removeValue(forKey: clear.layerID)
        emptyThumbnailLayers.remove(clear.layerID)
        maskThumbnailCache.removeValue(forKey: clear.layerID)
        view?.setNeedsDisplay()
    }

    func commitLassoFill(_ fill: LassoFillCommand) {
        brushChanges.invalidate(layerID: fill.layerID)
        let masks = polygonMasks(fill.points)
        guard !masks.isEmpty, let command = queue.makeCommandBuffer() else { return }
        let size = CanvasConstants.tileSize
        var pending: [(TileKey, MTLTexture, MTLBuffer)] = []
        for (maskKey, shape) in masks {
            if let selection, selection.tileBounds[maskKey] == nil,
               (selection.defaultCoverage == 0 || selection.tiles[maskKey] != nil) { continue }
            let key = TileKey(layerID: fill.layerID, x: maskKey.x, y: maskKey.y, target: fill.target)
            let selected = selection?.tiles[maskKey] ?? (selection?.defaultCoverage == 0 ? emptyMask : fullMask)
            let initial = [UInt32(size), UInt32(size), 0, 0]
            guard let bounds = device.makeBuffer(bytes: initial, length: 16),
                  let encoder = command.makeComputeCommandEncoder() else { continue }
            let output = newTile(target: fill.target)
            var color = SIMD4<Float>(Float(fill.brush.red), Float(fill.brush.green),
                                     Float(fill.brush.blue), Float(fill.brush.opacity))
            encoder.setComputePipelineState(fill.target == .mask ? maskFillPipeline : lassoFillPipeline)
            encoder.setTexture(tiles[key] ?? newTile(target: fill.target), index: 0)
            encoder.setTexture(shape, index: 1)
            encoder.setTexture(selected, index: 2)
            encoder.setTexture(output, index: 3)
            encoder.setBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setBuffer(bounds, offset: 0, index: 1)
            var erases: UInt32 = fill.erases ? 1 : 0
            encoder.setBytes(&erases, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            pending.append((key, output, bounds))
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return }
        for (key, output, buffer) in pending {
            let values = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            guard values[0] < values[2], values[1] < values[3] else { continue }
            tiles[key] = output
            let changed = CGRect(x: key.x * size + Int(values[0]), y: key.y * size + Int(values[1]),
                                 width: Int(values[2] - values[0]), height: Int(values[3] - values[1]))
            dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(changed)
        }
        maskThumbnailCache.removeValue(forKey: fill.layerID)
        thumbnailCache.removeValue(forKey: fill.layerID)
        emptyThumbnailLayers.remove(fill.layerID)
        view?.setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        fitIfNeeded(viewSize: view.bounds.size)
    }

    func draw(in view: MTKView) {
        guard viewportVisible else { return }
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
        let tintID = includeChecker ? viewportTintLayerID : nil
        let needsCompositing = tintID != nil || page.layers.contains { $0.hasMask || $0.opacity != 1 || $0.blendMode != .normal || $0.tone?.isEnabled == true }
        let composite = needsCompositing ? composeGroup(parentID: nil, depth: 0,
            commandBuffer: commandBuffer, viewport: viewport, zoom: zoom,
            rotation: rotation, pan: pan, tintLayerID: tintID, tintTarget: viewportTintTarget) : nil
        guard !needsCompositing || composite != nil,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vp = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
        var paper = QuadUniforms(origin: .zero,
                                 size: SIMD2<Float>(Float(page.width), Float(page.height)),
                                 viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
        if includeChecker {
            encoder.setRenderPipelineState(checkerPipeline)
            encoder.setVertexBytes(&paper, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        if let composite {
            encoder.setRenderPipelineState(tilePipeline)
            var screen = QuadUniforms(origin: .zero, size: vp, viewport: vp,
                                      zoom: 1, rotation: 0, pan: .zero)
            encoder.setVertexBytes(&screen, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(composite, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } else {
        for layer in page.layers where page.isEffectivelyVisible(layer.id) {
            if layer.kind == .shape {
                guard let shape = layer.shape, !shape.bounds.isEmpty else { continue }
                let bounds = shape.bounds
                var background = paper
                background.origin = SIMD2<Float>(Float(bounds.minX), Float(bounds.minY))
                background.size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
                encoder.setRenderPipelineState(shapePipeline)
                var color = shape.fill.premultiplied
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setVertexBytes(&background, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                continue
            }
            guard layer.kind == .paint else { continue }
            encoder.setRenderPipelineState(tilePipeline)
            let keys = Set(tiles.keys.filter { $0.layerID == layer.id && $0.target == .content })
                .union(previewTiles.keys.filter { $0.layerID == layer.id && $0.target == .content })
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
        }
        if includeChecker {
            drawPageGuides(encoder: encoder, viewport: vp, zoom: zoom,
                           rotation: rotation, pan: pan)
            drawSelectionOutline(encoder: encoder, viewport: vp, zoom: zoom,
                                 rotation: rotation, pan: pan)
        }
        encoder.endEncoding()
    }

    /// Isolate folder contents before applying folder opacity/blend. Scratch textures
    /// are retained by nesting depth; paint remains in its original sparse GPU tiles.
    private func composeGroup(parentID: UUID?, depth: Int, commandBuffer: MTLCommandBuffer,
                              viewport: CGSize, zoom: Float, rotation: Float,
                              pan: SIMD2<Float>, tintLayerID: UUID? = nil,
                              tintTarget: LayerEditTarget = .content) -> MTLTexture? {
        let width = max(1, Int(viewport.width)), height = max(1, Int(viewport.height))
        let target: MTLTexture
        if let cached = groupTargets[depth], cached.width == width, cached.height == height {
            target = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            groupTargets[depth] = texture
            target = texture
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let vp = SIMD2<Float>(Float(width), Float(height))
        var encoder: MTLRenderCommandEncoder?
        var currentBackdrop: MTLTexture?
        func startEncoder() -> MTLRenderCommandEncoder? {
            let result = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            result?.setRenderPipelineState(layerCompositePipeline)
            result?.setFragmentTexture(fullMask, index: 2)
            if let currentBackdrop { result?.setFragmentTexture(currentBackdrop, index: 1) }
            // Later segments must retain layers rendered before an isolated child.
            pass.colorAttachments[0].loadAction = .load
            return result
        }
        func prepareBackdrop() -> Bool {
            guard !usesRasterOrderGroups else { return true }
            encoder?.endEncoding()
            if let cached = groupBackdrops[depth], cached.width == width, cached.height == height {
                currentBackdrop = cached
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = .shaderRead
                guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
                groupBackdrops[depth] = texture
                currentBackdrop = texture
            }
            guard let currentBackdrop, let copy = commandBuffer.makeBlitCommandEncoder() else { return false }
            copy.copy(from: target, to: currentBackdrop)
            copy.endEncoding()
            encoder = startEncoder()
            return encoder != nil
        }
        encoder = startEncoder()
        guard encoder != nil else { return nil }
        for layer in page.layers where tintLayerID.map({ layer.id == $0 }) ??
            (layer.parentID == parentID && layer.isVisible && layer.opacity > 0) {
            let tinted = layer.id == tintLayerID
            let maskPreview = tinted && tintTarget == .mask && layer.hasMask
            let applyMask = layer.hasMask && (!tinted || maskPreview)
            var layerMask: MTLTexture?
            if applyMask {
                encoder?.endEncoding()
                layerMask = renderLayerMask(layerID: layer.id, depth: depth, command: commandBuffer,
                    viewport: viewport, zoom: zoom, rotation: rotation, pan: pan)
                guard layerMask != nil else { return nil }
                encoder = startEncoder()
            }
            guard prepareBackdrop() else { return nil }
            encoder?.setFragmentTexture(layerMask ?? fullMask, index: 2)
            var uniforms = LayerCompositeUniforms(opacity: tinted ? 1 : Float(layer.opacity),
                mode: tinted ? 0 : layer.blendMode.shaderIndex)
            // Bit 0 applies a mask; bit 1 displays raw alpha as blue.
            uniforms.padding = (applyMask ? 1 : 0) | (tinted ? 2 : 0)
            if let tone = layer.tone, tone.isEnabled && !tinted {
                let dpi = Float(page.comicLayout?.dpi ?? 350)
                uniforms.tone = SIMD4<Float>(dpi / Float(max(1, tone.frequency)),
                    Float(tone.angle * .pi / 180), Float(tone.density), 1)
                uniforms.canvasMap = SIMD4<Float>(cos(rotation) / max(zoom, 0.000001),
                    sin(rotation) / max(zoom, 0.000001), pan.x, pan.y)
            }
            if maskPreview {
                guard let encoder else { return nil }
                var quad = QuadUniforms(origin: .zero,
                    size: SIMD2<Float>(Float(page.width), Float(page.height)), viewport: vp,
                    zoom: zoom, rotation: rotation, pan: pan)
                uniforms.solid = 1
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                encoder.setFragmentTexture(emptyMask, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            } else if layer.kind == .folder {
                encoder?.endEncoding()
                guard let child = composeGroup(parentID: layer.id, depth: depth + 1,
                    commandBuffer: commandBuffer, viewport: viewport, zoom: zoom,
                    rotation: rotation, pan: pan) else { return nil }
                encoder = startEncoder()
                guard let encoder else { return nil }
                encoder.setFragmentTexture(layerMask ?? fullMask, index: 2)
                var screen = QuadUniforms(origin: .zero, size: vp, viewport: vp,
                                          zoom: 1, rotation: 0, pan: .zero)
                encoder.setVertexBytes(&screen, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                encoder.setFragmentTexture(child, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            } else if layer.kind == .shape {
                guard let shape = layer.shape, !shape.bounds.isEmpty else { continue }
                guard let encoder else { return nil }
                let rect = shape.bounds
                uniforms.solidColor = shape.fill.premultiplied
                var quad = QuadUniforms(origin: SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
                    size: SIMD2<Float>(Float(rect.width), Float(rect.height)), viewport: vp,
                    zoom: zoom, rotation: rotation, pan: pan)
                uniforms.solid = 1
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                // A valid texture is required even though the solid branch does not sample it.
                encoder.setFragmentTexture(emptyMask, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            } else {
                guard let encoder else { return nil }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                let keys = Set(tiles.keys.filter { $0.layerID == layer.id && $0.target == .content })
                    .union(previewTiles.keys.filter { $0.layerID == layer.id && $0.target == .content })
                let tileSize = CanvasConstants.tileSize
                for key in keys {
                    guard let texture = previewTiles[key] ?? tiles[key] else { continue }
                    var quad = QuadUniforms(origin: SIMD2<Float>(Float(key.x * tileSize), Float(key.y * tileSize)),
                        size: SIMD2<Float>(Float(min(tileSize, page.width - key.x * tileSize)),
                                           Float(min(tileSize, page.height - key.y * tileSize))), viewport: vp,
                        zoom: zoom, rotation: rotation, pan: pan)
                    encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }
        }
        encoder?.endEncoding()
        return target
    }

    /// Render only allocated mask tiles over an implicit white viewport.
    private func renderLayerMask(layerID: UUID, depth: Int, command: MTLCommandBuffer,
                                 viewport: CGSize, zoom: Float, rotation: Float, pan: SIMD2<Float>,
                                 includePreview: Bool = true, shared: Bool = false) -> MTLTexture? {
        let width = max(1, Int(viewport.width)), height = max(1, Int(viewport.height))
        let target: MTLTexture
        if let cached = maskViewTargets[depth], cached.width == width, cached.height == height {
            target = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = shared ? .shared : .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let created = device.makeTexture(descriptor: descriptor) else { return nil }
            maskViewTargets[depth] = created
            target = created
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(maskViewPipeline)
        let keys = Set(tiles.keys.filter { $0.layerID == layerID && $0.target == .mask })
            .union(includePreview ? previewTiles.keys.filter { $0.layerID == layerID && $0.target == .mask } : [])
        let size = CanvasConstants.tileSize
        for key in keys {
            guard let tile = (includePreview ? previewTiles[key] : nil) ?? tiles[key] else { continue }
            var quad = QuadUniforms(origin: SIMD2<Float>(Float(key.x * size), Float(key.y * size)),
                size: SIMD2<Float>(Float(size), Float(size)), viewport: SIMD2<Float>(Float(width), Float(height)),
                zoom: zoom, rotation: rotation, pan: pan)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(tile, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        return target
    }

    func maskThumbnail(for layerID: UUID) -> UIImage? {
        if let cached = maskThumbnailCache[layerID] { return cached }
        let scale = min(48.0 / Double(page.width), 48.0 / Double(page.height))
        let width = max(1, Int((Double(page.width) * scale).rounded()))
        let height = max(1, Int((Double(page.height) * scale).rounded()))
        guard let command = queue.makeCommandBuffer(),
              let texture = renderLayerMask(layerID: layerID, depth: -1, command: command,
                viewport: CGSize(width: width, height: height), zoom: Float(scale), rotation: 0,
                pan: .zero, includePreview: false, shared: true) else { return nil }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let result = UIImage(cgImage: image)
        maskThumbnailCache[layerID] = result
        return result
    }

    private func drawPageGuides(encoder: MTLRenderCommandEncoder,
                                viewport: SIMD2<Float>, zoom: Float,
                                rotation: Float, pan: SIMD2<Float>) {
        var frames: [(CGRect, SIMD4<Float>)] = []
        if let layout = page.comicLayout {
            frames.append((layout.bleedRect, SIMD4<Float>(0.2, 0.72, 0.83, 1)))
            frames.append((layout.contentRect, SIMD4<Float>(0.18, 0.48, 0.95, 1)))
        }
        if page.isDoublePage {
            frames.append((CGRect(x: page.contentRect.midX, y: 0, width: 0, height: CGFloat(page.height)),
                           SIMD4<Float>(0.18, 0.48, 0.95, 1)))
        }
        guard !frames.isEmpty else { return }
        encoder.setRenderPipelineState(pageGuidePipeline)
        let padding = CGFloat(max(1, 1 / max(zoom, 0.001)))
        for (rect, color) in frames {
            var quad = QuadUniforms(origin: SIMD2<Float>(Float(rect.minX - padding), Float(rect.minY - padding)),
                                    size: SIMD2<Float>(Float(rect.width + 2 * padding), Float(rect.height + 2 * padding)),
                                    viewport: viewport, zoom: zoom, rotation: rotation, pan: pan)
            var uniforms = GuideUniforms(rect: SIMD4<Float>(Float(rect.minX), Float(rect.minY),
                                                             Float(rect.maxX), Float(rect.maxY)),
                                         zoomAndPadding: SIMD4<Float>(zoom, 0, 0, 0), color: color)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GuideUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
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
        if lassoPreviewPoints.count >= 2, let points = lassoPreviewBuffer {
            var quad = QuadUniforms(origin: .zero, size: .zero, viewport: viewport,
                                   zoom: zoom, rotation: rotation, pan: pan)
            var linePhase = phase
            encoder.setRenderPipelineState(lassoLinePipeline)
            encoder.setVertexBuffer(points, offset: 0, index: 0)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&linePhase, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: (lassoPreviewPoints.count - 1) * 6)
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

    func exportPNG(cropToContent: Bool) throws -> Data {
        let bounds = cropToContent ? page.contentRect : CGRect(x: 0, y: 0,
                                                                width: page.width, height: page.height)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
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
               viewport: CGSize(width: width, height: height),
               zoom: 1, rotation: 0, includeChecker: false,
               pan: SIMD2<Float>(-Float(bounds.minX), -Float(bounds.minY)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        guard let image = CGImage(width: width, height: height,
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

    func projectThumbnailPNG() throws -> Data {
        let scale = min(320.0 / Double(page.width), 320.0 / Double(page.height), 1)
        let width = max(1, Int((Double(page.width) * scale).rounded()))
        let height = max(1, Int((Double(page.height) * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { throw RendererError.exportFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        render(pass: pass, commandBuffer: commandBuffer,
               viewport: CGSize(width: width, height: height), zoom: Float(scale),
               rotation: 0, includeChecker: false, pan: .zero)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        guard let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent),
              let png = UIImage(cgImage: image).pngData() else { throw RendererError.exportFailed }
        return png
    }
}
