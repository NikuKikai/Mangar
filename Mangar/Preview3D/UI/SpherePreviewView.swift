import SwiftUI
import MetalKit

struct SpherePreviewView: View {
    @StateObject var controller: SpherePreviewController
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 26,height: 26) }
                    .accessibilityLabel(L10n.text("关闭三维预览"))
                Text(L10n.text("3D预览")).font(.system(size: 12))
                Text(controller.source.currentPage.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { controller.reset() } label: { Image(systemName: "arrow.counterclockwise").frame(width: 26,height: 26) }
                    .accessibilityLabel(L10n.text("重置三维视角"))
            }.padding(.horizontal,4).frame(height: 34).background(Color(white: 0.16))
            Rectangle().fill(.black).frame(height: 1)
            ZStack(alignment: .bottomLeading) {
                SpherePreviewSurface(controller: controller)
                if let error=controller.error {
                    VStack(alignment: .leading,spacing: 3) {
                        Text(error).foregroundStyle(.red)
                        Button(L10n.text("重试")) { controller.loadIfNeeded() }
                    }.font(.system(size: 11)).padding(8).background(.black.opacity(0.6))
                } else if controller.loading {
                    Text(L10n.text("正在生成页面贴图…")).font(.system(size: 11)).padding(8).background(.black.opacity(0.6))
                }
            }
        }.background(Color(white: 0.11)).buttonStyle(ImmediateButtonStyle())
            .onAppear { controller.loadIfNeeded() }.onDisappear { controller.close() }
    }
}
private struct SpherePreviewSurface: UIViewRepresentable {
    let controller: SpherePreviewController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> MTKView {
        let view=MTKView(frame: .zero,device: controller.renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor=MTLClearColorMake(0.09,0.10,0.11,1)
        view.isPaused=true; view.enableSetNeedsDisplay=true
        view.delegate=controller.renderer; controller.renderer.view=view
        let pan=UIPanGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.pan(_:)))
        let pinch=UIPinchGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.pinch(_:)))
        for gesture in [pan,pinch] { gesture.delegate=context.coordinator; view.addGestureRecognizer(gesture) }
        return view
    }
    func updateUIView(_ view: MTKView,context: Context) { view.setNeedsDisplay() }
    final class Coordinator: NSObject,UIGestureRecognizerDelegate {
        let controller: SpherePreviewController
        var lastTranslation=CGPoint.zero
        var baseZoom: CGFloat=1
        init(_ controller: SpherePreviewController) { self.controller=controller }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let translation=gesture.translation(in: gesture.view)
            if gesture.state == .began { lastTranslation = .zero }
            let renderer=controller.renderer
            let factor=renderer.surface.validRadius/max(1,renderer.diskRadius(in: gesture.view?.bounds.size ?? .zero))
            let center=CGPoint(x: renderer.center.x-(translation.x-lastTranslation.x)*factor,
                               y: renderer.center.y-(translation.y-lastTranslation.y)*factor)
            lastTranslation=translation
            controller.move(to: center)
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { baseZoom=controller.renderer.zoom }
            controller.renderer.zoom=max(0.25,min(4,baseZoom*gesture.scale))
            controller.renderer.invalidate()
        }
    }
}
