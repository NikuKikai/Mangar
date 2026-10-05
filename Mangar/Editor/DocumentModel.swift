import Foundation

enum CanvasConstants {
    static let tileSize = 256
    static let defaultWidth = 2048
    static let defaultHeight = 2048
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
}

extension LayerRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, parentID, isVisible, opacity, isLocked
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
    var backgroundSchemaVersion: Int? = 3
    /// Bottom layer first.
    var layers: [LayerRecord]

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

    static func blank(name: String = "第 1 页") -> PageRecord {
        PageRecord(name: name, width: CanvasConstants.defaultWidth,
                   height: CanvasConstants.defaultHeight,
                   layers: [LayerRecord(name: "背景", kind: .solidWhite, isLocked: true),
                            LayerRecord(name: "图层 1")])
    }
}

struct ProjectManifest: Codable {
    var formatVersion: Int = 1
    var name: String = "我的漫画"
    var pageIDs: [UUID]
    var selectedPageID: UUID
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
