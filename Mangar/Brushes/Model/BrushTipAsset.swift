import Foundation
import CryptoKit

/// Immutable coverage. History retains the value, never a lookup in the current library.
struct BrushTipAsset: Codable, Equatable {
    let id: String
    let width: Int
    let height: Int
    let coverage: Data
    init(width: Int, height: Int, coverage: Data) throws {
        guard (1...1024).contains(width), (1...1024).contains(height),
              coverage.count == width * height, coverage.contains(where: { $0 != 0 }) else {
            throw BrushResourceError.invalidTip
        }
        self.width = width; self.height = height; self.coverage = coverage
        var bytes = Data("\(width)x\(height):".utf8); bytes.append(coverage)
        id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool { (try? Self(width: width, height: height, coverage: coverage).id) == id }
}
enum BrushResourceError: LocalizedError {
    case invalidTip, missingTip, invalidResource
    var errorDescription: String? {
        switch self {
        case .invalidTip: L10n.text("笔尖素材无效或完全透明（最长边上限 1024）。")
        case .missingTip: L10n.text("笔尖素材缺失或损坏，未开始绘画。")
        case .invalidResource: L10n.text("笔刷资源缺失或损坏。")
        }
    }
}
