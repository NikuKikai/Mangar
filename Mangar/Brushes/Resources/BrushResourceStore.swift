import Foundation
import CryptoKit

struct BrushRecipe: Codable, Equatable {
    var formatVersion = 1
    var engineVersion = 7
    var configuration: BrushConfiguration
    init(_ configuration: BrushConfiguration) {
        var value = configuration.validated
        value.resourceID = nil
        value.red = 0; value.green = 0; value.blue = 0
        value.dynamics = value.resolvedDynamics; value.tip = value.tipSettings
        value.rendering = value.renderingSettings; value.stamp = value.stampSettings; value.wet = value.wetSettings
        self.configuration = value
    }
    var revision: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try! encoder.encode(self)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
struct BrushResource: Codable, Identifiable {
    let id: UUID
    var name: String
    var revision: String
    let initialRevision: String
}

/// Manifest is the publication point. Referenced immutable payloads are written first.
final class BrushResourceStore {
    static let shared = BrushResourceStore()
    let root: URL
    private var assetCache: [String: BrushTipAsset] = [:]
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrushResources", isDirectory: true)
    }
    func resources() throws -> [BrushResource] {
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([BrushResource].self, from: Data(contentsOf: url))
    }
    func create(name: String, configuration: BrushConfiguration) throws -> BrushResource {
        let recipe = BrushRecipe(configuration)
        try writeRecipe(recipe)
        let resource = BrushResource(id: UUID(), name: cleaned(name), revision: recipe.revision, initialRevision: recipe.revision)
        var all = try resources(); all.append(resource); try publish(all)
        return resource
    }
    func configuration(_ resource: BrushResource, color: BrushConfiguration) throws -> BrushConfiguration {
        let recipe = try readRecipe(resource.revision)
        var result = recipe.configuration
        result.resourceID = resource.id
        result.red = color.red; result.green = color.green; result.blue = color.blue
        return result
    }
    func update(_ configuration: BrushConfiguration) throws {
        guard let id = configuration.resourceID else { return }
        var all = try resources()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw BrushResourceError.invalidResource }
        let recipe = BrushRecipe(configuration)
        guard all[index].revision != recipe.revision else { return }
        try writeRecipe(recipe)
        all[index].revision = recipe.revision; try publish(all)
    }
    func rename(_ id: UUID, name: String) throws {
        var all = try resources()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw BrushResourceError.invalidResource }
        all[index].name = cleaned(name); try publish(all)
    }
    func reset(_ id: UUID, color: BrushConfiguration) throws -> BrushConfiguration {
        var all = try resources()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw BrushResourceError.invalidResource }
        all[index].revision = all[index].initialRevision
        let result = try configuration(all[index], color: color)
        try publish(all); return result
    }
    func store(_ asset: BrushTipAsset) throws {
        guard asset.isValid else { throw BrushResourceError.invalidTip }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tips"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("tips/\(asset.id).tip")
        if !FileManager.default.fileExists(atPath: url.path) {
            var bytes = Data()
            for dimension in [asset.width, asset.height] {
                var value = UInt32(dimension).littleEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            }
            bytes.append(asset.coverage)
            try bytes.write(to: url, options: .atomic)
        }
        if assetCache.count >= 32 { assetCache.removeAll() }
        assetCache[asset.id] = asset
    }
    func assets(for configuration: BrushConfiguration) throws -> [BrushTipAsset] {
        try configuration.stampSettings.assetIDs.map { id in
            guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw BrushResourceError.missingTip }
            if let cached = assetCache[id] { return cached }
            if let bundled = try BundledBrushTips.load(id) {
                if assetCache.count >= 32 { assetCache.removeAll() }
                assetCache[id] = bundled; return bundled
            }
            let bytes = try Data(contentsOf: root.appendingPathComponent("tips/\(id).tip"))
            guard bytes.count >= 8 else { throw BrushResourceError.missingTip }
            func dimension(_ start: Int) -> Int {
                (0..<4).reduce(0) { $0 | (Int(bytes[start + $1]) << ($1 * 8)) }
            }
            let asset = try BrushTipAsset(width: dimension(0), height: dimension(4), coverage: Data(bytes.dropFirst(8)))
            guard asset.id == id, asset.isValid else { throw BrushResourceError.missingTip }
            if assetCache.count >= 32 { assetCache.removeAll() }
            assetCache[id] = asset; return asset
        }
    }
    private func writeRecipe(_ recipe: BrushRecipe) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("revisions"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("revisions/\(recipe.revision).json")
        if !FileManager.default.fileExists(atPath: url.path) { try JSONEncoder().encode(recipe).write(to: url, options: .atomic) }
    }
    private func readRecipe(_ revision: String) throws -> BrushRecipe {
        guard revision.count == 64, revision.allSatisfy({ $0.isHexDigit }) else { throw BrushResourceError.invalidResource }
        let recipe = try JSONDecoder().decode(BrushRecipe.self, from: Data(contentsOf: root.appendingPathComponent("revisions/\(revision).json")))
        guard recipe.revision == revision else { throw BrushResourceError.invalidResource }
        return recipe
    }
    private func publish(_ resources: [BrushResource]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(resources).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
    private func cleaned(_ name: String) -> String {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return value.isEmpty ? "自定义笔刷" : value
    }
}
