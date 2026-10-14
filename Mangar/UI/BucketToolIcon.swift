import SwiftUI

/// SF Symbols has no paint bucket; keep this vector icon consistent with the rail.
struct BucketToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 28
            context.scaleBy(x: scale, y: scale)
            var bucket = Path()
            bucket.move(to: CGPoint(x: 5, y: 12))
            bucket.addLine(to: CGPoint(x: 14, y: 3))
            bucket.addLine(to: CGPoint(x: 23, y: 12))
            bucket.addLine(to: CGPoint(x: 14, y: 21))
            bucket.closeSubpath()
            context.stroke(bucket, with: .foreground, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            var handle = Path()
            handle.move(to: CGPoint(x: 5, y: 12))
            handle.addCurve(to: CGPoint(x: 14, y: 3), control1: CGPoint(x: 0, y: 1), control2: CGPoint(x: 6, y: -2))
            context.stroke(handle, with: .foreground, lineWidth: 1.8)
            var paint = Path()
            paint.move(to: CGPoint(x: 7, y: 11)); paint.addLine(to: CGPoint(x: 22, y: 11))
            context.stroke(paint, with: .foreground, lineWidth: 1.8)
            var drop = Path()
            drop.move(to: CGPoint(x: 23, y: 15))
            drop.addCurve(to: CGPoint(x: 23, y: 26), control1: CGPoint(x: 16, y: 24), control2: CGPoint(x: 20, y: 26))
            drop.addCurve(to: CGPoint(x: 23, y: 15), control1: CGPoint(x: 29, y: 26), control2: CGPoint(x: 28, y: 23))
            context.fill(drop, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
