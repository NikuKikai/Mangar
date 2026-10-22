import SwiftUI

struct CanvasNavigationPanel: View {
    @ObservedObject var session: EditorSession
    @State private var image: UIImage?
    @State private var bounds = CGRect(x:0,y:0,width:2048,height:2048)
    private var revision: String { "\(session.page.id)-\(session.historyRevision)-\(session.contentRevision)" }
    var body: some View {
        let _ = session.viewportRevision
        VStack(spacing:0) {
            HStack(spacing: CompactControlMetrics.buttonSpacing) {
                Text(L10n.text("导航")).font(.system(size:11,weight:.semibold))
                Text(verbatim:session.renderer.viewportZoomPercentage.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))+"%")
                    .font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width:60,alignment:.leading)
                    .accessibilityLabel(L10n.text("当前缩放率"))
                Spacer(minLength:0)
                if session.manifest.purpose == .book {
                    ScrubbableToggleButton(icon: "rectangle.on.rectangle",label: L10n.text("显示对页缩略图"),
                        isOn: session.showsFacingPage,value: session.facingPageOpacity) { on,opacity in
                            if session.showsFacingPage != on { session.showsFacingPage = on }
                            if session.facingPageOpacity != opacity { session.facingPageOpacity = opacity }
                        }
                        .compactIconTarget()
                        .disabled(session.facingPagePair == nil)
                        .help(L10n.text("对页缩略图；上下拖动调整不透明度"))
                }
                Button { session.showsRulers.toggle() } label: {
                    ControlSymbol(name: "ruler").compactIconTarget()
                        .foregroundStyle(session.showsRulers ? Color.accentColor : Color.primary)
                }
                .help(L10n.text("显示标尺"))
                .accessibilityLabel(L10n.text("显示标尺"))
                .accessibilityAddTraits(session.showsRulers ? [.isSelected] : [])
                Button { session.renderer.setNativeZoom() } label: { Text(verbatim:"1:1").font(.system(size:10,design:.monospaced)).compactIconTarget() }
                    .help(L10n.text("1:1 缩放（保持视口中心）"))
                    .accessibilityLabel(L10n.text("1:1 缩放（保持视口中心）"))
                Button { session.renderer.straightenViewport() } label: { ControlSymbol(name: "rotate.left").compactIconTarget() }
                    .help(L10n.text("画布回正（保持缩放与视口中心）"))
                    .accessibilityLabel(L10n.text("画布回正，保持缩放与视口中心"))
            }.padding(.horizontal,4).frame(height:26)
            GeometryReader { geometry in
                let frame = imageFrame(in:geometry.size)
                ZStack {
                    Color(red:0.10,green:0.11,blue:0.12)
                    if let image {
                        Image(uiImage:image).resizable().interpolation(.medium)
                            .frame(width:frame.width,height:frame.height).position(x:frame.midX,y:frame.midY)
                    }
                    Canvas { context,_ in
                        let points=session.renderer.viewportGeometry.canvasCorners.map { point in
                            CGPoint(x:frame.minX+(point.x-bounds.minX)/bounds.width*frame.width,y:frame.minY+(point.y-bounds.minY)/bounds.height*frame.height)
                        }
                        guard let first=points.first else { return }
                        var path=Path();path.move(to:first);for point in points.dropFirst() { path.addLine(to:point) };path.closeSubpath()
                        context.clip(to:Path(frame))
                        context.fill(path,with:.color(.accentColor.opacity(0.12)))
                        context.stroke(path,with:.color(.accentColor),lineWidth:1)
                    }.allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    let x=min(max(value.location.x,frame.minX),frame.maxX),y=min(max(value.location.y,frame.minY),frame.maxY)
                    session.renderer.centerViewport(on:CGPoint(x:bounds.minX+(x-frame.minX)/frame.width*bounds.width,y:bounds.minY+(y-frame.minY)/frame.height*bounds.height))
                })
            }.frame(height:132).padding(3)
        }
        .buttonStyle(ImmediateButtonStyle())
        .background(Color(red:0.15,green:0.16,blue:0.17))
        .task(id: session.bookPageReferenceRequest) { session.refreshBookPageReferences() }
        .task(id:revision) {
            do {
                session.renderer.prepareForReadback()
                let data=try session.renderer.navigationThumbnailPNG()
                bounds=session.renderer.navigationBounds
                image=UIImage(data:data)
            } catch { session.message=error.localizedDescription }
        }
    }
    private func imageFrame(in size:CGSize) -> CGRect {
        let scale=min(size.width/max(bounds.width,1),size.height/max(bounds.height,1))
        let width=bounds.width*scale,height=bounds.height*scale
        return CGRect(x:(size.width-width)/2,y:(size.height-height)/2,width:width,height:height)
    }
}
