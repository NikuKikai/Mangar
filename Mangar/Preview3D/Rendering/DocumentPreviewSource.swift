import Foundation
import Metal

@MainActor
final class DocumentPreviewSource {
    let manifest: ProjectManifest
    let currentPage: PageRecord
    private let currentArchive: CanvasTileArchive?
    private let store: ProjectStore
    private var compositor: MetalCanvasRenderer?
    private var compositorPageID: UUID?
    typealias Region = PageRenderRegion
    private struct TextureKey: Hashable { var id: UUID; var region: Region; var dimension: Int }
    private var textures: [TextureKey: MTLTexture] = [:]
    private var usage: [TextureKey] = []
    private let budget = 64 * 1024 * 1024

    init(manifest: ProjectManifest, currentPage: PageRecord,
         currentArchive: CanvasTileArchive? = nil, store: ProjectStore) {
        self.manifest = manifest; self.currentPage = currentPage
        self.currentArchive = currentArchive; self.store = store
    }

    func regionTexture(bounds: CGRect) throws -> MTLTexture {
        if compositor == nil { compositor = try MetalCanvasRenderer(page: currentPage) }
        guard let compositor else { throw MetalCanvasRenderer.RendererError.exportFailed }
        if compositorPageID != currentPage.id {
            compositor.page = currentPage
            try compositor.restore(currentArchive ?? store.loadPageIndex(currentPage.id).1)
            compositorPageID = currentPage.id
        }
        return try compositor.previewTexture(bounds: bounds, maxDimension: 1536)
    }

    func pageRecord(for id: UUID) throws -> PageRecord {
        id == currentPage.id ? currentPage : try store.pageRecord(id)
    }

    func texture(for id: UUID, region: Region = .content, maxDimension: Int = 2048) throws -> MTLTexture {
        let key = TextureKey(id: id,region: region,dimension: maxDimension)
        usage.removeAll { $0 == key }; usage.append(key)
        if let texture = textures[key] { return texture }
        // An unsaved current-page snapshot always wins over disk-derived data.
        if !(id == currentPage.id && currentArchive != nil),
           let revision=try? PageRenderCache.revision(root:store.root,pageID:id),
           let bounds=try? store.previewBounds(id,region:region),
           maxDimension <= PageRenderCache.maximumDimension,
           let image=PageRenderCache.read(root:store.root,pageID:id,region:region,revision:revision,bounds:bounds),
           let device=MTLCreateSystemDefaultDevice(),
           let texture=try? PageRenderTexture.upload(image,device:device,maxDimension:maxDimension) {
            remember(texture,for:key)
            return texture
        }
        let page: PageRecord, archive: CanvasTileArchive
        if id == currentPage.id, let currentArchive { page=currentPage;archive=currentArchive }
        else { (page,archive)=try store.loadPageIndex(id) }
        if compositor == nil { compositor = try MetalCanvasRenderer(page: page) }
        guard let compositor else { throw MetalCanvasRenderer.RendererError.exportFailed }
        compositor.page = page
        try compositor.restore(archive)
        compositorPageID = id
        let bounds = region == .content ? page.contentRect : compositor.outputBounds()
        let texture = try compositor.previewTexture(bounds: bounds,maxDimension: Double(maxDimension))
        remember(texture,for:key)
        return texture
    }

    private func remember(_ texture:MTLTexture,for key:TextureKey) {
        textures[key] = texture
        func bytes(_ t: MTLTexture) -> Int { t.width * t.height * 4 * 4 / 3 }
        while textures.values.reduce(0, { $0 + bytes($1) }) > budget, usage.count > 1 {
            textures.removeValue(forKey: usage.removeFirst())
        }
    }
}
