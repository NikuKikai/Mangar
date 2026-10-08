import Foundation
import CoreGraphics
import Metal

/// Refines conservative scheduling bounds after GPU completion, outside the drawing hot path.
@MainActor
final class BrushChangeTracker {
    private struct Entry {
        var prior: CGRect
        var scheduled: CGRect
        var buffers: [MTLBuffer]
        var wasPresent: Bool
    }
    private var entries: [TileKey: Entry] = [:]

    func record(_ result: MetalBrushEngine.Result, tiles: [TileKey: MTLTexture], dirty: [TileKey: CGRect]) {
        for (key, buffer) in result.measuredBounds {
            let scheduled = (dirty[key] ?? .null).union(result.dirtyBounds[key] ?? .null)
            if var entry = entries[key], entry.scheduled == dirty[key] {
                entry.scheduled = scheduled
                entry.buffers.append(buffer)
                entries[key] = entry
            } else {
                entries[key] = Entry(prior: dirty[key] ?? .null, scheduled: scheduled,
                                     buffers: [buffer], wasPresent: tiles[key] != nil)
            }
        }
    }

    func invalidate(layerID: UUID? = nil) {
        if let layerID { entries = entries.filter { $0.key.layerID != layerID } }
        else { entries.removeAll() }
    }

    /// Caller must synchronize the shared GPU queue before reading these buffers.
    func resolve(tiles: inout [TileKey: MTLTexture], dirty: inout [TileKey: CGRect]) {
        for (key, entry) in entries where dirty[key] == entry.scheduled {
            var bounds = entry.prior
            for buffer in entry.buffers {
                let p = buffer.contents().bindMemory(to: UInt32.self, capacity: 4)
                if p[2] > p[0], p[3] > p[1] {
                    bounds = bounds.union(CGRect(x: key.x * CanvasConstants.tileSize + Int(p[0]),
                        y: key.y * CanvasConstants.tileSize + Int(p[1]),
                        width: Int(p[2] - p[0]), height: Int(p[3] - p[1])))
                }
            }
            if bounds.isNull {
                dirty.removeValue(forKey: key)
                if !entry.wasPresent { tiles.removeValue(forKey: key) }
            } else { dirty[key] = bounds }
        }
        entries.removeAll()
    }
}
