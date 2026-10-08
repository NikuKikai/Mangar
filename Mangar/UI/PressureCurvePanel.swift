import SwiftUI

struct PressureCurvePanel: View {
    @Binding var curve: PressureCurve
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("全局压感曲线").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel("关闭压感曲线面板")
            }
            Text("输出压感").font(.system(size: 9)).foregroundStyle(.secondary)
            PressureCurveGraph(curve: $curve)
                .frame(height: 160)
                .padding(5)
            HStack {
                Text("0%"); Spacer(); Text("输入压感"); Spacer(); Text("100%")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                preset("线性", curve: .linear)
                preset("轻压", curve: .soft)
                preset("重压", curve: .firm)
            }
            Text("上下拖动控制点；设置立即生效并自动保存。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .buttonStyle(ImmediateButtonStyle())
        .padding(7)
        .frame(width: 258)
        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
        .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        .preferredColorScheme(.dark)
    }

    private func preset(_ title: String, curve preset: PressureCurve) -> some View {
        Button { curve = preset } label: {
            Text(title).font(.system(size: 10))
                .frame(maxWidth: .infinity).frame(height: 22)
                .background(curve == preset ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.10))
                .contentShape(Rectangle())
        }
    }
}

private struct PressureCurveGraph: View {
    @Binding var curve: PressureCurve
    @State private var draggingPoint: Int?

    var body: some View {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Canvas { context, size in
                        var grid = Path()
                        for index in 0...4 {
                            let x = CGFloat(index) * size.width / 4
                            let y = CGFloat(index) * size.height / 4
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
                        var reference = Path()
                        reference.move(to: CGPoint(x: 0, y: size.height))
                        reference.addLine(to: CGPoint(x: size.width, y: 0))
                        context.stroke(reference, with: .color(.white.opacity(0.25)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: CGFloat(1 - curve.outputs[0]) * size.height))
                        for index in 0..<4 {
                            let startX = CGFloat(index) * size.width / 4
                            let endX = CGFloat(index + 1) * size.width / 4
                            // Same cubic as PressureCurve.map, expressed as a Bezier path.
                            line.addCurve(
                                to: CGPoint(x: endX, y: CGFloat(1 - curve.outputs[index + 1]) * size.height),
                                control1: CGPoint(x: startX + size.width / 12,
                                    y: CGFloat(1 - curve.outputs[index] - curve.tangent(at: index) / 3) * size.height),
                                control2: CGPoint(x: endX - size.width / 12,
                                    y: CGFloat(1 - curve.outputs[index + 1] + curve.tangent(at: index + 1) / 3) * size.height))
                        }
                        context.stroke(line, with: .color(.accentColor), lineWidth: 2)
                    }
                    ForEach(0..<5) { index in
                        Circle().fill(draggingPoint == index ? Color.white : Color.accentColor)
                            .frame(width: 9, height: 9)
                            .position(x: CGFloat(index) * size.width / 4,
                                      y: CGFloat(1 - curve.outputs[index]) * size.height)
                    }
                }
                .background(Color.black.opacity(0.25))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let index = draggingPoint ?? min(4, max(0,
                            Int((gesture.startLocation.x / size.width * 4).rounded())))
                        draggingPoint = index
                        curve.movePoint(index, to: Double(1 - gesture.location.y / size.height))
                    }
                    .onEnded { _ in draggingPoint = nil })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("压感曲线，拖动控制点上下调整")
            }
    }
}
