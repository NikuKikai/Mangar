import Foundation
import Metal

@MainActor
final class DocumentPreviewSource {
    let manifest: ProjectManifest
    let currentPage: PageRecord
    private let currentArchive: CanvasTileArchive
    private let store: ProjectStore
    private var compositor: MetalCanvasRenderer?
    private var compositorPageID: UUID?
    private var textures: [UUID: MTLTexture] = [:]
    private var usage: [UUID] = []
    private let budget = 64 * 1024 * 1024

    init(manifest: ProjectManifest, currentPage: PageRecord,
         currentArchive: CanvasTileArchive, store: ProjectStore) {
        self.manifest = manifest; self.currentPage = currentPage
        self.currentArchive = currentArchive; self.store = store
    }

    func regionTexture(bounds: CGRect) throws -> MTLTexture {
        if compositor == nil { compositor = try MetalCanvasRenderer(page: currentPage) }
        guard let compositor else { throw MetalCanvasRenderer.RendererError.exportFailed }
        if compositorPageID != currentPage.id {
            compositor.page = currentPage
            try compositor.restore(currentArchive)
            compositorPageID = currentPage.id
        }
        return try compositor.previewTexture(bounds: bounds, maxDimension: 1536)
    }

    func texture(for id: UUID) throws -> MTLTexture {
        usage.removeAll { $0 == id }; usage.append(id)
        if let texture = textures[id] { return texture }
        let (page, archive) = id == currentPage.id
            ? (currentPage, currentArchive) : try store.loadPageIndex(id)
        if compositor == nil { compositor = try MetalCanvasRenderer(page: page) }
        guard let compositor else { throw MetalCanvasRenderer.RendererError.exportFailed }
        compositor.page = page
        try compositor.restore(archive)
        compositorPageID = id
        let texture = try compositor.bookPreviewTexture()
        textures[id] = texture
        func bytes(_ t: MTLTexture) -> Int { t.width * t.height * 4 * 4 / 3 }
        while textures.values.reduce(0, { $0 + bytes($1) }) > budget, usage.count > 1 {
            textures.removeValue(forKey: usage.removeFirst())
        }
        return texture
    }
}
