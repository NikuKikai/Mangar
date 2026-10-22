import UIKit

/// Pixel dimensions shared by newly created pages and rendered page previews.
enum PageThumbnail {
    static let maximumDimension: CGFloat = 320

    static func geometry(for source: CGSize) -> (scale: CGFloat, pixelSize: CGSize) {
        let scale = min(maximumDimension / source.width, maximumDimension / source.height, 1)
        return (scale, CGSize(width: max(1, (source.width * scale).rounded()),
                              height: max(1, (source.height * scale).rounded())))
    }

    static func whitePNG(for source: CGSize) -> Data {
        let size = geometry(for: source).pixelSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
