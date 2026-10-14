import Foundation
import CoreGraphics

/// Query the smaller of the viewport's coordinate cells and the allocated tile set.
/// Empty world space does not add nodes to this index.
final class CanvasTileIndex {
    let keys: Set<TileKey>
    private var cells: [SelectionTileKey:Set<TileKey>] = [:]
    init(_ keys: Set<TileKey>) {
        self.keys = keys
        for key in keys { cells[SelectionTileKey(x:key.x,y:key.y),default:[]].insert(key) }
    }
    func query(_ rect: CGRect) -> Set<TileKey> {
        guard !rect.isNull, !rect.isEmpty else { return [] }
        let x0=Int(floor(rect.minX/256)),y0=Int(floor(rect.minY/256))
        let x1=Int(ceil(rect.maxX/256))-1,y1=Int(ceil(rect.maxY/256))-1
        let area=(Double(x1)-Double(x0)+1)*(Double(y1)-Double(y0)+1)
        if !area.isFinite || area > Double(keys.count) {
            return Set(keys.filter { CGRect(x:$0.x*256,y:$0.y*256,width:256,height:256).intersects(rect) })
        }
        var result:Set<TileKey> = []
        for y in y0...y1 { for x in x0...x1 { if let cell=cells[SelectionTileKey(x:x,y:y)] { result.formUnion(cell) } } }
        return result
    }
}
