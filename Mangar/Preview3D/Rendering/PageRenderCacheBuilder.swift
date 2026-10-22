import Foundation
import Metal

/// One renderer per pending saved page; pixels are compressed/written off the
/// main actor only after the authoritative document save has completed.
@MainActor
final class PageRenderCacheBuilder {
    static let shared = PageRenderCacheBuilder()
    private struct Job {
        var token: UUID
        var task: Task<Void,Never>
    }
    private var jobs: [URL:Job] = [:]

    func schedule(store: ProjectStore,pageID: UUID) {
        let key=store.root.appendingPathComponent(pageID.uuidString)
        jobs[key]?.task.cancel()
        let token=UUID()
        let task=Task { [weak self] in
            defer { if self?.jobs[key]?.token == token { self?.jobs.removeValue(forKey:key) } }
            do {
                await Task.yield();try Task.checkCancellation()
                let revision=try PageRenderCache.revision(root:store.root,pageID:pageID)
                let (page,archive)=try store.loadPageIndex(pageID)
                let renderer=try MetalCanvasRenderer(page:page)
                try renderer.restore(archive)
                let canvas=renderer.outputBounds()
                var regions:[(PageRenderRegion,CGRect)]=[(.canvas,canvas)]
                let sharesContent = page.contentRect == canvas
                if !sharesContent { regions.append((.content,page.contentRect)) }
                for (region,bounds) in regions {
                    await Task.yield();try Task.checkCancellation()
                    let texture=try renderer.previewTexture(bounds:bounds,maxDimension:Double(PageRenderCache.maximumDimension))
                    let image=try PageRenderTexture.read(texture,device:renderer.device)
                    let root=store.root
                    let write=Task.detached(priority:.utility) {
                        try PageRenderCache.write(image,bounds:bounds,region:region,revision:revision,root:root,pageID:pageID)
                        // Pages without a trim frame share identical pixels.
                        if region == .canvas && sharesContent {
                            try PageRenderCache.write(image,bounds:bounds,region:.content,revision:revision,root:root,pageID:pageID)
                        }
                    }
                    try await withTaskCancellationHandler { try await write.value } onCancel: { write.cancel() }
                }
            } catch {
                // Optional derived data: a failure must never turn a successful
                // document save into a failed save. Cache readers render afresh.
            }
        }
        jobs[key]=Job(token:token,task:task)
    }
}

