import SwiftUI
import MetalKit

struct BookPreviewView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    @StateObject var controller: BookPreviewController
    let close: () -> Void
    @State private var pageInput = ""

    var body: some View {
        let _=language
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 26,height: 26) }
                    .accessibilityLabel(L10n.text("关闭三维预览"))
                Text(L10n.text("3D预览")).font(.system(size: 12))
                Text(controller.source.manifest.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                // Book arrangement currently reads right-to-left: left advances.
                Button { controller.jump(1) } label: { Image(systemName: "chevron.left").frame(width: 26,height: 26) }
                    .disabled(controller.opening+1 >= controller.count || controller.loading || controller.isTurning)
                    .accessibilityLabel(L10n.text("下一对开"))
                TextField("", text: $pageInput)
                    .textFieldStyle(.plain).multilineTextAlignment(.center)
                    .disabled(controller.isTurning)
                    .font(.system(size: 11)).monospacedDigit().frame(width: 30, height: 24)
                    .background(Color.white.opacity(0.08))
                    .accessibilityLabel(L10n.text("跳转到对开"))
                    .submitLabel(.go)
                    .onSubmit {
                        if let value = Int(pageInput) { controller.go(to: value - 1) }
                        pageInput = String(controller.opening + 1)
                    }
                Text(verbatim: "/ \(controller.count)")
                    .monospacedDigit().font(.system(size: 11))
                Button { controller.jump(-1) } label: { Image(systemName: "chevron.right").frame(width: 26,height: 26) }
                    .disabled(controller.opening == 0 || controller.loading || controller.isTurning)
                    .accessibilityLabel(L10n.text("上一对开"))
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1,height: 18)
                Text(L10n.text("书缝弯曲")).font(.system(size: 10)).foregroundStyle(.secondary)
                FlatSlider(value: Binding(get: { Double(controller.gutterCurvature) },
                                          set: { controller.setGutterCurvature(Float($0)) }),range: 0...0.4)
                    .frame(width: 70)
                Button { controller.reset() } label: { Image(systemName: "arrow.counterclockwise").frame(width: 26,height: 26) }
                    .accessibilityLabel(L10n.text("重置三维视角"))
            }
            .padding(.horizontal, 4).frame(height: 34).background(Color(white: 0.16))
            Rectangle().fill(.black).frame(height: 1)
            ZStack(alignment: .bottomLeading) {
                BookPreviewSurface(controller: controller)
                if controller.error != nil || controller.loading {
                VStack(alignment: .leading,spacing: 3) {
                    if let error=controller.error {
                        Text(error).foregroundStyle(.red)
                        Button(L10n.text("重试")) { controller.load() }
                    } else if controller.loading { Text(L10n.text("正在生成页面贴图…")) }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                    .background(Color.black.opacity(0.6))
                }
            }
        }
        .background(Color(white: 0.11)).buttonStyle(ImmediateButtonStyle())
        .onAppear { pageInput = String(controller.opening + 1); controller.load() }
        .onChange(of: controller.opening) { _, value in pageInput = String(value + 1) }
        .onDisappear { controller.close() }
    }
}

private struct BookPreviewSurface: UIViewRepresentable {
    let controller: BookPreviewController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> MTKView {
        let view=MTKView(frame: .zero,device: controller.renderer.device)
        view.colorPixelFormat = .bgra8Unorm; view.depthStencilPixelFormat = .depth32Float
        view.clearColor=MTLClearColorMake(0.09,0.10,0.11,1)
        view.isPaused=true; view.enableSetNeedsDisplay=true
        view.delegate=controller.renderer; controller.renderer.view=view
        // Keep one pan recognizer active as a second finger joins. Separate
        // competing one/two-finger recognizers let an early single pan win.
        let pan=UIPanGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches=2
        let pinch=UIPinchGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.pinch(_:)))
        for gesture in [pan,pinch] { gesture.delegate=context.coordinator; view.addGestureRecognizer(gesture) }
        return view
    }
    func updateUIView(_ view: MTKView,context: Context) { view.setNeedsDisplay() }
    final class Coordinator: NSObject,UIGestureRecognizerDelegate {
        let controller: BookPreviewController
        var baseZoom: Float=1
        var baseYaw: Float=0, basePitch: Float=0
        var orbiting=false
        var orbitOrigin=CGPoint.zero
        init(_ controller: BookPreviewController) { self.controller=controller }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let point=gesture.translation(in: gesture.view)
            if gesture.state == .began { orbiting=false }
            if gesture.numberOfTouches >= 2, !orbiting {
                controller.cancelDrag()
                orbiting=true; orbitOrigin=point
                baseYaw=controller.renderer.yaw; basePitch=controller.renderer.pitch
            }
            if orbiting {
                let p=CGPoint(x: point.x-orbitOrigin.x,y: point.y-orbitOrigin.y)
                controller.renderer.yaw=max(-1.05,min(1.05,baseYaw+Float(p.x)*0.005))
                controller.renderer.pitch=max(-1.05,min(0.65,basePitch+Float(p.y)*0.005))
                controller.renderer.view?.setNeedsDisplay()
            } else if gesture.state == .cancelled || gesture.state == .failed {
                controller.cancelDrag()
            } else {
                controller.drag(point.x,width: gesture.view?.bounds.width ?? 500,
                                finished: gesture.state == .ended)
            }
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { baseZoom=controller.renderer.zoom }
            controller.renderer.zoom=max(0.4,min(4,baseZoom*Float(gesture.scale)))
            controller.scale=controller.renderer.zoom; controller.renderer.view?.setNeedsDisplay()
        }
    }
}
