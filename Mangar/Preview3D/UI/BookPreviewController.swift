import UIKit
import Combine

@MainActor
private final class PageTurnDisplayTarget: NSObject {
    weak var controller: BookPreviewController?
    init(_ controller: BookPreviewController) { self.controller=controller }
    @objc func tick(_ link: CADisplayLink) { controller?.advanceTurn(at: link.timestamp) }
}

@MainActor
final class BookPreviewController: ObservableObject {
    let source: BookPreviewSource
    let renderer: MetalBookRenderer
    @Published var opening = 0
    @Published var loading = true
    @Published var error: String?
    @Published var scale: Float = 1
    @Published private(set) var gutterCurvature: Float = 0.22
    @Published private(set) var isTurning = false
    private var transition: PageTurnTransition?
    private var displayLink: CADisplayLink?
    private var task: Task<Void, Never>?
    private var ready: Set<Int> = []

    init(source: BookPreviewSource) throws {
        self.source=source
        let layout=BookPreviewLayout(manifest: source.manifest)
        renderer=try MetalBookRenderer(layout: layout)
        let rect=source.currentPage.contentRect
        renderer.paperAspect=Float(rect.height / (rect.width / (source.currentPage.isDoublePage ? 2 : 1)))
        opening=layout.openings.firstIndex { $0.left.source == source.currentPage.id || $0.right.source == source.currentPage.id } ?? 0
        renderer.opening=opening
    }
    var count: Int { renderer.layout.openings.count }
    func load() {
        task?.cancel()
        task=Task { [weak self] in
            guard let self else { return }
            loading=true; error=nil; ready=[]
            let indices=[opening,opening+1,opening-1].filter { $0 >= 0 && $0 < self.count }
            let ids=Set(indices.flatMap { [self.renderer.layout.openings[$0].left.source,self.renderer.layout.openings[$0].right.source].compactMap { $0 } })
            renderer.images=renderer.images.filter { ids.contains($0.key) }
            defer { if !Task.isCancelled { loading=false } }
            do {
                for index in indices {
                    let faces=renderer.layout.openings[index]
                    for id in [faces.left.source,faces.right.source].compactMap({ $0 }) {
                        try Task.checkCancellation()
                        await Task.yield()
                        try Task.checkCancellation()
                        renderer.images[id]=try source.texture(for: id)
                    }
                    ready.insert(index)
                    renderer.view?.setNeedsDisplay()
                }
            } catch is CancellationError { } catch { self.error=error.localizedDescription }
        }
    }
    func close() {
        task?.cancel(); task=nil; displayLink?.invalidate(); displayLink=nil
        transition=nil; isTurning=false; renderer.images=[:]
    }
    func jump(_ delta: Int) {
        let target=opening+delta
        guard !isTurning, ready.contains(opening),ready.contains(target) else { return }
        animate(to: delta > 0 ? 1 : -1, destination: target)
    }
    func go(to index: Int) {
        let next=min(max(0,index),max(0,count-1))
        guard next != opening, !isTurning else { return }
        opening=next; renderer.opening=next; renderer.turn=0
        renderer.view?.setNeedsDisplay(); load()
    }
    func drag(_ distance: CGFloat, width: CGFloat, finished: Bool) {
        guard !isTurning else { return }
        let p=Float(distance / max(100,width*0.55))
        let target=opening+(p > 0 ? 1 : -1)
        guard ready.contains(opening),ready.contains(target) else {
            if finished { cancelDrag() }
            else { renderer.turn=0; renderer.view?.setNeedsDisplay() }
            return
        }
        renderer.turn=max(-0.999,min(0.999,p))
        if finished {
            let advance=abs(p)>0.3
            animate(to: advance ? (p > 0 ? 1 : -1) : 0,
                    destination: advance ? target : nil)
        }
        renderer.view?.setNeedsDisplay()
    }
    func cancelDrag() {
        guard !isTurning,renderer.turn != 0 else { return }
        animate(to: 0,destination: nil)
    }
    private func animate(to end: Float,destination: Int?) {
        transition=PageTurnTransition(start: renderer.turn,end: end,
                                      startedAt: CACurrentMediaTime(),destination: destination)
        isTurning=true
        let link=CADisplayLink(target: PageTurnDisplayTarget(self),selector: #selector(PageTurnDisplayTarget.tick(_:)))
        link.add(to: .main,forMode: .common); displayLink=link
    }
    fileprivate func advanceTurn(at time: Double) {
        guard let transition else { return }
        renderer.turn=transition.value(at: time)
        if transition.isComplete(at: time) {
            displayLink?.invalidate(); displayLink=nil; self.transition=nil; isTurning=false
            renderer.turn=0
            if let destination=transition.destination {
                opening=destination; renderer.opening=destination; load()
            }
        }
        renderer.view?.setNeedsDisplay()
    }
    func setGutterCurvature(_ value: Float) {
        gutterCurvature=max(0,min(0.4,value)); renderer.gutterCurvature=gutterCurvature
        renderer.view?.setNeedsDisplay()
    }
    func reset() {
        renderer.yaw=0; renderer.pitch = -0.24; renderer.zoom=1; scale=1
        renderer.view?.setNeedsDisplay()
    }
}
