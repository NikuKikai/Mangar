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
    var clip: SIMD4<Float> = SIMD4(-.infinity, -.infinity, .infinity, .infinity)
}

private struct LayerCompositeUniforms {
    var opacity: Float
    var mode: UInt32
    var solid: UInt32 = 0
    var padding: UInt32 = 0
    var tone: SIMD4<Float> = .zero
    var canvasMap: SIMD4<Float> = .zero
    var solidColor: SIMD4<Float> = SIMD4<Float>(repeating: 1)
    var tonePhase: SIMD2<Float> = .zero
    var reserved: SIMD2<Float> = .zero
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
    var bounds: SIMD4<Float> = SIMD4(0,0,256,256)
    var viewport: SIMD2<Float> = SIMD2(256,256)
    var constant: UInt32 = 0
    var padding: UInt32 = 0
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
    private var tileIndex: CanvasTileIndex?
    private var archive = CanvasTileArchive()
    private var residencyClock: UInt64 = 0
    private var lastUsed: [TileKey: UInt64] = [:]
    private let residentBudget = 128 * 1024 * 1024
    private var storageFailure: Error?
    var onStorageError: ((Error) -> Void)?
    func checkStorageIntegrity() throws { if let storageFailure { throw storageFailure } }
    private func reportStorageError(_ error: Error) { storageFailure = error; onStorageError?(error) }
    private var renderOrigin = SIMD2<Double>.zero
    private var renderBounds = CGRect.zero
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let maskFillPipeline: MTLComputePipelineState
    private let maskViewPipeline: MTLRenderPipelineState
    private var maskViewTargets: [Int: MTLTexture] = [:]
    private var maskThumbnailCache: [UUID: UIImage] = [:]
    private let brushChanges = BrushChangeTracker()
    private let tileContents: TileContentTracker
    private(set) var tileContentBounds: [TileKey: CGRect] = [:]
    private var tileLOD: CanvasTileLOD!
    private let brushEngine: MetalBrushEngine
    private let polygonRasterizer: PolygonMaskRasterizer
    private let clearLayerPipeline: MTLComputePipelineState
    private let lassoFillPipeline: MTLComputePipelineState
    private let lassoLinePipeline: MTLRenderPipelineState
    private let selectionEditPipeline: MTLComputePipelineState
    private let selectionBoundsPipeline: MTLComputePipelineState
    private let selectionDeviationPipeline: MTLComputePipelineState
    private let usesRasterOrderGroups: Bool
    private var groupBackdrops: [Int: MTLTexture] = [:]
    private var curveTextures: [UUID: (LayerCurveEffect, MTLTexture)] = [:]
    private let layerCompositePipeline: MTLRenderPipelineState
    private var groupTargets: [Int: MTLTexture] = [:]
    private let tilePipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let checkerPipeline: MTLRenderPipelineState
    private let selectionTintPipeline: MTLRenderPipelineState
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
    private var lassoPreviewPoints: [SelectionPoint] = []
    private var selectionMaskTarget: MTLTexture?
    private var selectionPreviewRect: CGRect?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: SelectionDisplayLinkTarget?
    private(set) var dirtyBounds: [TileKey: CGRect] = [:]
    weak var view: MTKView?
    var showsSelectionTint = false {
        didSet {
            if showsSelectionTint != oldValue { updateSelectionAnimation(); view?.setNeedsDisplay() }
        }
    }
    var viewportTintLayerID: UUID?
    var viewportTintTarget: LayerEditTarget = .content
    var page: PageRecord
    private var displayPixelScale: CGFloat { max(view?.contentScaleFactor ?? 1,1) }
    var minimumViewportZoom: CGFloat { CanvasViewportGeometry.minimumDisplayZoom/displayPixelScale }
    var viewportZoomPercentage: Double { Double(zoom*displayPixelScale*100) }
    var onViewportChanged: (() -> Void)?
    var onContentChanged: (() -> Void)?
    private var viewportNotificationPending = false
    private var previousViewport: CanvasViewportGeometry?
    var viewportGeometry: CanvasViewportGeometry {
        CanvasViewportGeometry(size:view?.bounds.size ?? .zero,zoom:zoom,rotation:rotation,pan:pan)
    }
    private func scheduleViewportNotification() {
        guard !viewportNotificationPending else { return }
        viewportNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportNotificationPending = false
            let geometry = self.viewportGeometry
            if geometry != self.previousViewport { self.previousViewport = geometry; self.onViewportChanged?() }
        }
    }
    var zoom: CGFloat = 1 {
        didSet {
            let clamped = CanvasViewportGeometry.clampedViewportZoom(zoom,displayScale:displayPixelScale)
            if zoom != clamped { zoom = clamped }
            scheduleViewportNotification()
        }
    }
    var rotation: CGFloat = 0 { didSet { scheduleViewportNotification() } }
    var pan: CGPoint = .zero { didSet { scheduleViewportNotification() } }
    private var didFit = false
    private var viewportVisible = true
    var isViewportVisible: Bool { viewportVisible }

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
        guard let pigmentURL = Bundle.main.url(forResource: "PigmentMixing", withExtension: "txt"),
              let brushURL = Bundle.main.url(forResource: "BrushKernels", withExtension: "txt") else {
            throw RendererError.unavailable
        }
        shaderSource += "\n" + (try String(contentsOf: pigmentURL, encoding: .utf8))
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
              let selectionDeviation = library.makeFunction(name: "selectionTileDeviationBounds"),
              let vertex = library.makeFunction(name: "tileVertex"),
              let tileFragment = library.makeFunction(name: "tileFragment"),
              let layerCompositeFragment = library.makeFunction(name: usesRasterOrderGroups
                ? "layerCompositeFragment" : "layerCompositeFallbackFragment"),
              let shapeFragment = library.makeFunction(name: "shapeFragment"),
              let checkerFragment = library.makeFunction(name: "checkerFragment"),
              let selectionOutlineFragment = library.makeFunction(name: "selectionOutlineFragment"),
              let selectionTintFragment = library.makeFunction(name: "selectionTintFragment"),
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
        self.tileContents = try TileContentTracker(device: device, queue: queue, library: library)
        self.brushEngine = try MetalBrushEngine(device: device, queue: queue, library: library)
        self.polygonRasterizer = try PolygonMaskRasterizer(device: device, queue: queue, library: library)
        self.lassoFillPipeline = try device.makeComputePipelineState(function: lassoFill)
        self.selectionEditPipeline = try device.makeComputePipelineState(function: selectionEdit)
        self.selectionBoundsPipeline = try device.makeComputePipelineState(function: selectionBounds)
        self.selectionDeviationPipeline = try device.makeComputePipelineState(function: selectionDeviation)
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
        outlineDescriptor.fragmentFunction = selectionTintFragment
        let tintAttachment = outlineDescriptor.colorAttachments[0]!
        tintAttachment.isBlendingEnabled = true
        tintAttachment.sourceRGBBlendFactor = .one
        tintAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        tintAttachment.sourceAlphaBlendFactor = .one
        tintAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.selectionTintPipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        tintAttachment.isBlendingEnabled = false
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
        tileLOD = try CanvasTileLOD(device:device,queue:queue,library:library,transparent:newTile(),white:fullMask)
        tileContents.onReady = { [weak self] in self?.resolveTileContentBounds() }
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
            case .unavailable: L10n.text("Metal 不可用或 shader 文件缺失。")
            case .exportFailed: L10n.text("无法生成 PNG 图像。")
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
        let fit = page.boundary.finiteRect.flatMap { $0.width <= 16384 && $0.height <= 16384 ? $0 : nil } ?? page.boundary.initialRect
        zoom = min(viewSize.width / fit.width, viewSize.height / fit.height) * 0.92
        rotation = 0
        pan = CGPoint(x: (viewSize.width - fit.width * zoom) / 2 - fit.minX * zoom,
                      y: (viewSize.height - fit.height * zoom) / 2 - fit.minY * zoom)
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
        page.boundary.contains(point)
    }

    func clearPreview() {
        brushEngine.cancel()
        previewStrokeID = nil
        previewTipRadius = nil
        previewTiles.removeAll()
        view?.setNeedsDisplay()
    }

    func preview(_ stroke: StrokeCommand) {
        loadStrokeTiles(stroke)
        let result = brushEngine.update(stroke, base: tiles, selection: selection, width: page.width, height: page.height, boundary: page.boundary)
        previewTiles = result.tiles
        if previewStrokeID != stroke.id, let last = stroke.samples.last {
            previewTipRadius = CGFloat(stroke.brush.radius(pressure: last.pressure, altitude: last.altitude))
        }
        previewStrokeID = stroke.id
        view?.setNeedsDisplay()
    }

    func commit(_ stroke: StrokeCommand) {
        tileIndex = nil
        tileLOD?.invalidate()
        loadStrokeTiles(stroke)
        let result = brushEngine.finish(stroke, base: tiles, selection: selection, width: page.width, height: page.height, boundary: page.boundary)
        brushChanges.record(result, tiles: tiles, dirty: dirtyBounds)
        for (key, texture) in result.tiles { tiles[key] = texture; archive.remove(key) }
        tileIndex = nil
        tileContents.record(result.tiles, width: page.width, height: page.height, boundary: page.boundary)
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
        tileIndex = nil
        tileLOD?.invalidate()
        for key in archive.files.keys.filter({ $0.layerID == layerID }) { archive.remove(key) }
        brushChanges.invalidate(layerID: layerID)
        tileContents.invalidate(layerID: layerID)
        tileContentBounds = tileContentBounds.filter { $0.key.layerID != layerID }
        maskThumbnailCache.removeValue(forKey: layerID)
        thumbnailCache.removeValue(forKey: layerID)
        emptyThumbnailLayers.remove(layerID)
        tiles = tiles.filter { $0.key.layerID != layerID }
        previewTiles = previewTiles.filter { $0.key.layerID != layerID }
        dirtyBounds = dirtyBounds.filter { $0.key.layerID != layerID }
        view?.setNeedsDisplay()
    }

    func removeTiles(for layerID: UUID, target: LayerEditTarget) {
        tileIndex = nil
        tileLOD?.invalidate()
        for key in archive.files.keys.filter({ $0.layerID == layerID && $0.target == target }) { archive.remove(key) }
        brushChanges.invalidate(layerID: layerID)
        tileContents.invalidate(layerID: layerID, target: target)
        tileContentBounds = tileContentBounds.filter { $0.key.layerID != layerID || $0.key.target != target }
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
        for key in archive.files.keys { do { result[key] = try archive.read(key) } catch { reportStorageError(error) } }
        for (key, texture) in tiles {
            result[key] = bytes(of: texture)
        }
        return result
    }

    var tileKeys: Set<TileKey> { logicalIndex.keys }
    private var logicalIndex: CanvasTileIndex {
        if let tileIndex { return tileIndex }
        let index = CanvasTileIndex(Set(tiles.keys).union(archive.files.keys))
        tileIndex = index; return index
    }
    var dirtyTileKeys: Set<TileKey> { Set(dirtyBounds.keys) }

    func snapshot(keys: Set<TileKey>) -> [TileKey: Data] {
        prepareForReadback()
        var result: [TileKey: Data] = [:]
        for key in keys {
            if let texture = tiles[key] { result[key] = bytes(of: texture) }
            else { do { result[key] = try archive.read(key) } catch { reportStorageError(error) } }
        }
        return result
    }

    func prepareForReadback() {
        brushEngine.synchronize()
        brushChanges.resolve(tiles: &tiles, dirty: &dirtyBounds)
        tileContents.synchronize()
        resolveTileContentBounds()
    }

    private func resolveTileContentBounds() {
        let previousKeys = Set(tiles.keys)
        let layers = tileContents.resolve(tiles: &tiles, bounds: &tileContentBounds, dirty: &dirtyBounds)
        for key in previousKeys.subtracting(tiles.keys) { archive.remove(key) }
        if !layers.isEmpty { tileLOD.invalidate(); tileIndex = nil }
        for id in layers {
            thumbnailCache.removeValue(forKey: id)
            maskThumbnailCache.removeValue(forKey: id)
            emptyThumbnailLayers.remove(id)
        }
        if !layers.isEmpty { onContentChanged?(); view?.setNeedsDisplay() }
    }

    func clearSavedDirtyTiles() { dirtyBounds.removeAll(); brushChanges.invalidate() }

    func markAllTilesDirty() {
        brushChanges.invalidate()
        for key in tileKeys { dirtyBounds[key] = .infinite }
    }

    func restore(_ snapshot: [TileKey: Data]) {
        tileIndex = nil
        tileLOD?.invalidate()
        archive = CanvasTileArchive(); lastUsed.removeAll(); storageFailure = nil
        brushEngine.cancel()
        brushChanges.invalidate()
        tileContents.invalidate()
        tileContentBounds.removeAll()
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
        tileContents.record(tiles, width: page.width, height: page.height, boundary: page.boundary)
        view?.setNeedsDisplay()
    }

    func restore(_ source: CanvasTileArchive) throws {
        let copy = try source.clone()
        restore([:])
        archive = copy; tileIndex = nil
        tileContentBounds = source.bounds
        view?.setNeedsDisplay()
    }

    func checkpointArchive() throws -> CanvasTileArchive {
        prepareForReadback()
        try checkStorageIntegrity()
        let result = try archive.clone()
        for (key,texture) in tiles { try result.put(bytes(of:texture),for:key) }
        result.bounds = tileContentBounds
        return result
    }

    private func ensureResident(_ keys: Set<TileKey>) {
        residencyClock &+= 1
        for key in keys {
            lastUsed[key] = residencyClock
            guard tiles[key] == nil else { continue }
            do {
                guard let data = try archive.read(key) else { continue }
                let texture = newTile(target:key.target)
                data.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256*key.target.bytesPerPixel) }
                tiles[key] = texture
                tileContents.record([key:texture],width:page.width,height:page.height,boundary:page.boundary)
            } catch { reportStorageError(error) }
        }
    }

    private func loadStrokeTiles(_ stroke: StrokeCommand) {
        guard !archive.files.isEmpty, let last = stroke.samples.last else { return }
        let reach = stroke.definition.maximumReach(stroke.brush) + 256
        // Live input normally adds a short segment. Replay may contain the entire command.
        let points = previewStrokeID == stroke.id ? Array(stroke.samples.suffix(2)) : stroke.samples
        let rect = CGRect(x:points.map(\.x).min() ?? last.x,y:points.map(\.y).min() ?? last.y,width:(points.map(\.x).max() ?? last.x)-(points.map(\.x).min() ?? last.x),height:(points.map(\.y).max() ?? last.y)-(points.map(\.y).min() ?? last.y)).insetBy(dx:-reach,dy:-reach)
        ensureResident(Set(logicalIndex.query(rect).filter { $0.layerID == stroke.layerID && $0.target == stroke.target }))
    }

    private func trimResidentTiles() {
        guard previewStrokeID == nil, tiles.reduce(0, { $0 + $1.key.rawSize }) > residentBudget else { return }
        prepareForReadback()
        var total = tiles.reduce(0) { $0 + $1.key.rawSize }
        let candidates = tiles.keys.sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
        for key in candidates where total > residentBudget {
            guard let texture = tiles[key], !CGRect(x:key.x*256,y:key.y*256,width:256,height:256).intersects(renderBounds) else { continue }
            do {
                try archive.put(bytes(of:texture),for:key)
                archive.bounds[key] = tileContentBounds[key]
                tiles.removeValue(forKey:key); total -= key.rawSize
            } catch { reportStorageError(error); break }
        }
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
        prepareForReadback()
        var bounds = tileContentBounds.filter { $0.key.layerID == layerID && $0.key.target == .content }
            .values.reduce(CGRect.null) { $0.union($1) }
        bounds = page.boundary.clip(bounds)
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
        let pan = SIMD2<Float>(Float((CGFloat(size) - bounds.width * CGFloat(zoom)) / 2),
                               Float((CGFloat(size) - bounds.height * CGFloat(zoom)) / 2))
        for (rect,texture) in displayTiles(layerID:layerID,zoom:zoom,bounds:bounds) {
            var quad = QuadUniforms(origin:SIMD2(Float(rect.minX-bounds.minX),Float(rect.minY-bounds.minY)),size:SIMD2(Float(rect.width),Float(rect.height)),viewport:SIMD2(Float(size),Float(size)),zoom:zoom,rotation:0,pan:pan,clip:page.boundary.gpuClip(relativeTo:SIMD2(bounds.minX,bounds.minY)))
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
        let x0 = min(start.x, end.x)
        let y0 = min(start.y, end.y)
        let x1 = max(start.x, end.x)
        let y1 = max(start.y, end.y)
        selectionPreviewRect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        updateSelectionAnimation()
        view?.setNeedsDisplay()
    }

    func previewLasso(_ points: [SelectionPoint]) {
        selectionPreviewRect = nil
        lassoPreviewPoints = points
        if lassoPreviewPoints.count >= 3 { lassoPreviewPoints.append(lassoPreviewPoints[0]) }
        lassoPreviewBuffer = nil
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
                                          bounds: (page.boundary.finiteRect ?? .infinite),
                                          outlineKeys: [])
        case .invert:
            selection = (selection ?? SelectionSnapshot(defaultCoverage: 0, tiles: [:], tileBounds: [:], bounds: .null, outlineKeys: [])).inverted()
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
            !(!showsSelectionTint && (selection.map { $0.defaultCoverage != 0 || !$0.tileBounds.isEmpty } ?? false))
        )
    }

    func setViewportVisible(_ visible: Bool) {
        viewportVisible = visible
        updateSelectionAnimation()
        if visible { view?.setNeedsDisplay() }
    }

    private func selectionKeys(in rect: CGRect) -> Set<SelectionTileKey> {
        let clipped = page.boundary.clip(rect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
        let size = CGFloat(CanvasConstants.tileSize)
        let minX = Int(floor(clipped.minX / size))
        let minY = Int(floor(clipped.minY / size))
        let maxX = Int(ceil(clipped.maxX / size)) - 1
        let maxY = Int(ceil(clipped.maxY / size)) - 1
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
        var reductions: [(SelectionTileKey, MTLBuffer, MTLBuffer, MTLBuffer)] = []
        var fullKeys = (mode == .replace || mode == .intersect) ? Set<SelectionTileKey>() : (old?.fullKeys ?? [])
        var zeroKeys = (mode == .replace || mode == .intersect) ? Set<SelectionTileKey>() : (old?.zeroKeys ?? [])
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
            let tileRect = CGRect(x:key.x*tileSize,y:key.y*tileSize,width:tileSize,height:tileSize)
            if masks == nil, let rect, rect.contains(tileRect), mode != nil {
                if mode == .replace || mode == .add || mode == .subtract {
                    let full = mode != .subtract
                    newTiles.removeValue(forKey:key); newBounds.removeValue(forKey:key)
                    fullKeys.remove(key); zeroKeys.remove(key)
                    if full && newDefault == 0 { fullKeys.insert(key); newBounds[key] = tileRect }
                    if !full && newDefault == 255 { zeroKeys.insert(key) }
                    continue
                }
                if mode == .intersect {
                    if let source = old?.tiles[key] { newTiles[key] = source }
                    else if oldDefault == 255 { fullKeys.insert(key); newBounds[key] = tileRect }
                    if let bounds = old?.tileBounds[key] { newBounds[key] = bounds }
                    if old?.fullKeys.contains(key) == true { fullKeys.insert(key) }
                    continue
                }
            }
            let source = old?.tiles[key] ?? (oldDefault == 0 ? emptyMask : fullMask)
            let output = Self.makeMaskTile(device: device, fill: 0)
            let initial = [UInt32(tileSize), UInt32(tileSize), 0, 0]
            guard let boundsBuffer = device.makeBuffer(bytes: initial,
                length: MemoryLayout<UInt32>.stride * initial.count),
                  let deviationBuffer = device.makeBuffer(bytes: initial, length: 16),
                  let notFullBuffer = device.makeBuffer(bytes: initial, length: 16),
                let edit = commandBuffer.makeComputeCommandEncoder() else { continue }
            var uniforms = SelectionOpUniforms(
                rect: SIMD4<Float>(Float(rectangle.minX-Double(key.x * tileSize)), Float(rectangle.minY-Double(key.y * tileSize)),
                                   Float(rectangle.maxX-Double(key.x * tileSize)), Float(rectangle.maxY-Double(key.y * tileSize))),
                tileOrigin: .zero,
                operation: operation, padding: (masks == nil ? 0 : 1) | (oldDefault == 255 ? 2 : 0))
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
                if let deviations = commandBuffer.makeComputeCommandEncoder() {
                    var defaultCoverage = UInt32(newDefault)
                    deviations.setComputePipelineState(selectionDeviationPipeline)
                    deviations.setTexture(output, index: 0)
                    deviations.setBuffer(deviationBuffer, offset: 0, index: 0)
                    deviations.setBytes(&defaultCoverage, length: 4, index: 1)
                    deviations.dispatchThreads(MTLSize(width: tileSize, height: tileSize, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    deviations.endEncoding()
                    newTiles[key] = output
                    reductions.append((key, boundsBuffer, deviationBuffer, notFullBuffer))
                    if let notFull = commandBuffer.makeComputeCommandEncoder() {
                        var white: UInt32 = 255
                        notFull.setComputePipelineState(selectionDeviationPipeline)
                        notFull.setTexture(output, index: 0); notFull.setBuffer(notFullBuffer, offset: 0, index: 0)
                        notFull.setBytes(&white, length: 4, index: 1)
                        notFull.dispatchThreads(MTLSize(width: tileSize, height: tileSize, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        notFull.endEncoding()
                    }
                }
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return }
        for (key, buffer, deviationBuffer, notFullBuffer) in reductions {
            fullKeys.remove(key); zeroKeys.remove(key)
            let deviation = deviationBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            if deviation[0] >= deviation[2] || deviation[1] >= deviation[3] {
                newTiles.removeValue(forKey: key)
                newBounds.removeValue(forKey: key)
                continue
            }
            let values = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            if values[0] < values[2], values[1] < values[3] {
                newBounds[key] = CGRect(x: key.x * tileSize + Int(values[0]),
                                        y: key.y * tileSize + Int(values[1]),
                                        width: Int(values[2] - values[0]),
                                        height: Int(values[3] - values[1]))
            } else {
                newBounds.removeValue(forKey: key)
                newTiles.removeValue(forKey: key)
                if newDefault == 255 { zeroKeys.insert(key) }
            }
            let notFull = notFullBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
            if notFull[0] >= notFull[2] || notFull[1] >= notFull[3] {
                newTiles.removeValue(forKey: key); fullKeys.insert(key)
            }
        }
        let canvasBounds = (page.boundary.finiteRect ?? .infinite)
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
        for key in fullKeys.union(zeroKeys) { newTiles.removeValue(forKey: key) }
        selection = SelectionSnapshot(defaultCoverage: newDefault, tiles: newTiles,
                                      tileBounds: newBounds, bounds: bounds,
                                      outlineKeys: outlineKeys, fullKeys: fullKeys, zeroKeys: zeroKeys)
    }

    private func polygonMasks(_ points: [SelectionPoint]) -> [SelectionTileKey: MTLTexture] {
        guard let first = points.first else { return [:] }
        let origin = SIMD2<Double>(floor(first.x/256)*256,floor(first.y/256)*256)
        return polygonRasterizer.rasterize(points.map { SIMD2<Float>(Float($0.x-origin.x), Float($0.y-origin.y)) },
            canvasSize: CGSize(width: page.width, height: page.height), tileSize: CanvasConstants.tileSize, boundary: page.boundary, origin:origin)
    }

    func commitClear(_ clear: ClearLayerCommand) {
        tileIndex = nil
        tileLOD?.invalidate()
        brushChanges.invalidate(layerID: clear.layerID)
        // Missing content tiles are transparent; missing mask tiles are white.
        // Clearing the whole target can therefore release its sparse allocation.
        guard let selection else {
            removeTiles(for: clear.layerID, target: clear.target)
            return
        }
        ensureResident(Set(archive.files.keys.filter { $0.layerID == clear.layerID && $0.target == clear.target && CGRect(x:$0.x*256,y:$0.y*256,width:256,height:256).intersects(selection.bounds) }))
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
            tileIndex = nil
            let changed = CGRect(x: key.x * size + Int(bounds[0]), y: key.y * size + Int(bounds[1]),
                width: Int(bounds[2] - bounds[0]), height: Int(bounds[3] - bounds[1]))
            dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(changed)
        }
        tileContents.record(Dictionary(uniqueKeysWithValues: pending.compactMap { key, output, _ in
            tiles[key].map { current in current === output ? (key, output) : nil } ?? nil
        }), width: page.width, height: page.height, boundary: page.boundary)
        thumbnailCache.removeValue(forKey: clear.layerID)
        emptyThumbnailLayers.remove(clear.layerID)
        maskThumbnailCache.removeValue(forKey: clear.layerID)
        view?.setNeedsDisplay()
    }

    func commitLassoFill(_ fill: LassoFillCommand) {
        commitRegionFill(fill, masks: polygonMasks(fill.points))
    }

    func commitRegionFill(_ fill: LassoFillCommand, masks: [SelectionTileKey: MTLTexture]) {
        tileIndex = nil
        tileLOD.invalidate()
        ensureResident(Set(masks.keys.map { TileKey(layerID:fill.layerID,x:$0.x,y:$0.y,target:fill.target) }))
        brushChanges.invalidate(layerID: fill.layerID)
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
            tileIndex = nil
            let changed = CGRect(x: key.x * size + Int(values[0]), y: key.y * size + Int(values[1]),
                                 width: Int(values[2] - values[0]), height: Int(values[3] - values[1]))
            dirtyBounds[key] = (dirtyBounds[key] ?? .null).union(changed)
        }
        tileContents.record(Dictionary(uniqueKeysWithValues: pending.compactMap { key, output, _ in
            tiles[key].map { current in current === output ? (key, output) : nil } ?? nil
        }), width: page.width, height: page.height, boundary: page.boundary)
        maskThumbnailCache.removeValue(forKey: fill.layerID)
        thumbnailCache.removeValue(forKey: fill.layerID)
        emptyThumbnailLayers.remove(fill.layerID)
        view?.setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scheduleViewportNotification()
        fitIfNeeded(viewSize: view.bounds.size)
        // Resizing the backing texture must invalidate an on-demand canvas,
        // including after the initial fit has already completed.
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard viewportVisible else { return }
        trimResidentTiles()
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let center = canvasPoint(from: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        let origin = SIMD2<Double>(floor(center.x / 256) * 256, floor(center.y / 256) * 256)
        let mapped = rotatedScaledPoint(CGPoint(x: origin.x, y: origin.y))
        render(pass: pass, commandBuffer: commandBuffer,
               viewport: CGSize(width: drawable.texture.width, height: drawable.texture.height),
               zoom: Float(zoom * view.contentScaleFactor),
               rotation: Float(rotation), includeChecker: true,
               pan: SIMD2<Float>(Float((pan.x + mapped.x) * view.contentScaleFactor),
                                 Float((pan.y + mapped.y) * view.contentScaleFactor)), origin: origin)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func render(pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer,
                        viewport: CGSize, zoom: Float, rotation: Float,
                        includeChecker: Bool, pan: SIMD2<Float>, origin: SIMD2<Double> = .zero) {
        renderOrigin = origin
        let c = Double(cos(rotation)), s = Double(sin(rotation)), z = Double(zoom)
        let corners = [CGPoint.zero, CGPoint(x: viewport.width, y: 0), CGPoint(x: 0, y: viewport.height), CGPoint(x: viewport.width, y: viewport.height)].map { p -> CGPoint in
            let x = p.x - Double(pan.x), y = p.y - Double(pan.y)
            return CGPoint(x: (x*c+y*s)/z + origin.x, y: (-x*s+y*c)/z + origin.y)
        }
        renderBounds = page.boundary.clip(CGRect(x: corners.map(\.x).min()! - 1, y: corners.map(\.y).min()! - 1, width: corners.map(\.x).max()! - corners.map(\.x).min()! + 2, height: corners.map(\.y).max()! - corners.map(\.y).min()! + 2))
        let visibleKeys = logicalIndex.query(renderBounds)
        if zoom > 0.5 { ensureResident(visibleKeys) }
        let screenSelection = includeChecker ? renderSelectionMask(command:commandBuffer,viewport:viewport,zoom:zoom,rotation:rotation,pan:pan) : nil
        if includeChecker { selectionMaskTarget = screenSelection }
        let inspectingSelection = includeChecker && showsSelectionTint && selection != nil
        let tintID = includeChecker ? viewportTintLayerID : nil
        let needsCompositing = !inspectingSelection && (tintID != nil || page.layers.contains { $0.hasMask || $0.opacity != 1 || $0.blendMode != .normal || $0.tone?.isEnabled == true || $0.curves?.isEnabled == true })
        let composite = needsCompositing ? composeGroup(parentID: nil, depth: 0,
            commandBuffer: commandBuffer, viewport: viewport, zoom: zoom,
            rotation: rotation, pan: pan, tintLayerID: tintID, tintTarget: viewportTintTarget) : nil
        guard !needsCompositing || composite != nil,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let vp = SIMD2<Float>(Float(viewport.width), Float(viewport.height))
        var paper = worldQuad(renderBounds, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
        if includeChecker {
            encoder.setRenderPipelineState(checkerPipeline)
            encoder.setVertexBytes(&paper, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        if inspectingSelection {
            drawSelectionOutline(encoder: encoder, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
            drawPageGuides(encoder: encoder, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
            encoder.endEncoding()
            return
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
            if layer.kind == .shape || layer.kind == .solidColor {
                let bounds = layer.kind == .solidColor ? renderBounds.intersection(layer.solidBounds ?? renderBounds) : (layer.shape?.bounds ?? .null)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                var background = worldQuad(bounds, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
                encoder.setRenderPipelineState(shapePipeline)
                var color = (layer.solidColor ?? layer.shape?.fill ?? .white).premultiplied
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setVertexBytes(&background, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                continue
            }
            guard layer.kind == .paint else { continue }
            encoder.setRenderPipelineState(tilePipeline)
            for (rect, texture) in displayTiles(layerID:layer.id,zoom:zoom) {
                var quad = worldQuad(rect, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
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

    private func displayTiles(layerID: UUID, target: LayerEditTarget = .content, zoom: Float, bounds: CGRect? = nil) -> [(CGRect,MTLTexture)] {
        let occupied = tileKeys.union(previewTiles.keys).filter { $0.layerID == layerID && $0.target == target }
        let level = previewStrokeID != nil ? 0 : max(0,min(30,Int(floor(log2(1 / max(Double(zoom),1e-12))))))
        let nodes = Set(occupied.map { CanvasTileLOD.Node(key:TileKey(layerID:layerID,x:$0.x >> level,y:$0.y >> level,target:target),level:level) })
        let tree = Set(occupied.flatMap { key in (0...level).map { level in CanvasTileLOD.Node(key:TileKey(layerID:key.layerID,x:key.x >> level,y:key.y >> level,target:key.target),level:level) } })
        let visible = bounds ?? renderBounds
        return nodes.filter { $0.rect.intersects(visible) }.compactMap { node in
            let texture = tileLOD.texture(node,occupied:tree) { key in
                if let value = previewTiles[key] ?? tiles[key] { return value }
                do {
                    guard let data = try archive.read(key) else { return nil }
                    let texture = newTile(target:key.target)
                    data.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256*key.target.bytesPerPixel) }
                    return texture
                } catch { reportStorageError(error); return nil }
            }
            return texture.map { (node.rect,$0) }
        }
    }

    private func worldQuad(_ rect: CGRect, viewport: SIMD2<Float>, zoom: Float, rotation: Float, pan: SIMD2<Float>) -> QuadUniforms {
        let rect = rect.isNull ? CGRect.zero : rect
        return QuadUniforms(origin: SIMD2(Float(rect.minX-renderOrigin.x), Float(rect.minY-renderOrigin.y)), size: SIMD2(Float(rect.width), Float(rect.height)), viewport: viewport, zoom: zoom, rotation: rotation, pan: pan, clip: page.boundary.gpuClip(relativeTo: renderOrigin))
    }

    func outputBounds(cropToContent: Bool = false) -> CGRect {
        if page.comicLayout != nil { return cropToContent ? page.contentRect : page.boundary.finiteRect! }
        if let finite = page.boundary.finiteRect { return finite }
        let content = tileContentBounds.filter { $0.key.target == .content }.values.reduce(CGRect.null) { $0.union($1) }
        let bounds = content.isNull ? page.boundary.initialRect : content.integral
        let x0 = page.boundary.hasMinimumX ? 0 : bounds.minX
        let y0 = page.boundary.hasMinimumY ? 0 : bounds.minY
        let x1 = page.boundary.width.map { CGFloat($0) } ?? bounds.maxX
        let y1 = page.boundary.height.map { CGFloat($0) } ?? bounds.maxY
        return CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
    }

    /// 1:1 means one image pixel per physical display pixel, including Retina screens.
    func setNativeZoom() {
        guard let view,view.bounds.width>0,view.bounds.height>0 else { return }
        let target=viewportGeometry.zoomedAroundCenter(to:1/max(view.contentScaleFactor,1))
        zoom=target.zoom;pan=target.pan
        (view as? CanvasSurface)?.refreshBrushCursor()
        view.setNeedsDisplay()
    }

    func centerViewport(on point: CGPoint) {
        pan = viewportGeometry.centeredPan(on:point)
        (view as? CanvasSurface)?.refreshBrushCursor()
        view?.setNeedsDisplay()
    }

    var navigationBounds: CGRect { outputBounds() }

    func navigationThumbnailPNG() throws -> Data {
        let oldOrigin = renderOrigin, oldBounds = renderBounds
        defer { renderOrigin = oldOrigin; renderBounds = oldBounds }
        return try projectThumbnailPNG()
    }

    var visibleContentLayerIDs: Set<UUID> {
        let geometry = viewportGeometry
        var result: Set<UUID> = []
        guard geometry.size.width > 0, geometry.size.height > 0 else { return result }
        for key in logicalIndex.query(geometry.canvasBounds) where key.target == .content && page.isEffectivelyVisible(key.layerID) {
            guard let bounds = tileContentBounds[key], geometry.intersects(bounds) else { continue }
            result.insert(key.layerID)
            var parent = page.layers.first { $0.id == key.layerID }?.parentID
            while let id = parent { result.insert(id); parent = page.layers.first { $0.id == id }?.parentID }
        }
        return result
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
            if let effect = layer.curves, effect.isEnabled && !tinted {
                uniforms.padding |= 4
                encoder?.setFragmentTexture(curveTexture(effect, layerID: layer.id), index: 3)
            } else { encoder?.setFragmentTexture(fullMask, index: 3) }
            if let tone = layer.tone, tone.isEnabled && !tinted {
                let dpi = Float(page.comicLayout?.dpi ?? 350)
                uniforms.tone = SIMD4<Float>(dpi / Float(max(1, tone.frequency)),
                    Float(tone.angle * .pi / 180), Float(tone.density), 1)
                let angle = tone.angle * .pi / 180, period = Double(uniforms.tone.x)
                uniforms.tonePhase = SIMD2(Float(((renderOrigin.x*cos(angle)+renderOrigin.y*sin(angle))/period).truncatingRemainder(dividingBy:1)), Float(((-renderOrigin.x*sin(angle)+renderOrigin.y*cos(angle))/period).truncatingRemainder(dividingBy:1)))
                uniforms.canvasMap = SIMD4<Float>(cos(rotation) / max(zoom, 1e-12),
                    sin(rotation) / max(zoom, 1e-12), pan.x, pan.y)
            }
            if maskPreview {
                guard let encoder else { return nil }
                var quad = worldQuad(renderBounds, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
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
                encoder.setFragmentTexture(layer.curves.map { curveTexture($0, layerID: layer.id) } ?? fullMask, index: 3)
                var screen = QuadUniforms(origin: .zero, size: vp, viewport: vp,
                                          zoom: 1, rotation: 0, pan: .zero)
                encoder.setVertexBytes(&screen, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                encoder.setFragmentTexture(child, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            } else if layer.kind == .shape || layer.kind == .solidColor {
                let rect = layer.kind == .solidColor ? renderBounds.intersection(layer.solidBounds ?? renderBounds) : (layer.shape?.bounds ?? .null)
                guard !rect.isNull, !rect.isEmpty else { continue }
                guard let encoder else { return nil }
                uniforms.solidColor = (layer.solidColor ?? layer.shape?.fill ?? .white).premultiplied
                var quad = worldQuad(rect, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
                uniforms.solid = 1
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                // A valid texture is required even though the solid branch does not sample it.
                encoder.setFragmentTexture(emptyMask, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            } else {
                guard let encoder else { return nil }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerCompositeUniforms>.stride, index: 0)
                for (rect,texture) in displayTiles(layerID:layer.id,zoom:zoom) {
                    var quad = worldQuad(rect, viewport: vp, zoom: zoom, rotation: rotation, pan: pan)
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
        for (rect,tile) in displayTiles(layerID:layerID,target:.mask,zoom:zoom) {
            var quad = worldQuad(rect,viewport:SIMD2(Float(width),Float(height)),zoom:zoom,rotation:rotation,pan:pan)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(tile, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        return target
    }

    func maskThumbnail(for layerID: UUID) -> UIImage? {
        if let cached = maskThumbnailCache[layerID] { return cached }
        let bounds = outputBounds()
        renderOrigin = SIMD2(bounds.minX,bounds.minY); renderBounds = bounds
        let scale = min(48.0 / bounds.width, 48.0 / bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
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
        for (worldRect, color) in frames {
            let rect = worldRect.offsetBy(dx:-renderOrigin.x,dy:-renderOrigin.y)
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

    private func renderSelectionMask(command: MTLCommandBuffer, viewport: CGSize, zoom: Float, rotation: Float, pan: SIMD2<Float>) -> MTLTexture? {
        guard let selection, !selection.tiles.isEmpty, !renderBounds.isNull else { return nil }
        let width = max(1,Int(viewport.width)), height = max(1,Int(viewport.height))
        if selectionMaskTarget?.width != width || selectionMaskTarget?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:width,height:height,mipmapped:false)
            d.storageMode = .private; d.usage = [.renderTarget,.shaderRead]
            selectionMaskTarget = device.makeTexture(descriptor:d)
        }
        guard let target = selectionMaskTarget else { return nil }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return nil }
        encoder.setRenderPipelineState(maskViewPipeline)
        let vp = SIMD2<Float>(Float(width),Float(height))
        if selection.defaultCoverage == 255 {
            var quad = worldQuad(renderBounds,viewport:vp,zoom:zoom,rotation:rotation,pan:pan)
            encoder.setVertexBytes(&quad,length:MemoryLayout<QuadUniforms>.stride,index:0); encoder.setFragmentTexture(fullMask,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        }
        for (key,texture) in selection.tiles {
            let rect = CGRect(x:key.x*256,y:key.y*256,width:256,height:256)
            guard rect.intersects(renderBounds) else { continue }
            var quad = worldQuad(rect,viewport:vp,zoom:zoom,rotation:rotation,pan:pan)
            encoder.setVertexBytes(&quad,length:MemoryLayout<QuadUniforms>.stride,index:0); encoder.setFragmentTexture(texture,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        }
        encoder.endEncoding(); return target
    }

    private func drawSelectionOutline(encoder: MTLRenderCommandEncoder,
                                      viewport: SIMD2<Float>, zoom: Float,
                                      rotation: Float, pan: SIMD2<Float>) {
        let phase = Float(CACurrentMediaTime() * 3).truncatingRemainder(dividingBy: 2)
        if let selection {
            let size = CanvasConstants.tileSize
            let visible = renderBounds
            guard !visible.isNull else { return }
            let minX = Int(floor((visible.minX - 2) / Double(size)))
            let minY = Int(floor((visible.minY - 2) / Double(size)))
            let maxX = Int(floor((visible.maxX + 2) / Double(size)))
            let maxY = Int(floor((visible.maxY + 2) / Double(size)))
            let selectedTiles = selection.tiles
            let constantSelection = selectedTiles.isEmpty && selection.defaultCoverage == 255
            if constantSelection || selectionMaskTarget != nil {
                encoder.setRenderPipelineState(showsSelectionTint ? selectionTintPipeline : selectionOutlinePipeline)
                var quad = worldQuad(visible.insetBy(dx: -Double(0.75 / max(zoom,1e-12)), dy: -Double(0.75 / max(zoom,1e-12))), viewport: viewport, zoom: zoom, rotation: rotation, pan: pan)
                quad.clip = SIMD4(-.infinity,-.infinity,.infinity,.infinity)
                var uniforms = SelectionOutlineUniforms(tileOrigin: .zero, canvasSize: SIMD2(.infinity,.infinity), zoom: zoom, phase: phase, bounds: page.boundary.gpuClip(relativeTo: renderOrigin), viewport: viewport, constant: constantSelection ? 1 : (zoom < 0.05 ? 3 : 2))
                encoder.setVertexBytes(&quad,length:MemoryLayout<QuadUniforms>.stride,index:0)
                encoder.setFragmentBytes(&uniforms,length:MemoryLayout<SelectionOutlineUniforms>.stride,index:0)
                for index in 0...8 { encoder.setFragmentTexture(selectionMaskTarget ?? fullMask,index:index) }
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
            }
            if !constantSelection, !showsSelectionTint, zoom >= 0.05, minX <= maxX, minY <= maxY {
                let fallback = selection.defaultCoverage == 0 ? emptyMask : fullMask
                encoder.setRenderPipelineState(selectionOutlinePipeline)
                let fullKeys = selection.fullKeys, zeroKeys = selection.zeroKeys
                func constantCoverage(_ key:SelectionTileKey) -> UInt8? {
                    if fullKeys.contains(key) { return 255 }
                    if zeroKeys.contains(key) { return 0 }
                    return selectedTiles[key] == nil ? selection.defaultCoverage : nil
                }
                for key in selection.outlineKeys where key.x >= minX && key.x <= maxX && key.y >= minY && key.y <= maxY {
                    let x = key.x, y = key.y
                    if let constant = constantCoverage(key), (-1...1).allSatisfy({ dy in (-1...1).allSatisfy { dx in constantCoverage(SelectionTileKey(x:x+dx,y:y+dy)) == constant } }) { continue }
                    let origin = SIMD2<Float>(Float(Double(x * size)-renderOrigin.x), Float(Double(y * size)-renderOrigin.y))
                    var quad = QuadUniforms(origin:origin,size:SIMD2<Float>(repeating:Float(size)),
                        viewport:viewport,zoom:zoom,rotation:rotation,pan:pan)
                    var uniforms = SelectionOutlineUniforms(
                        tileOrigin: origin,
                        canvasSize: SIMD2<Float>(Float(page.width), Float(page.height)),
                        zoom: zoom, phase: phase, bounds: page.boundary.gpuClip(relativeTo: renderOrigin), viewport: viewport)
                    encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&uniforms,
                        length: MemoryLayout<SelectionOutlineUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(selectedTiles[key] ?? fallback, index: 0)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x: x - 1, y: y)] ?? fallback, index: 1)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x: x + 1, y: y)] ?? fallback, index: 2)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x: x, y: y - 1)] ?? fallback, index: 3)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x: x, y: y + 1)] ?? fallback, index: 4)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x:x-1,y:y-1)] ?? fallback,index:5)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x:x+1,y:y-1)] ?? fallback,index:6)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x:x-1,y:y+1)] ?? fallback,index:7)
                    encoder.setFragmentTexture(selectedTiles[SelectionTileKey(x:x+1,y:y+1)] ?? fallback,index:8)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }
        }
        if lassoPreviewPoints.count >= 2 {
            let positions = lassoPreviewPoints.map { SIMD2<Float>(Float($0.x-renderOrigin.x),Float($0.y-renderOrigin.y)) }
            guard let points = device.makeBuffer(bytes:positions,length:positions.count * MemoryLayout<SIMD2<Float>>.stride) else { return }
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
            let x0 = Float(floor(rect.minX + 0.5)-renderOrigin.x)
            let y0 = Float(floor(rect.minY + 0.5)-renderOrigin.y)
            let x1 = Float(floor(rect.maxX + 0.5)-renderOrigin.x)
            let y1 = Float(floor(rect.maxY + 0.5)-renderOrigin.y)
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
               pan: .zero, origin: SIMD2(floor(point.x), floor(point.y)))
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

    private func curveTexture(_ effect: LayerCurveEffect, layerID: UUID) -> MTLTexture {
        if let cached = curveTextures[layerID], cached.0 == effect { return cached.1 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 256, height: 4, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)!
        let values = effect.lookupTable
        values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 256, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * 4) }
        curveTextures[layerID] = (effect, texture)
        return texture
    }

    func selectionReadback() -> (tiles: [SelectionTileKey: Data]?, defaultCoverage: UInt8) {
        prepareForReadback()
        return (selection?.tiles.mapValues { bytes(of: $0) }, selection?.defaultCoverage ?? 255)
    }

    func exportPNG(cropToContent: Bool) throws -> Data {
        let bounds = outputBounds(cropToContent: cropToContent)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000 else { throw RendererError.exportFailed }
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
               pan: .zero, origin: SIMD2(bounds.minX, bounds.minY))
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

    /// Trimmed paper texture for document previews; independent of editing overlays.
    func bookPreviewTexture(maxDimension: Double = 1280) throws -> MTLTexture {
        let bounds = page.contentRect
        let scale = min(maxDimension / bounds.width, maxDimension / bounds.height, 1)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { throw RendererError.exportFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        render(pass: pass, commandBuffer: command, viewport: CGSize(width: width, height: height),
               zoom: Float(scale), rotation: 0, includeChecker: false, pan: .zero,
               origin: SIMD2(bounds.minX, bounds.minY))
        let blit = command.makeBlitCommandEncoder()
        blit?.generateMipmaps(for: texture)
        blit?.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw RendererError.exportFailed }
        return texture
    }

    func projectThumbnailPNG() throws -> Data {
        let bounds = outputBounds()
        let scale = min(320.0 / bounds.width, 320.0 / bounds.height, 1)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
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
               rotation: 0, includeChecker: false, pan: .zero, origin: SIMD2(bounds.minX, bounds.minY))
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
