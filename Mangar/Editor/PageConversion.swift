import Foundation
import CoreGraphics

struct ConvertedPage {
    var page: PageRecord
    var tiles: [TileKey: Data]
}

enum PageConversion {
    enum Failure: LocalizedError {
        case incompatible, tooLarge
        var errorDescription: String? {
            switch self {
            case .incompatible: "只能合并尺寸、分辨率和余量相同的两个单页。"
            case .tooLarge: "合并后的画布超出 16384 px 上限。"
            }
        }
    }

    static func merge(right: ConvertedPage, left: ConvertedPage) throws -> ConvertedPage {
        var rLayout = right.page.comicLayout
        var lLayout = left.page.comicLayout
        rLayout?.pageSpan = 1
        lLayout?.pageSpan = 1
        guard !right.page.isDoublePage, !left.page.isDoublePage,
              right.page.width == left.page.width, right.page.height == left.page.height,
              rLayout == lLayout else { throw Failure.incompatible }
        let content = Int(right.page.contentRect.width)
        let margin = Int(right.page.contentRect.minX)
        let width = right.page.width + content
        guard width <= 16384 else { throw Failure.tooLarge }
        rLayout?.pageSpan = 2
        var output = ConvertedPage(page: PageRecord(name: "对开页", width: width,
            height: right.page.height, comicLayout: rLayout, isSpread: true, layers: []), tiles: [:])
        append(left, clip: CGRect(x: 0, y: 0, width: margin + content, height: left.page.height),
               offset: 0, folder: "左页", to: &output)
        append(right, clip: CGRect(x: margin, y: 0, width: right.page.width - margin,
                                  height: right.page.height), offset: content, folder: "右页", to: &output)
        return output
    }

    static func split(_ source: ConvertedPage) -> [ConvertedPage] {
        var layout = source.page.comicLayout
        layout?.pageSpan = 1
        let content = Int(source.page.contentRect.width) / 2
        let width = source.page.width - content
        // Overlapping crops retain the artwork in the new inner margins.
        return [content, 0].map { origin in
            var output = ConvertedPage(page: PageRecord(name: origin == 0 ? "左页" : "右页",
                width: width, height: source.page.height, comicLayout: layout,
                isSpread: false, layers: []), tiles: [:])
            append(source, clip: CGRect(x: origin, y: 0, width: width, height: source.page.height),
                   offset: -origin, folder: nil, to: &output)
            return output
        }
    }

    private static func append(_ source: ConvertedPage, clip: CGRect, offset: Int,
                               folder: String?, to output: inout ConvertedPage) {
        let ids = Dictionary(uniqueKeysWithValues: source.page.layers.map { ($0.id, UUID()) })
        let group = folder.map { LayerRecord(name: $0, kind: .folder) }
        if let group { output.page.layers.append(group) }
        for original in source.page.layers {
            var layer = original
            layer.id = ids[original.id]!
            layer.parentID = original.parentID.flatMap { ids[$0] } ?? group?.id
            if original.kind == .solidWhite {
                let bounds = original.paperBounds ?? CGRect(x: 0, y: 0,
                                    width: source.page.width, height: source.page.height)
                let cropped = bounds.intersection(clip)
                layer.paperBounds = cropped.isNull ? .zero : cropped.offsetBy(dx: CGFloat(offset), dy: 0)
            }
            output.page.layers.append(layer)
        }
        let size = CanvasConstants.tileSize
        for (key, data) in source.tiles {
            guard let layerID = ids[key.layerID] else { continue }
            let intersection = CGRect(x: key.x * size, y: key.y * size, width: size, height: size)
                .intersection(clip)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            data.withUnsafeBytes { sourceBytes in
                for y in Int(intersection.minY)..<Int(intersection.maxY) {
                    var x = Int(intersection.minX)
                    while x < Int(intersection.maxX) {
                        let dx = x + offset
                        let destination = TileKey(layerID: layerID, x: dx / size, y: y / size)
                        let count = min(Int(intersection.maxX) - x, size - dx % size)
                        var tile = output.tiles.removeValue(forKey: destination) ?? Data(count: size * size * 4)
                        tile.withUnsafeMutableBytes { bytes in
                            bytes.baseAddress!.advanced(by: ((y % size) * size + dx % size) * 4)
                                .copyMemory(from: sourceBytes.baseAddress!.advanced(by:
                                    ((y - key.y * size) * size + x - key.x * size) * 4), byteCount: count * 4)
                        }
                        output.tiles[destination] = tile
                        x += count
                    }
                }
            }
        }
    }
}
