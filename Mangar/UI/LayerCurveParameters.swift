import SwiftUI

struct LayerCurveParameters: View {
    @ObservedObject var session: EditorSession
    let close: () -> Void
    @State private var channel: LayerCurveEffect.Channel = .master
    private var curve: Binding<BrushResponseCurve> {
        Binding(get: {
            let effect = session.selectedLayer?.curves ?? LayerCurveEffect(isEnabled: false)
            return BrushResponseCurve(enabled: effect.isEnabled, outputs: effect[channel])
        }, set: { session.previewLayerCurve(channel: channel, values: $0.outputs) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("曲线调整").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 18) }
                    .accessibilityLabel("关闭曲线参数区")
            }
            HStack(spacing: 2) {
                ForEach(LayerCurveEffect.Channel.allCases, id: \.self) { value in
                    Button { session.endLayerPropertyEdit(); channel = value } label: {
                        Text(value.name).font(.system(size: 10)).frame(maxWidth: .infinity).frame(height: 18)
                            .background(channel == value ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.06))
                    }
                }
            }
            if let layer = session.selectedLayer {
                BrushResponseCurveGraph(curve: curve, limit: 1,
                    begin: { session.beginLayerPropertyEdit(layer.id) },
                    end: { session.endLayerPropertyEdit() })
                    .frame(height: 126).padding(3)
                    .disabled(layer.curves?.isEnabled != true)
                HStack {
                    Text("输入 → 输出").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重置通道") {
                        session.beginLayerPropertyEdit(layer.id)
                        session.previewLayerCurve(channel: channel, values: [0, 0.25, 0.5, 0.75, 1])
                        session.endLayerPropertyEdit()
                    }.font(.system(size: 9)).disabled(layer.curves?.isEnabled != true)
                }.frame(height: 18)
            }
        }
        .buttonStyle(ImmediateButtonStyle()).padding(4)
        .background(Color(red: 0.18, green: 0.19, blue: 0.20))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
        .onDisappear { session.endLayerPropertyEdit() }
    }
}
