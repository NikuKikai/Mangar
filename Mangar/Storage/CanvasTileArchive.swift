import Foundation
import CoreGraphics

/// Owned immutable compressed files can be shared by checkpoints without retaining GPU pixels.
final class CanvasTileArchive {
    private let root: URL
    private(set) var files: [TileKey: URL] = [:]
    var bounds: [TileKey: CGRect] = [:]
    init() { root = FileManager.default.temporaryDirectory.appendingPathComponent("MangarTiles-" + UUID().uuidString, isDirectory: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func destination() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(UUID().uuidString + ".tile")
    }
    func put(_ pixels: Data, for key: TileKey) throws {
        let file = try destination()
        try TileCodec.encode(pixels).write(to: file, options: .atomic)
        remove(key); files[key] = file
    }
    func importFile(_ file: URL, for key: TileKey) throws {
        let target = try destination()
        do { try FileManager.default.linkItem(at:file,to:target) }
        catch { try FileManager.default.copyItem(at:file,to:target) }
        remove(key); files[key] = target
    }
    func read(_ key: TileKey) throws -> Data? { try files[key].map { try TileCodec.decode(Data(contentsOf: $0)) } }
    func remove(_ key: TileKey) {
        if let file = files.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }
        bounds.removeValue(forKey: key)
    }
    func clone() throws -> CanvasTileArchive {
        let copy = CanvasTileArchive()
        for (key,file) in files { try copy.importFile(file,for:key) }
        copy.bounds = bounds
        return copy
    }
}
