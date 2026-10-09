import Foundation

/// Bundled tips use the same immutable coverage model as imported tips.
enum BundledBrushTips {
    static let oilFlatID = "6683f9b9781a68c2729627ddbffb71f5578bfb1c62f6e7467b656c77832fc36f"
    /// Test runner supplies its source asset directory; the app loads its resource bundle.
    static var resourceDirectory: URL?
    static func load(_ id: String) throws -> BrushTipAsset? {
        guard id == oilFlatID else { return nil }
        let url = resourceDirectory?.appendingPathComponent("oil-flat-chisel.png") ??
            Bundle.main.url(forResource: "oil-flat-chisel", withExtension: "png")
        guard let url else { throw BrushResourceError.missingTip }
        let asset = try BrushTipImporter.load(url, channel: .darkness)
        guard asset.id == id else { throw BrushResourceError.invalidTip }
        return asset
    }
}
