import SwiftUI

struct BrushDynamicsPanel: View {
    @Binding var brush: BrushConfiguration
    let parameter: BrushParameter
    let close: () -> Void
    @State private var input: BrushDynamicInput = .pressure

    private var curve: Binding<BrushResponseCurve> {
        Binding(get: { brush.resolvedDynamics[parameter][input] },
                set: { brush.resolvedDynamics[parameter][input] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text("\(brush.preset.name) · \(parameter.name)动态").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 2)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 18) }
                    .accessibilityLabel("关闭动态曲线面板")
            }
            HStack(spacing: 2) {
                ForEach(BrushDynamicInput.allCases) { source in
                    Button { input = source } label: {
                        HStack(spacing: 3) {
                            Text(source.name)
                            if brush.resolvedDynamics[parameter][source].enabled {
                                Rectangle().fill(Color.accentColor).frame(width: 3, height: 3)
                            }
                        }.font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 19)
                            .background(input == source ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.2))
                    }
                }
            }
            HStack {
                Button { curve.wrappedValue.enabled.toggle() } label: {
                    Label("启用\(input.name)曲线", systemImage: curve.wrappedValue.enabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(curve.wrappedValue.enabled ? Color.accentColor : .white.opacity(0.75))
                }
                Spacer()
                Text("输出倍数").font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(height: 18)
            HStack(alignment: .top, spacing: 4) {
                VStack {
                    Text("\(Int(parameter.outputLimit))×")
                    Spacer(); Text("0×")
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 20)
                BrushResponseCurveGraph(curve: curve, limit: parameter.outputLimit)
                    .frame(height: 132).padding(4)
            }.frame(height: 140)
            HStack {
                Text(input == .pressure ? "轻" : input == .speed ? "慢" : "直立")
                Spacer(); Text(input.name); Spacer()
                Text(input == .pressure ? "重" : input == .speed ? "快" : "放平")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                preset("线性", outputs: [0, 0.25, 0.5, 0.75, 1])
                preset("反向", outputs: [1, 0.75, 0.5, 0.25, 0])
                preset("恒定", outputs: [1, 1, 1, 1, 1])
                Button {
                    curve.wrappedValue = MangaBrushes.dynamics(brush.preset)[parameter][input]
                } label: { Text("预设").font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 18) }
                    .background(Color.white.opacity(0.08))
            }
            Text("基础值 × 已开启曲线的乘积")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text(input == .speed ? "笔尖直径/秒；40 对应横轴中点。" :
                input == .tilt ? "直立为 0，放平为 1。" : "输入经过应用的全局压感曲线。")
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 12).lineLimit(1)
        }
        .buttonStyle(ImmediateButtonStyle()).padding(6).frame(width: 264)
        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
        .overlay(Rectangle().stroke(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }
    private func preset(_ title: String, outputs: [Double]) -> some View {
        Button { curve.wrappedValue.outputs = outputs } label: {
            Text(title).font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 18)
                .background(Color.white.opacity(0.08))
        }
    }
}

private struct BrushResponseCurveGraph: View {
    @Binding var curve: BrushResponseCurve
    let limit: Double
    @State private var draggingPoint: Int?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in draw(context, size: size) }
                ForEach(0..<5) { index in controlPoint(index, size: geometry.size) }
            }
            .background(Color.black.opacity(0.25)).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in updateDrag(value, size: geometry.size) }
                .onEnded { _ in draggingPoint = nil })
            .accessibilityLabel("动态曲线，拖动控制点调整倍数")
        }
    }

    private func controlPoint(_ index: Int, size: CGSize) -> some View {
        let color: Color = draggingPoint == index ? .white : curve.enabled ? .accentColor : .gray
        return Rectangle().fill(color).frame(width: 6, height: 6)
            .position(x: CGFloat(index) * size.width / 4,
                      y: CGFloat(1 - curve.outputs[index] / limit) * size.height)
    }
    private func updateDrag(_ value: DragGesture.Value, size: CGSize) {
        let fraction = value.startLocation.x / max(1, size.width)
        let index = draggingPoint ?? min(4, max(0, Int((fraction * 4).rounded())))
        draggingPoint = index
        curve.outputs[index] = min(limit, max(0, Double(1 - value.location.y / max(1, size.height)) * limit))
    }
    private func draw(_ context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for index in 0...4 {
            let x = CGFloat(index) * size.width / 4
            let y = CGFloat(index) * size.height / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)
        var reference = Path()
        let one = CGFloat(1 - 1 / limit) * size.height
        reference.move(to: CGPoint(x: 0, y: one)); reference.addLine(to: CGPoint(x: size.width, y: one))
        context.stroke(reference, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        var path = Path()
        var visible = curve; visible.enabled = true
        for index in 0...128 {
            let x = Double(index) / 128
            let point = CGPoint(x: CGFloat(x) * size.width, y: CGFloat(1 - visible.map(x) / limit) * size.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(curve.enabled ? .accentColor : .gray), lineWidth: 1.5)
    }
}
