import Foundation
import CoreGraphics
import Combine

@MainActor
final class SpherePreviewController: ObservableObject {
    let source: DocumentPreviewSource
    let renderer: MetalSphereRenderer
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    private let initialCenter: CGPoint
    private var task: Task<Void,Never>?
    init(source: DocumentPreviewSource,center: CGPoint) throws {
        self.source=source
        let boundary=source.currentPage.boundary
        initialCenter=boundary.clampedPoint(center)
        renderer=try MetalSphereRenderer(surface: source.currentPage.pageSurface,center: initialCenter,boundary: boundary)
    }
    func move(to center: CGPoint) {
        guard center.x.isFinite,center.y.isFinite else { return }
        renderer.center=source.currentPage.boundary.clampedPoint(center); renderer.invalidate(); loadIfNeeded()
    }
    func reset() { renderer.zoom=1; move(to: initialCenter) }
    func loadIfNeeded() {
        let r=renderer.surface.sourceRadius
        let visible=CGRect(x: renderer.center.x-r,y: renderer.center.y-r,width: 2*r,height: 2*r)
        guard renderer.image == nil || !renderer.patchBounds.contains(visible) else { return }
        // One latest-position job: repeated input events cannot queue readbacks.
        guard task == nil else { return }
        task=Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled,let self else { return }
            defer { task=nil; loading=false }
            loading=true; error=nil
            let r=renderer.surface.sourceRadius*1.5
            let bounds=CGRect(x: renderer.center.x-r,y: renderer.center.y-r,width: 2*r,height: 2*r)
            do {
                let image=try source.regionTexture(bounds: bounds)
                renderer.patchBounds=bounds; renderer.image=image; renderer.invalidate()
            } catch { self.error=error.localizedDescription }
        }
    }
    func close() { task?.cancel(); task=nil; renderer.image=nil }
}
