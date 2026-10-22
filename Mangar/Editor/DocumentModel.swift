import Foundation
import CoreGraphics

enum CanvasConstants {
    static let tileSize = 256
    static let defaultWidth = 2048
    static let defaultHeight = 2048
}

struct ComicPageLayout: Codable, Equatable {
    var contentWidthMM: Double
    var contentHeightMM: Double
    var dpi: Int
    /// Left/right canvas margin. Older pages use it on all four sides.
    var marginMM: Double
    var verticalMarginMM: Double? = nil
    var bleedMM: Double = 3
    var pageSpan: Int? = nil

    private func pixels(_ millimeters: Double) -> Int {
        Int((millimeters * Double(dpi) / 25.4).rounded())
    }

    var totalContentWidthMM: Double { contentWidthMM * Double(pageSpan ?? 1) }
    var contentWidthPixels: Int { pixels(contentWidthMM) * (pageSpan ?? 1) }
    var contentHeightPixels: Int { pixels(contentHeightMM) }
    var effectiveVerticalMarginMM: Double { verticalMarginMM ?? marginMM }
    var horizontalMarginPixels: Int { pixels(marginMM) }
    var verticalMarginPixels: Int { pixels(effectiveVerticalMarginMM) }
    var canvasWidthPixels: Int { contentWidthPixels + 2 * horizontalMarginPixels }
    var canvasHeightPixels: Int { contentHeightPixels + 2 * verticalMarginPixels }
    var contentRect: CGRect {
        CGRect(x: horizontalMarginPixels, y: verticalMarginPixels,
               width: contentWidthPixels, height: contentHeightPixels)
    }
    var bleedRect: CGRect {
        contentRect.insetBy(dx: -CGFloat(pixels(min(bleedMM, marginMM))),
                           dy: -CGFloat(pixels(min(bleedMM, effectiveVerticalMarginMM))))
    }
}

enum LayerBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay, darken, lighten, softLight, hardLight, difference, add

    var title: String {
        switch self {
        case .normal: L10n.text("正常")
        case .multiply: L10n.text("乘算")
        case .screen: L10n.text("滤色")
        case .overlay: L10n.text("blend.overlay")
        case .darken: L10n.text("变暗")
        case .lighten: L10n.text("变亮")
        case .softLight: L10n.text("柔光")
        case .hardLight: L10n.text("强光")
        case .difference: L10n.text("差值")
        case .add: L10n.text("添加（发光）")
        }
    }
    /// Short UI badge names are explicit; truncation can make modes indistinguishable.
    var shortTitle: String { L10n.text("blend.\(rawValue).short") }

    var shaderIndex: UInt32 { UInt32(Self.allCases.firstIndex(of: self)!) }
}

struct LayerToneEffect: Codable, Equatable {
    var isEnabled: Bool = true
    var frequency: Double = 60
    var angle: Double = 45
    var density: Double = 1
}

struct LayerRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case paint, folder, shape, solidColor }

    var id: UUID = UUID()
    var name: String
    var kind: Kind = .paint
    var parentID: UUID? = nil
    var isVisible: Bool = true
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var tone: LayerToneEffect? = nil
    var curves: LayerCurveEffect? = nil
    var hasMask: Bool = false
    var isLocked: Bool = false
    var shape: LayerShape? = nil
    var solidColor: ShapeColor? = nil
    var solidBounds: CGRect? = nil
}

extension LayerRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, parentID, isVisible, opacity, blendMode, tone, curves, hasMask, isLocked, shape, solidColor, solidBounds
    }

    private enum LegacyKeys: String, CodingKey { case paperBounds }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let rawKind = try values.decode(String.self, forKey: .kind)
        if rawKind == "solidWhite" { kind = .shape }
        else if let decoded = Kind(rawValue: rawKind) { kind = decoded }
        else { throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown layer kind") }
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        isVisible = try values.decode(Bool.self, forKey: .isVisible)
        opacity = try values.decode(Double.self, forKey: .opacity)
        blendMode = try values.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal
        tone = try values.decodeIfPresent(LayerToneEffect.self, forKey: .tone)
        curves = try values.decodeIfPresent(LayerCurveEffect.self, forKey: .curves)
        hasMask = try values.decodeIfPresent(Bool.self, forKey: .hasMask) ?? false
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        shape = try values.decodeIfPresent(LayerShape.self, forKey: .shape)
        solidColor = try values.decodeIfPresent(ShapeColor.self, forKey: .solidColor)
        solidBounds = try values.decodeIfPresent(CGRect.self, forKey: .solidBounds)
        if rawKind == "solidWhite", let bounds = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(CGRect.self, forKey: .paperBounds) {
            shape = .rect(bounds: bounds, fill: .white)
        }
    }
}

enum LayerDropPlacement: Equatable { case above, below, inside }

struct LayerDisplayEntry: Identifiable {
    let layer: LayerRecord
    let depth: Int
    var id: UUID { layer.id }
}

struct PageRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var width: Int
    var height: Int
    var canvasBoundary: CanvasBoundary? = nil
    var surface: PageSurface? = nil
    var pageSurface: PageSurface { (surface ?? .normal).normalized }
    var boundary: CanvasBoundary { canvasBoundary ?? CanvasBoundary(width: width, height: height) }
    /// Nil for projects created before physical page settings were introduced.
    var comicLayout: ComicPageLayout? = nil
    var isSpread: Bool? = nil
    var backgroundSchemaVersion: Int? = 3
    /// Bottom layer first.
    var layers: [LayerRecord]

    var contentRect: CGRect {
        comicLayout?.contentRect ?? CGRect(x: 0, y: 0, width: width, height: height)
    }
    var isDoublePage: Bool { isSpread == true }

    /// Storage is bottom to top; the panel presents each folder before its children.
    var layerDisplayEntries: [LayerDisplayEntry] {
        var entries: [LayerDisplayEntry] = []
        var visited = Set<UUID>()
        func appendChildren(of parentID: UUID?, depth: Int) {
            for layer in layers.reversed() where layer.parentID == parentID {
                guard visited.insert(layer.id).inserted else { continue }
                entries.append(LayerDisplayEntry(layer: layer, depth: depth))
                if layer.kind == .folder { appendChildren(of: layer.id, depth: depth + 1) }
            }
        }
        appendChildren(of: nil, depth: 0)
        return entries
    }

    func isDescendant(_ id: UUID, of ancestorID: UUID) -> Bool {
        var current = layers.first(where: { $0.id == id })?.parentID
        var visited = Set<UUID>()
        while let parentID = current, visited.insert(parentID).inserted {
            if parentID == ancestorID { return true }
            current = layers.first(where: { $0.id == parentID })?.parentID
        }
        return false
    }

    func isEffectivelyVisible(_ id: UUID) -> Bool {
        var current: UUID? = id
        var visited = Set<UUID>()
        while let layerID = current, visited.insert(layerID).inserted {
            guard let layer = layers.first(where: { $0.id == layerID }), layer.isVisible else { return false }
            current = layer.parentID
        }
        return current == nil
    }

    func isEffectivelyLocked(_ id: UUID) -> Bool {
        var current: UUID? = id
        var visited = Set<UUID>()
        while let layerID = current, visited.insert(layerID).inserted {
            guard let layer = layers.first(where: { $0.id == layerID }) else { return true }
            if layer.isLocked { return true }
            current = layer.parentID
        }
        return current != nil
    }

    func subtreeRange(of id: UUID) -> Range<Int>? {
        guard let start = layers.firstIndex(where: { $0.id == id }) else { return nil }
        var end = start + 1
        while end < layers.count, isDescendant(layers[end].id, of: id) { end += 1 }
        return start..<end
    }

    func movingLayers(_ requested: [UUID], relativeTo targetID: UUID,
                      placement: LayerDropPlacement) -> [LayerRecord]? {
        guard let target = layers.first(where: { $0.id == targetID }) else { return nil }
        if placement == .inside && target.kind != .folder { return nil }
        let destinationParent = placement == .inside ? targetID : target.parentID
        if let destinationParent, isEffectivelyLocked(destinationParent) { return nil }
        let roots = requested.filter { candidate in
            !requested.contains { $0 != candidate && isDescendant(candidate, of: $0) }
        }
        guard !roots.isEmpty, roots.allSatisfy({ !isEffectivelyLocked($0) }) else { return nil }
        let ranges = roots.compactMap(subtreeRange).sorted { $0.lowerBound < $1.lowerBound }
        guard ranges.count == roots.count else { return nil }
        let movingIDs = Set(ranges.flatMap { layers[$0].map(\.id) })
        guard !movingIDs.contains(targetID) else { return nil }
        var updated = layers.filter { !movingIDs.contains($0.id) }
        var moving: [LayerRecord] = []
        for range in ranges {
            var block = Array(layers[range])
            block[0].parentID = destinationParent
            moving.append(contentsOf: block)
        }
        var remaining = self
        remaining.layers = updated
        guard let targetRange = remaining.subtreeRange(of: targetID) else { return nil }
        let insertion = placement == .below ? targetRange.lowerBound : targetRange.upperBound
        updated.insert(contentsOf: moving, at: insertion)
        return updated == layers ? nil : updated
    }

    static func blank(name: String = L10n.text("第 1 页"),
                      width: Int = CanvasConstants.defaultWidth,
                      height: Int = CanvasConstants.defaultHeight,
                      comicLayout: ComicPageLayout? = nil,
                      isSpread: Bool = false, boundary: CanvasBoundary? = nil, surface: PageSurface = .normal) -> PageRecord {
        PageRecord(name: name, width: width,
                   height: height, canvasBoundary: boundary, surface: surface.normalized, comicLayout: comicLayout, isSpread: isSpread,
                   layers: [LayerRecord(name: L10n.text("背景"), kind: .solidColor, isLocked: true, solidColor: .white),
                            LayerRecord(name: L10n.text("图层 1"))])
    }
}

extension PageRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, width, height, canvasBoundary, surface, comicLayout, isSpread, backgroundSchemaVersion, layers
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        canvasBoundary = try values.decodeIfPresent(CanvasBoundary.self, forKey: .canvasBoundary)
        surface = try values.decodeIfPresent(PageSurface.self, forKey: .surface)
        comicLayout = try values.decodeIfPresent(ComicPageLayout.self, forKey: .comicLayout)
        isSpread = try values.decodeIfPresent(Bool.self, forKey: .isSpread)
        backgroundSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .backgroundSchemaVersion)
        layers = try values.decode([LayerRecord].self, forKey: .layers)
        // Legacy solidWhite layers without bounds meant the entire owning page.
        for index in layers.indices where layers[index].kind == .shape && layers[index].shape == nil {
            layers[index].shape = .rect(bounds: CGRect(x: 0, y: 0, width: width, height: height), fill: .white)
        }
    }
}

struct ProjectManifest: Codable {
    var formatVersion: Int = 1
    var name: String = L10n.text("我的漫画")
    var pageIDs: [UUID]
    var selectedPageID: UUID
    var startingSide: PageStartSide = .right
    var spreadPageIDs: [UUID] = []
    var singlePageLayout: ComicPageLayout? = nil
    var purpose: ProjectPurpose = .book
    var pageStructure: PageStructure = .bookSpreads
    var initialBoundary: CanvasBoundary? = nil

    var logicalPageCount: Int { pageIDs.reduce(0) { $0 + (spreadPageIDs.contains($1) ? 2 : 1) } }

    func firstPageNumber(for id: UUID) -> Int {
        1 + pageIDs.prefix { $0 != id }.reduce(0) { $0 + (spreadPageIDs.contains($1) ? 2 : 1) }
    }
}

extension ProjectManifest {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, pageIDs, selectedPageID, startingSide, spreadPageIDs, singlePageLayout, purpose, pageStructure, initialBoundary
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        name = try values.decode(String.self, forKey: .name)
        pageIDs = try values.decode([UUID].self, forKey: .pageIDs)
        selectedPageID = try values.decode(UUID.self, forKey: .selectedPageID)
        startingSide = try values.decodeIfPresent(PageStartSide.self, forKey: .startingSide) ?? .right
        spreadPageIDs = try values.decodeIfPresent([UUID].self, forKey: .spreadPageIDs) ?? []
        singlePageLayout = try values.decodeIfPresent(ComicPageLayout.self, forKey: .singlePageLayout)
        purpose = try values.decodeIfPresent(ProjectPurpose.self, forKey: .purpose) ?? .book
        pageStructure = try values.decodeIfPresent(PageStructure.self, forKey: .pageStructure) ?? .bookSpreads
        initialBoundary = try values.decodeIfPresent(CanvasBoundary.self, forKey: .initialBoundary)
    }
}

nonisolated enum LayerEditTarget: String, Codable {
    case content, mask
    var bytesPerPixel: Int { self == .mask ? 1 : 4 }
    var defaultByte: UInt8 { self == .mask ? 255 : 0 }
}

struct TileKey: Hashable, Codable {
    var layerID: UUID
    var x: Int
    var y: Int
    var target: LayerEditTarget = .content
    var rawSize: Int { CanvasConstants.tileSize * CanvasConstants.tileSize * target.bytesPerPixel }
}

extension TileKey {
    private enum CodingKeys: String, CodingKey { case layerID, x, y, target }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try c.decode(UUID.self, forKey: .layerID)
        x = try c.decode(Int.self, forKey: .x)
        y = try c.decode(Int.self, forKey: .y)
        target = try c.decodeIfPresent(LayerEditTarget.self, forKey: .target) ?? .content
    }
}

enum DrawingTool: String, Codable {
    case brush, eraser, selection, lassoSelection, lassoFill, bucket

    var isSelectionTool: Bool { self == .selection || self == .lassoSelection }
    var isRegionTool: Bool { isSelectionTool || self == .lassoFill }
}

enum SelectionCombineMode: String, Codable {
    case replace, add, subtract, intersect
}

struct SelectionRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct SelectionPoint: Codable {
    var x: Double
    var y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct LassoFillCommand: Codable {
    var layerID: UUID
    var points: [SelectionPoint]
    var brush: BrushConfiguration
    var target: LayerEditTarget = .content
    var erases: Bool = false
}

enum SelectionCommand: Codable {
    case lasso([SelectionPoint], SelectionCombineMode)
    case rectangle(SelectionRect, SelectionCombineMode)
    case selectAll
    case invert
    case clear
}

enum EditorModifier: String, CaseIterable, Hashable {
    case command, option, shift, control

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .shift: "⇧"
        case .control: "⌃"
        }
    }

    var name: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .shift: "Shift"
        case .control: "Control"
        }
    }
}

struct StrokeCommand: Codable {
    var tipAssets: [BrushTipAsset]? = nil
    var resourceRevision: String? = nil
    var id: UUID = UUID()
    var definition: BrushDefinition = MangaBrushes.definition(.gPen)
    var layerID: UUID
    var samples: [StrokeSample]
    var brush: BrushConfiguration
    var seed: UInt64
    var tool: DrawingTool
    var target: LayerEditTarget = .content
}

struct ClearLayerCommand: Codable {
    var layerID: UUID
    var target: LayerEditTarget
}

enum EditCommand: Codable {
    case setPageSurface(PageSurface)
    case clearLayer(ClearLayerCommand)
    case lassoFill(LassoFillCommand)
    case bucketFill(BucketFillCommand)
    case stroke(StrokeCommand)
    case selection(SelectionCommand)
    case addLayer(LayerRecord, Int)
    case removeLayer(UUID)
    case moveLayer(UUID, Int)
    case setVisibility(UUID, Bool)
    case setLocked(UUID, Bool)
    case replaceLayerStack([LayerRecord])
}

struct DocumentCheckpoint {
    var page: PageRecord
    var tiles: [TileKey: Data] = [:]
    var archive: CanvasTileArchive? = nil
    var selection: SelectionSnapshot? = nil
}

struct CommandHistory {
    var checkpoint: DocumentCheckpoint
    var commands: [EditCommand] = []
    var cursor = 0
    let limit = 48

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < commands.count }
}
