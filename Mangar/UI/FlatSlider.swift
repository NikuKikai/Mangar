import SwiftUI

struct FlatSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logarithmic = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let useLog = logarithmic && range.lowerBound > 0
            let fraction = min(1, max(0, useLog ?
                log(max(range.lowerBound, value) / range.lowerBound) / log(range.upperBound / range.lowerBound) :
                (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(red: 0.09, green: 0.10, blue: 0.11))
                    .frame(height: 5)
                Rectangle()
                    .fill(Color(red: 0.39, green: 0.58, blue: 0.77))
                    .frame(width: width * fraction, height: 5)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 7)
                    .offset(x: min(width - 2, max(0, width * fraction - 1)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let fraction = min(1, max(0, gesture.location.x / width))
                value = useLog ? range.lowerBound * pow(range.upperBound / range.lowerBound, fraction) :
                    range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}
