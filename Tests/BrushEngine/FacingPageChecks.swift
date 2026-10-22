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
        print("PASS Facing-page shader overlays content inside/outside the current canvas and applies premultiplied opacity once")
    }
}
