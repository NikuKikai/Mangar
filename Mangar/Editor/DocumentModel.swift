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

struct LayerRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case paint, folder, solidWhite }

    var id: UUID = UUID()
    var name: String
    var kind: Kind = .paint
    var parentID: UUID? = nil
    var isVisible: Bool = true
    var opacity: Double = 1
    var isLocked: Bool = false
    /// Bounds of a procedural background after page merge/split.
    var paperBounds: CGRect? = nil
}

extension LayerRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, parentID, isVisible, opacity, isLocked, paperBounds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        isVisible = try values.decode(Bool.self, forKey: .isVisible)
        opacity = try values.decode(Double.self, forKey: .opacity)
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        paperBounds = try values.decodeIfPresent(CGRect.self, forKey: .paperBounds)
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

    static func blank(name: String = "第 1 页",
                      width: Int = CanvasConstants.defaultWidth,
                      height: Int = CanvasConstants.defaultHeight,
                      comicLayout: ComicPageLayout? = nil,
                      isSpread: Bool = false) -> PageRecord {
        PageRecord(name: name, width: width,
                   height: height, comicLayout: comicLayout, isSpread: isSpread,
                   layers: [LayerRecord(name: "背景", kind: .solidWhite, isLocked: true),
                            LayerRecord(name: "图层 1")])
    }
}

struct ProjectManifest: Codable {
    var formatVersion: Int = 1
    var name: String = "我的漫画"
    var pageIDs: [UUID]
    var selectedPageID: UUID
    var startingSide: PageStartSide = .right
    var spreadPageIDs: [UUID] = []
    var singlePageLayout: ComicPageLayout? = nil

    var logicalPageCount: Int { pageIDs.reduce(0) { $0 + (spreadPageIDs.contains($1) ? 2 : 1) } }

    func firstPageNumber(for id: UUID) -> Int {
        1 + pageIDs.prefix { $0 != id }.reduce(0) { $0 + (spreadPageIDs.contains($1) ? 2 : 1) }
    }
}

extension ProjectManifest {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, pageIDs, selectedPageID, startingSide, spreadPageIDs, singlePageLayout
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
    }
}

struct TileKey: Hashable, Codable {
    var layerID: UUID
    var x: Int
    var y: Int
}

struct StrokeSample: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
}

struct RoundBrush: Codable, Equatable {
    var size: Double = 12
    var opacity: Double = 1
    var spacing: Double = 0.18
    var sizeJitter: Double = 0
    var opacityJitter: Double = 0
    var positionJitter: Double = 0
    var buildsOpacity: Bool = false
    var red: Double = 0.08
    var green: Double = 0.08
    var blue: Double = 0.09
}

enum DrawingTool: String, Codable {
    case brush, eraser, selection
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

enum SelectionCommand: Codable {
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
    var layerID: UUID
    var samples: [StrokeSample]
    var brush: RoundBrush
    var seed: UInt64
    var tool: DrawingTool
}

enum EditCommand: Codable {
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
    var tiles: [TileKey: Data]
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
