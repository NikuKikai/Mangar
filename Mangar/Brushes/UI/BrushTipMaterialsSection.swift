import SwiftUI
import UniformTypeIdentifiers

/// Inline controls for the current brush's tip images.
struct BrushTipMaterialsSection: View {
    @Binding var brush: BrushConfiguration
    let importTips: ([URL], BrushTipChannel) -> Void
    let reportError: (String) -> Void
    @State private var importsTips = false
    @State private var channel: BrushTipChannel = .alpha

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("笔尖素材 · \(brush.stampSettings.assetIDs.count)/16")
                Spacer()
                Button("圆尖") { brush.stampSettings.assetIDs = [] }
            }.frame(height: 18)
            HStack(spacing: 3) {
                Text("导入通道").foregroundStyle(.secondary)
                ForEach(BrushTipChannel.allCases, id: \.self) { item in
                    Button { channel = item } label: {
                        Text(item.name).frame(maxWidth: .infinity).frame(height: 18)
                            .background(channel == item ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.2))
                    }
                }
                Button { importsTips = true } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .disabled(brush.stampSettings.assetIDs.count >= 16)
            }
            if !brush.stampSettings.assetIDs.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    let assets = (try? BrushResourceStore.shared.assets(for: brush)) ?? []
                    ForEach(Array(assets.enumerated()), id: \.offset) { index, asset in
                        VStack(spacing: 2) {
                            tipPreview(asset).frame(width: 42, height: 38).background(.black.opacity(0.3))
                            HStack(spacing: 0) {
                                Button { moveTip(index) } label: { Image(systemName: "chevron.left").frame(width: 14, height: 16) }
                                    .disabled(index == 0)
                                Text("\(index + 1)").frame(width: 14)
                                Button { brush.stampSettings.assetIDs.remove(at: index) } label: {
                                    Image(systemName: "xmark").frame(width: 14, height: 16)
                                }
                            }
                        }
                    }
                }
            }.frame(height: 60)
            }
            Text("图片保留原比例；大小以最长边计。硬度仅用于圆尖。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .fileImporter(isPresented: $importsTips, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importTips(urls, channel)
            case .failure(let error): reportError(error.localizedDescription)
            }
        }
    }
    private func moveTip(_ index: Int) {
        guard index > 0 else { return }
        brush.stampSettings.assetIDs.swapAt(index, index - 1)
    }
    @ViewBuilder private func tipPreview(_ asset: BrushTipAsset) -> some View {
        if let provider = CGDataProvider(data: asset.coverage as CFData),
           let image = CGImage(width: asset.width, height: asset.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: asset.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            Image(decorative: image, scale: 1).resizable().scaledToFit().padding(2)
        }
    }
}
