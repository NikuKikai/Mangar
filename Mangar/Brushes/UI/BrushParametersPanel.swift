import SwiftUI

struct BrushParametersPanel: View {
    @Binding var brush: BrushConfiguration
    let brushName: String
    let importTips: ([URL], BrushTipChannel) -> Void
    let reportError: (String) -> Void
    let editDynamics: (BrushParameter) -> Void
    let close: () -> Void
    var maximumContentHeight: CGFloat = 540

    private var isInk: Bool { brush.definition.isSolidInk }
    private let labelWidth: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("\(brushName)参数").lineLimit(1).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 2)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 18) }
                    .accessibilityLabel("关闭画笔参数")
            }.frame(height: 20)
            ScrollView {
                controls
            }.frame(height: min(maximumContentHeight, contentHeight))
                .scrollBounceBehavior(.basedOnSize)

        }
        .buttonStyle(ImmediateButtonStyle())
        .padding(6).frame(width: 264)
        .background(Color(red: 0.17, green: 0.18, blue: 0.19))
        .overlay(Rectangle().stroke(Color.gray.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 6, x: 2, y: 3)
    }

    private var contentHeight: CGFloat {
        465 + (brush.stampSettings.assetIDs.isEmpty ? 0 : 63) +
            (brush.wetSettings.medium == .dry ? 0 : 92) +
            (brush.wetSettings.medium == .watercolor ? 60 : 0)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("笔刷大小", value: $brush.size, range: 1...2000, parameter: .size)
            row("不透明度", value: $brush.opacity, range: 0...1, parameter: .opacity)
            row(isInk ? "出墨量" : "流量", value: $brush.flow, range: 0...1, parameter: .flow)
            row("间距", value: $brush.spacing, range: 0.025...1)
            row("大小抖动", value: $brush.sizeJitter, range: 0...1)
            row(isInk ? "出墨抖动" : "流量抖动", value: $brush.opacityJitter, range: 0...1)
            row("位置抖动", value: $brush.positionJitter, range: 0...1)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
            choices("着墨方式", values: BrushDeposition.allCases,
                    selection: rendering(\.deposition), name: { $0.name })
            HStack(spacing: 3) {
                label("二值化")
                Button { brush.renderingSettings.binary.toggle() } label: {
                    Label("笔尖边缘", systemImage: brush.renderingSettings.binary ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(brush.renderingSettings.binary ? Color.accentColor : .white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                }
            }.frame(height: 18)
            row("硬度", value: tip(\.hardness), range: 0...1)
                .disabled(brush.renderingSettings.binary || !brush.stampSettings.assetIDs.isEmpty)
                .opacity(brush.renderingSettings.binary || !brush.stampSettings.assetIDs.isEmpty ? 0.4 : 1)
            row("纸纹", value: tip(\.grain), range: 0...1)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
            BrushTipMaterialsSection(brush: $brush, importTips: importTips, reportError: reportError)
            row("宽高比例", value: stamp(\.aspect), range: 0.1...4)
            row("笔尖角度", value: stamp(\.angle), range: -180...180)
            choices("旋转参考", values: BrushTipRotation.allCases, selection: stamp(\.rotation), name: { $0.name })
            choices("素材选择", values: BrushTipSequence.allCases, selection: stamp(\.sequence), name: { $0.name })
                .disabled(brush.stampSettings.assetIDs.count < 2)
            row("倾斜形状", value: tip(\.tiltElongation), range: 0...2)
            row("持续出墨", value: tip(\.timeRate), range: 0...240)
            row("停留扩墨", value: tip(\.pooling), range: 0...1)
            choices("累积模式", values: BrushAccumulation.allCases,
                    selection: rendering(\.accumulation), name: { $0.name })
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
            choices("媒介", values: BrushMedium.allCases, selection: wet(\.medium), name: { $0.name })
            if brush.wetSettings.medium != .dry {
                row("拾色量", value: wet(\.pickup), range: 0...1)
                row("混色强度", value: wet(\.mixing), range: 0...1)
                row("颜料量", value: wet(\.load), range: 0...1)
                row("携色距离", value: wet(\.persistence), range: 0...1)
                if brush.wetSettings.medium == .watercolor {
                    row("含水量", value: wet(\.dilution), range: 0...1)
                    row("颗粒强度", value: wet(\.granulation), range: 0...1)
                    row("边缘积色", value: wet(\.edgeDarkening), range: 0...1)
                }
                Text("拾取当前图层；颜料量为 0 时仅携色。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func wet<Value>(_ key: WritableKeyPath<BrushWetSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.wetSettings[keyPath: key] }, set: { brush.wetSettings[keyPath: key] = $0 })
    }
    private func stamp<Value>(_ key: WritableKeyPath<BrushStampSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.stampSettings[keyPath: key] }, set: { brush.stampSettings[keyPath: key] = $0 })
    }
    private func rendering<Value>(_ key: WritableKeyPath<BrushRenderingSettings, Value>) -> Binding<Value> {
        Binding(get: { brush.renderingSettings[keyPath: key] },
                set: { brush.renderingSettings[keyPath: key] = $0 })
    }
    private func choices<Value: Hashable>(_ title: String, values: [Value],
                                         selection: Binding<Value>, name: @escaping (Value) -> String) -> some View {
        HStack(spacing: 3) {
            label(title)
            HStack(spacing: 2) {
                ForEach(values, id: \.self) { value in
                    Button { selection.wrappedValue = value } label: {
                        Text(name(value)).font(.system(size: 10))
                            .frame(maxWidth: .infinity).frame(height: 16)
                            .background(selection.wrappedValue == value ? Color.accentColor.opacity(0.4) : Color.black.opacity(0.2))
                    }
                }
            }
        }.frame(height: 18)
    }
    private func tip(_ key: WritableKeyPath<BrushTipSettings, Double>) -> Binding<Double> {
        Binding(get: { brush.tipSettings[keyPath: key] }, set: { brush.tipSettings[keyPath: key] = $0 })
    }
    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.72))
            .frame(width: labelWidth, alignment: .leading)
    }
    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                     parameter: BrushParameter? = nil) -> some View {
        HStack(spacing: 3) {
            label(title)
            FlatSlider(value: value, range: range, logarithmic: parameter == .size)
            Text(parameter == .size ? "\(Int(value.wrappedValue.rounded()))" :
                value.wrappedValue.formatted(.number.precision(.fractionLength(range.upperBound > 5 ? 0 : 2))))
                .font(.system(size: 10, design: .monospaced)).frame(width: 34, alignment: .trailing)
            if let parameter {
                let enabled = brush.resolvedDynamics[parameter].isEnabled
                Button { editDynamics(parameter) } label: {
                    Image(systemName: "waveform.path").font(.system(size: 11))
                        .foregroundStyle(enabled ? Color.accentColor : .white.opacity(0.55))
                        .frame(width: 18, height: 16)
                        .background(enabled ? Color.accentColor.opacity(0.18) : .clear)
                }
                .accessibilityLabel("\(title)动态曲线")
                .accessibilityValue(enabled ? "已启用" : "未启用")
            } else { Color.clear.frame(width: 18, height: 16) }
        }.frame(height: 18)
    }
}
