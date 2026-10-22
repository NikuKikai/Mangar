import Foundation
import CoreGraphics
import Metal

@MainActor
enum PageRenderCacheChecks {
    static func run(device:MTLDevice) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("MangarPreviewCheck-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ProjectStore(root:root)
        var page=PageRecord.blank(width:37,height:29)
        let manifest=ProjectManifest(pageIDs:[page.id],selectedPageID:page.id)
        try store.save(manifest:manifest,page:page,changedTiles:[:],allTileKeys:[])
        let revision=try PageRenderCache.revision(root:root,pageID:page.id)
        let bounds=CGRect(x:0,y:0,width:37,height:29)
        let savedBounds=try store.previewBounds(page.id,region:.canvas)
        precondition(savedBounds == bounds)
        let pixels=Data([[UInt8]](repeating:[20,40,80,128],count:37*29).flatMap { $0 })
        let image=PageRenderImage(width:37,height:29,pixels:pixels)
        try PageRenderCache.write(image,bounds:bounds,region:.canvas,revision:revision,root:root,pageID:page.id)
        let cached=PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:revision,bounds:bounds)!
        precondition(cached.pixels == pixels && cached.width == 37 && cached.height == 29)
        precondition(PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:"old",bounds:bounds) == nil)
        precondition(PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:revision,bounds:bounds.offsetBy(dx:1,dy:0)) == nil)
        let texture=try PageRenderTexture.upload(cached,device:device,maxDimension:4096)
        let readback=try PageRenderTexture.read(texture,device:device)
        precondition(readback.pixels == pixels)
        let small=try PageRenderTexture.upload(cached,device:device,maxDimension:10)
        let smallPixels=try PageRenderTexture.read(small,device:device)
        precondition(small.width<=10 && small.height<=10)
        precondition(stride(from:3,to:smallPixels.pixels.count,by:4).allSatisfy { smallPixels.pixels[$0] == 128 })
        print("PASS Transparent preview cache preserves exact BGRA bytes, GPU readback alignment, alpha and bounded mip uploads")
        page.name="Changed"
        try store.save(manifest:manifest,page:page,changedTiles:[:],allTileKeys:[])
        let next=try PageRenderCache.revision(root:root,pageID:page.id)
        precondition(next != revision)
        precondition(PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:next,bounds:bounds) == nil)
        try PageRenderCache.write(image,bounds:bounds,region:.canvas,revision:next,root:root,pageID:page.id)
        try PageRenderCache.write(image,bounds:bounds,region:.canvas,revision:revision,root:root,pageID:page.id)
        precondition(PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:next,bounds:bounds) != nil)
        let file=root.appendingPathComponent("pages/\(page.id.uuidString)/previews/canvas.mgpreview")
        var corrupt=try Data(contentsOf:file);corrupt[corrupt.count-1] ^= 0xff
        try corrupt.write(to:file,options:.atomic)
        precondition(PageRenderCache.read(root:root,pageID:page.id,region:.canvas,revision:next,bounds:bounds) == nil)
        print("PASS Preview cache rejects changed revisions, bounds mismatches, stale writers and corrupt payloads without affecting page data")
    }
}
