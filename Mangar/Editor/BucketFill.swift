import Foundation

nonisolated struct BucketSettings: Codable, Equatable, Sendable {
    var tolerance: Double = 0.12
    /// Diameter of gaps to bridge, in canvas pixels.
    var closeGap: Int = 0
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "Mangar.tools.bucket.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.validated
    }
    var validated: Self { Self(tolerance: tolerance.isFinite ? min(1, max(0, tolerance)) : 0.12, closeGap: min(32, max(0, closeGap))) }
    func save() { if let data = try? JSONEncoder().encode(validated) { UserDefaults.standard.set(data, forKey: "Mangar.tools.bucket.v1") } }
}

nonisolated struct FillSpan: Codable, Equatable, Sendable {
    var y: Int
    var x0: Int
    var x1: Int // exclusive
}

/// Region is frozen as scanline runs, so replay does not re-read an altered reference.
struct BucketFillCommand: Codable {
    var layerID: UUID
    var spans: [FillSpan]
    var brush: BrushConfiguration
    var target: LayerEditTarget
    var erases: Bool
}

/// Discrete connectivity runs off the main thread on immutable sparse tile readback.
/// Raster compositing is performed by the same Metal kernel as lasso filling.
nonisolated enum BucketRegionResolver {
    nonisolated private final class Mask { var values = [UInt8](repeating: 0, count: 256 * 256) }
    static func resolve(width: Int, height: Int, x: Int, y: Int, target: LayerEditTarget,
                        source: [SelectionTileKey: Data], settings: BucketSettings,
                        selection: [SelectionTileKey: Data]? = nil, selectionDefault: UInt8 = 255) -> [FillSpan] {
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else { return [] }
        let channels = target == .mask ? 1 : 4
        let pixels = source.mapValues { [UInt8]($0) }
        let selected = selection?.mapValues { [UInt8]($0) }
        let fallback: [UInt8] = target == .mask ? [255] : [0, 0, 0, 0]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            guard let data = pixels[SelectionTileKey(x: x / 256, y: y / 256)] else { return fallback }
            let i = ((y % 256) * 256 + x % 256) * channels
            return Array(data[i..<i + channels])
        }
        let seed = pixel(x, y)
        let threshold = Int(settings.validated.tolerance * 255)
        func matches(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            if let selected, (selected[SelectionTileKey(x: x / 256, y: y / 256)]?[(y % 256) * 256 + x % 256] ?? selectionDefault) == 0 { return false }
            guard let data = pixels[SelectionTileKey(x: x / 256, y: y / 256)] else {
                return zip(seed, fallback).allSatisfy { abs(Int($0) - Int($1)) <= threshold }
            }
            let i = ((y % 256) * 256 + x % 256) * channels
            for c in 0..<channels where abs(Int(data[i + c]) - Int(seed[c])) > threshold { return false }
            return true
        }
        guard matches(x, y) else { return [] }
        if source.isEmpty && (selected == nil || (selected!.isEmpty && selectionDefault > 0)) {
            return (0..<height).map { FillSpan(y: $0, x0: 0, x1: width) }
        }
        let radius = (settings.validated.closeGap + 1) / 2
        var passable: [SelectionTileKey: [UInt8]] = [:]
        func allowedTile(_ key: SelectionTileKey) -> [UInt8] {
            if let cached = passable[key] { return cached }
            let side = 256 + 2 * radius
            // Separable max filter expands nonmatching barriers, bridging gaps.
            // Outside-canvas pixels do not grow a fictitious barrier at the page edge.
            var raw = [UInt8](repeating: 0, count: side * side)
            for ly in 0..<side { for lx in 0..<side {
                let px = key.x * 256 + lx - radius, py = key.y * 256 + ly - radius
                if px >= 0, py >= 0, px < width, py < height, !matches(px, py) { raw[ly * side + lx] = 1 }
            } }
            var horizontal = [UInt8](repeating: 0, count: side * 256)
            for ly in 0..<side {
                var sum = (0...2 * radius).reduce(0) { $0 + Int(raw[ly * side + $1]) }
                for lx in 0..<256 {
                    horizontal[ly * 256 + lx] = sum > 0 ? 1 : 0
                    if lx < 255 { sum += Int(raw[ly * side + lx + 2 * radius + 1]) - Int(raw[ly * side + lx]) }
                }
            }
            var out = [UInt8](repeating: 0, count: 256 * 256)
            for lx in 0..<256 {
                var sum = (0...2 * radius).reduce(0) { $0 + Int(horizontal[$1 * 256 + lx]) }
                for ly in 0..<256 {
                    let px = key.x * 256 + lx, py = key.y * 256 + ly
                    out[ly * 256 + lx] = sum == 0 && px < width && py < height ? 1 : 0
                    if ly < 255 { sum += Int(horizontal[(ly + 2 * radius + 1) * 256 + lx]) - Int(horizontal[ly * 256 + lx]) }
                }
            }
            passable[key] = out
            return out
        }
        var filled: [SelectionTileKey: Mask] = [:]
        func canVisit(_ px: Int, _ py: Int) -> Bool {
            guard px >= 0, py >= 0, px < width, py < height else { return false }
            let key = SelectionTileKey(x: px / 256, y: py / 256), i = (py % 256) * 256 + px % 256
            if filled[key]?.values[i] == 255 { return false }
            return allowedTile(key)[i] != 0
        }
        var start = (x, y)
        if !canVisit(x, y) {
            // A seed close to an edge can fall inside its dilation. Find nearby interior.
            var found = false
            for r in 1...max(1, radius + 1) {
                for dy in -r...r { for dx in -r...r where abs(dx) == r || abs(dy) == r {
                    if !found, canVisit(x + dx, y + dy) { start = (x + dx, y + dy); found = true }
                } }
                if found { break }
            }
            guard found else { return [] }
        }
        var work = [start]
        while let (sx, sy) = work.popLast() {
            guard canVisit(sx, sy) else { continue }
            var left = sx, right = sx
            while canVisit(left - 1, sy) { left -= 1 }
            while canVisit(right + 1, sy) { right += 1 }
            for px in left...right {
                let key = SelectionTileKey(x: px / 256, y: sy / 256)
                let mask = filled[key] ?? Mask(); filled[key] = mask
                mask.values[(sy % 256) * 256 + px % 256] = 255
            }
            for ny in [sy - 1, sy + 1] {
                var inRun = false
                for px in left...right {
                    let allowed = canVisit(px, ny)
                    if allowed && !inRun { work.append((px, ny)) }
                    inRun = allowed
                }
            }
        }
        if radius > 0 {
            // Recover the strip removed by barrier dilation without crossing a bridge.
            // Read the frozen interior; never let newly expanded pixels feed expansion.
            let interior = filled.mapValues { $0.values }
            for (key, values) in interior {
                for ly in 0..<256 { for lx in 0..<256 where values[ly * 256 + lx] != 0 {
                    var boundary = false
                    for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let px = key.x * 256 + lx + dx, py = key.y * 256 + ly + dy
                        if px >= 0, py >= 0, px < width, py < height,
                           interior[SelectionTileKey(x: px / 256, y: py / 256)]?[(py % 256) * 256 + px % 256] != 255 { boundary = true }
                    }
                    guard boundary else { continue }
                    for dy in -radius...radius { for dx in -radius...radius {
                        let px = key.x * 256 + lx + dx, py = key.y * 256 + ly + dy
                        guard matches(px, py) else { continue }
                        let dest = SelectionTileKey(x: px / 256, y: py / 256)
                        let mask = filled[dest] ?? Mask(); filled[dest] = mask
                        mask.values[(py % 256) * 256 + px % 256] = 255
                    } }
                } }
            }
        }
        var spans: [FillSpan] = []
        for key in filled.keys.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let values = filled[key]!.values
            for ly in 0..<min(256, height - key.y * 256) {
                var lx = 0
                while lx < min(256, width - key.x * 256) {
                    if values[ly * 256 + lx] == 0 { lx += 1; continue }
                    let first = lx
                    while lx < min(256, width - key.x * 256), values[ly * 256 + lx] != 0 { lx += 1 }
                    spans.append(FillSpan(y: key.y * 256 + ly, x0: key.x * 256 + first, x1: key.x * 256 + lx))
                }
            }
        }
        return spans
    }
}
