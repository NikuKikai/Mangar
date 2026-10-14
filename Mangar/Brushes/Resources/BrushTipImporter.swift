import Foundation
import CoreGraphics
import ImageIO

enum BrushTipChannel: String, CaseIterable {
    case alpha, darkness
    var name: String { self == .alpha ? L10n.text("透明度") : L10n.text("灰度（黑）") }
}
enum BrushTipImporter {
    static func load(_ url: URL, channel: BrushTipChannel) throws -> BrushTipAsset {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw BrushResourceError.invalidTip }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard rendered else { throw BrushResourceError.invalidTip }
        var coverage = Data(count: w * h)
        for i in 0..<(w * h) {
            let a = Int(rgba[i*4+3])
            let luminance = (Int(rgba[i*4])*54 + Int(rgba[i*4+1])*183 + Int(rgba[i*4+2])*19 + 128) / 256
            coverage[i] = UInt8(channel == .alpha ? a : max(0, a - luminance))
        }
        return try BrushTipAsset(width: w, height: h, coverage: coverage)
    }
}
