import Foundation
import CoreGraphics
import Metal

@MainActor
enum FacingPageChecks {
    static func run(device: MTLDevice,queue: MTLCommandQueue,library: MTLLibrary) throws {
        let layout = ComicPageLayout(contentWidthMM: 100,contentHeightMM: 150,dpi: 254,marginMM: 10,verticalMarginMM: 20)
        var lowDPI = layout; lowDPI.dpi = 127
        let a = PageRecord.blank(width: layout.canvasWidthPixels,height: layout.canvasHeightPixels,comicLayout: layout)
        let b = PageRecord.blank(width: lowDPI.canvasWidthPixels,height: lowDPI.canvasHeightPixels,comicLayout: lowDPI)
        let c = PageRecord.blank(width: a.width,height: a.height,comicLayout: layout)
        var manifest = ProjectManifest(pageIDs: [a.id,b.id,c.id],selectedPageID: a.id)
        let pair = FacingPagePair.resolve(manifest: manifest,page: a)!
        precondition(pair.partnerID == b.id && pair.partnerIsLeft)
        let left = pair.destinationRect(current: a,partner: b)
        precondition(left == CGRect(x: -1000,y: 0,width: 1200,height: 1900))
        precondition(left.intersection(CGRect(x: 0,y: 0,width: a.width,height: a.height)).width == 200)
        let reverse = FacingPagePair.resolve(manifest: manifest,page: b)!
        precondition(reverse.partnerID == a.id && !reverse.partnerIsLeft)
        let right = reverse.destinationRect(current: b,partner: a)
        precondition(right == CGRect(x: 500,y: 0,width: 600,height: 950))
        precondition(FacingPagePair.resolve(manifest: manifest,page: c) == nil)
        manifest.startingSide = .left
        precondition(FacingPagePair.resolve(manifest: manifest,page: a) == nil)
        precondition(FacingPagePair.resolve(manifest: manifest,page: b)?.partnerID == c.id)
        manifest.pageStructure = .cards
        precondition(FacingPagePair.resolve(manifest: manifest,page: b) == nil)
        manifest.pageStructure = .bookSpreads; manifest.purpose = .unrestricted
        precondition(FacingPagePair.resolve(manifest: manifest,page: b) == nil)
        manifest.purpose = .book; manifest.startingSide = .right
        var spread = c; spread.isSpread = true
        manifest.pageIDs = [a.id,spread.id]; manifest.spreadPageIDs = [spread.id]
        precondition(FacingPagePair.resolve(manifest: manifest,page: a) == nil)
        precondition(FacingPagePair.resolve(manifest: manifest,page: spread) == nil)
        print("PASS Facing-page pairs follow book arrangement, skip gaps/spreads, align trim edges and scale different DPI physically")

        manifest.pageIDs=[a.id,b.id,c.id];manifest.spreadPageIDs=[]
        let book=BookPreviewLayout(manifest:manifest)
        let back=book.references(manifest:manifest,page:b)!
        precondition(back.reverses.count == 1 && back.reverses[0].reverse.source == c.id)
        precondition(book.references(manifest:manifest,page:a)!.reverses.isEmpty)
        let dPage=PageRecord.blank(width:a.width,height:a.height,comicLayout:layout)
        manifest.pageIDs=[a.id,b.id,spread.id,dPage.id];manifest.spreadPageIDs=[spread.id]
        let spreadBack=BookPreviewLayout(manifest:manifest).references(manifest:manifest,page:spread)!
        precondition(spreadBack.reverses.count == 2)
        precondition(Set(spreadBack.reverses.compactMap { $0.reverse.source }) == [b.id,dPage.id])
        print("PASS Reverse-page topology follows physical sheet backs, including two different backs of a spread")
        let alphaDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:2,height:1,mipmapped:false)
        let alphaImage=device.makeTexture(descriptor:alphaDescriptor)!
        let alphaBytes:[UInt8]=[0,0,0,0,64,32,16,128]
        alphaImage.replace(region:MTLRegionMake2D(0,0,2,1),mipmapLevel:0,withBytes:alphaBytes,bytesPerRow:8)
        let alphaTiles=try PageReferenceCoverage.capture([
            PageReferenceTexture(rect:CGRect(x:0,y:0,width:512,height:256),texture:alphaImage,uv:SIMD2(1,0))
        ],device:device,boundary:CanvasBoundary(width:512,height:256))
        precondition(!alphaTiles.isEmpty)
        let opaqueSide=alphaTiles.first { $0.x == 0 }!
        let captured=try TileCodec.decode(opaqueSide.pixels!)
        precondition(captured[128*256+10] == 128)
        precondition(captured[128*256+250] > 60 && captured[128*256+250] < 75)
        let roundTrip=try JSONDecoder().decode(SelectionCommand.self,from:JSONEncoder().encode(SelectionCommand.coverage(alphaTiles)))
        guard case .coverage(let restored)=roundTrip else { preconditionFailure() }
        precondition(restored.count == alphaTiles.count && restored[0].pixels == alphaTiles[0].pixels)
        let fullImage=device.makeTexture(descriptor:MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false))!
        var fullPixel:UInt32=0xffffffff
        fullImage.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&fullPixel,bytesPerRow:4)
        let fullTiles=try PageReferenceCoverage.capture([PageReferenceTexture(rect:CGRect(x:0,y:0,width:256,height:256),texture:fullImage)],device:device,boundary:CanvasBoundary(width:256,height:256))
        precondition(fullTiles.count == 1 && fullTiles[0].pixels == nil)
        print("PASS Reverse alpha selection mirrors continuous coverage, compresses replay data and represents full tiles with flags")

        struct Quad {
            var origin = SIMD2<Float>(-32,0), size = SIMD2<Float>(64,64)
            var viewport = SIMD2<Float>(64,64)
            var zoom: Float = 1, rotation: Float = 0
            var pan = SIMD2<Float>(32,0)
            var clip = SIMD4<Float>(0,0,32,64)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "tileVertex")
        d.fragmentFunction = library.makeFunction(name: "facingPageFragment")
        let blend = d.colorAttachments[0]!
        blend.pixelFormat = .bgra8Unorm; blend.isBlendingEnabled = true
        blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one; blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: d)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: 2,height: 2,mipmapped: false)
        inputDescriptor.storageMode = .shared; inputDescriptor.usage = .shaderRead
        let input = device.makeTexture(descriptor: inputDescriptor)!
        let data = [[UInt8]](repeating: [100,50,25,128],count: 4).flatMap { $0 }
        input.replace(region: MTLRegionMake2D(0,0,2,2),mipmapLevel: 0,withBytes: data,bytesPerRow: 8)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 64,height: 64,mipmapped: false)
        outputDescriptor.storageMode = .shared; outputDescriptor.usage = .renderTarget
        let output = device.makeTexture(descriptor: outputDescriptor)!
        for opacityValue: Float in [0,0.5,1] {
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2,0.2,0.2,1)
            let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            var quad = Quad(), opacity = opacityValue
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&quad,length: MemoryLayout<Quad>.stride,index: 0)
            encoder.setFragmentBytes(&opacity,length: MemoryLayout<Float>.stride,index: 0)
            encoder.setFragmentTexture(input,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            var pixels = [UInt8](repeating: 0,count: 64*64*4)
            output.getBytes(&pixels,bytesPerRow: 64*4,from: MTLRegionMake2D(0,0,64,64),mipmapLevel: 0)
            let remainder = 51*(1-Float(128)/255*opacityValue)
            let expected = [Float(25)*opacityValue+remainder,Float(50)*opacityValue+remainder,Float(100)*opacityValue+remainder,255]
            for x in [3,60] { for c in 0..<4 {
                precondition(abs(Float(pixels[(32*64+x)*4+c])-expected[c]) <= 2)
            } }
        }
        d.fragmentFunction=library.makeFunction(name:"reversePageFragment")
        let reversePipeline=try device.makeRenderPipelineState(descriptor:d)
        for tint:Float in [0,1] {
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:pass)!
            var quad=Quad(),settings=SIMD4<Float>(1,0,tint,0)
            encoder.setRenderPipelineState(reversePipeline)
            encoder.setVertexBytes(&quad,length:MemoryLayout<Quad>.stride,index:0)
            encoder.setFragmentBytes(&settings,length:16,index:0);encoder.setFragmentTexture(input,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            precondition(command.status == .completed)
            var pixels=[UInt8](repeating:0,count:64*64*4)
            output.getBytes(&pixels,bytesPerRow:256,from:MTLRegionMake2D(0,0,64,64),mipmapLevel:0)
            let p=(32*64+32)*4
            precondition(pixels[p+3] == 128)
            if tint == 0 { precondition(pixels[p] == 25 && pixels[p+2] == 100) }
            else { precondition(abs(Int(pixels[p+2])-109)<=1 && abs(Int(pixels[p+1])-45)<=1) }
        }
        print("PASS Reverse reference color/tint shader preserves continuous alpha and premultiplied color")
        print("PASS Facing-page shader overlays content inside/outside the current canvas and applies premultiplied opacity once")
    }
}
