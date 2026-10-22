import Foundation
import CoreGraphics
import Metal

@MainActor
enum SpherePreviewChecks {
    static func run(device: MTLDevice,queue: MTLCommandQueue) throws {
        let surface=PageSurface(kind: .sphere,radius: 100)
        let finite=CanvasBoundary(width: 100,height: 80)
        let positive=CanvasBoundary(width: nil,height: nil,startsAtZeroX: true,startsAtZeroY: false)
        let negative=CanvasBoundary(width: -100,height: nil,startsAtZeroX: false,startsAtZeroY: true)
        precondition(finite.clampedPoint(CGPoint(x: -50,y: 500)) == CGPoint(x: 0,y: 80))
        precondition(finite.clampedPoint(CGPoint(x: 500,y: -50)) == CGPoint(x: 100,y: 0))
        precondition(finite.clampedPoint(CGPoint(x: 40,y: 30)) == CGPoint(x: 40,y: 30))
        precondition(positive.clampedPoint(CGPoint(x: -10,y: -500)) == CGPoint(x: 0,y: -500))
        precondition(positive.clampedPoint(CGPoint(x: 1e12,y: 1e12)) == CGPoint(x: 1e12,y: 1e12))
        precondition(negative.clampedPoint(CGPoint(x: -20,y: -500)) == CGPoint(x: -100,y: 0))
        precondition(negative.clampedPoint(CGPoint(x: -1e12,y: 500)) == CGPoint(x: -1e12,y: 500))
        let distant=CGPoint(x: -1e12,y: 1e12)
        precondition(CanvasBoundary.unlimited.clampedPoint(distant) == distant)
        for boundary in [finite,positive,negative,.unlimited] {
            precondition(PageRecord.blank(boundary: boundary,surface: surface).pageSurface == surface)
        }
        precondition(abs(surface.sourceRadius-50 * .pi)<0.00001)
        for angle in [0.0,Double.pi/4,Double.pi/2,Double.pi] {
            for t in [0.0,0.2,0.7,Double.pi/2] {
                let p=CGPoint(x: 100*sin(t)*cos(angle),y: 100*sin(t)*sin(angle))
                let v=surface.sourceOffset(projected: p)!
                precondition(abs(v.x-100*t*cos(angle))<0.0001 && abs(v.y-100*t*sin(angle))<0.0001)
            }
        }
        precondition(surface.sourceOffset(projected: CGPoint(x: 101,y: 0)) == nil)
        var page=PageRecord.blank(boundary: .unlimited,surface: surface)
        let decoded=try JSONDecoder().decode(PageRecord.self,from: JSONEncoder().encode(page))
        precondition(decoded.pageSurface == surface)
        let command=EditCommand.setPageSurface(surface)
        guard case .setPageSurface(let restored)=try JSONDecoder().decode(EditCommand.self,from: JSONEncoder().encode(command)) else { fatalError() }
        precondition(restored == surface)
        var manifest=ProjectManifest(pageIDs: [page.id],selectedPageID: page.id,purpose: .unrestricted,pageStructure: .cards)
        precondition(DocumentPreviewForm.resolve(manifest,page: page) == .sphere)
        page.surface = .normal
        precondition(DocumentPreviewForm.resolve(manifest,page: page) == nil)
        manifest.purpose = .book; manifest.pageStructure = .bookSpreads
        precondition(DocumentPreviewForm.resolve(manifest,page: page) == .book)
        print("PASS Sphere supports finite/one-sided/unbounded pages, independent axis movement limits, arc mapping and persistence")

        let center=CGPoint(x: -1_000_000_000_123,y: 1_000_000_000_321)
        let renderer=try MetalSphereRenderer(surface: surface,center: center)
        let radius=surface.sourceRadius*1.5
        renderer.patchBounds=CGRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2)
        let sourceDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: 512,height: 512,mipmapped: false)
        sourceDescriptor.usage = .shaderRead; sourceDescriptor.storageMode = .shared
        let image=device.makeTexture(descriptor: sourceDescriptor)!
        var input=[UInt8](repeating: 255,count: 512*512*4)
        for y in 0..<512 { for x in 0..<512 {
            let i=(y*512+x)*4
            input[i]=UInt8(x/2); input[i+1]=UInt8(y/2); input[i+2]=0
        } }
        image.replace(region: MTLRegionMake2D(0,0,512,512),mipmapLevel: 0,withBytes: input,bytesPerRow: 512*4)
        renderer.image=image
        let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 400,height: 400,mipmapped: false)
        outputDescriptor.storageMode = .shared; outputDescriptor.usage = [.renderTarget]
        let output=device.makeTexture(descriptor: outputDescriptor)!
        func draw(_ target: MetalSphereRenderer) -> [UInt8] {
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor: pass)!
            target.encode(encoder: encoder,size: CGSize(width: 400,height: 400))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            precondition(command.status == .completed)
            var bytes=[UInt8](repeating: 0,count: 400*400*4)
            output.getBytes(&bytes,bytesPerRow: 400*4,from: MTLRegionMake2D(0,0,400,400),mipmapLevel: 0)
            return bytes
        }
        let pixels=draw(renderer)
        func value(_ x: Int,_ y: Int,_ channel: Int) -> Int { Int(pixels[(y*400+x)*4+channel]) }
        precondition(value(0,0,3) == 0 && value(399,200,3) == 0)
        precondition(abs(value(200,200,2)-128)<=2 && abs(value(200,200,1)-128)<=2)
        for (x,y) in [(280,200),(350,200),(200,280),(200,350),(60,180)] {
            let projected=CGPoint(x: Double(x)+0.5-200,y: Double(y)+0.5-200)
            let local=CGPoint(x: projected.x/172*100,y: projected.y/172*100)
            let arc=surface.sourceOffset(projected: local)!
            let expectedX=Int(((arc.x+radius)/(2*radius))*256)
            let expectedY=Int(((arc.y+radius)/(2*radius))*256)
            precondition(abs(value(x,y,2)-expectedX)<=2 && abs(value(x,y,1)-expectedY)<=2)
        }
        renderer.center.x += radius*0.1
        let moved=draw(renderer)
        precondition(Int(moved[(200*400+200)*4+2]) > value(200,200,2)+10)
        print("PASS Production sphere shader preserves signed-coordinate precision, orientation, inverse arc distortion and disk clipping")
        let bounded=try MetalSphereRenderer(surface: surface,center: CGPoint(x: 50,y: 50),boundary: CanvasBoundary(width: 100,height: 100))
        bounded.patchBounds=CGRect(x: 50-radius,y: 50-radius,width: radius*2,height: radius*2)
        bounded.image=image
        let boundedPixels=draw(bounded)
        func alpha(_ pixels: [UInt8],_ x: Int,_ y: Int) -> UInt8 { pixels[(y*400+x)*4+3] }
        precondition(alpha(boundedPixels,200,200) == 255)
        precondition(alpha(boundedPixels,250,200) == 255 && alpha(boundedPixels,200,250) == 255)
        precondition(alpha(boundedPixels,300,200) == 0 && alpha(boundedPixels,100,200) == 0)
        precondition(alpha(boundedPixels,200,300) == 0 && alpha(boundedPixels,200,100) == 0)
        let halfPlane=try MetalSphereRenderer(surface: surface,center: .zero,boundary: positive)
        halfPlane.patchBounds=CGRect(x: -radius,y: -radius,width: radius*2,height: radius*2)
        halfPlane.image=image
        let halfPixels=draw(halfPlane)
        precondition(alpha(halfPixels,250,200) == 255 && alpha(halfPixels,150,200) == 0)
        precondition(alpha(halfPixels,250,100) == 255 && alpha(halfPixels,250,300) == 255)
        print("PASS Production sphere shader clips finite source edges and independently preserves infinite directions")
        for fill in SphereOutsideFill.allCases {
            var settings=surface
            settings.outsideFill=fill
            precondition(settings.normalized.outsideFill == fill)
            let restored=try JSONDecoder().decode(PageSurface.self,from: JSONEncoder().encode(settings))
            precondition(restored == settings)
            let filled=try MetalSphereRenderer(surface: settings,center: CGPoint(x: 50,y: 50),boundary: CanvasBoundary(width: 100,height: 100))
            filled.patchBounds=bounded.patchBounds; filled.image=image
            let filledPixels=draw(filled)
            let edgeIndex=(200*400+300)*4
            let expected=fill == .white ? [255,255,255,255] : fill == .black ? [0,0,0,255] : [0,0,0,0]
            for c in 0..<4 { precondition(Int(filledPixels[edgeIndex+c]) == expected[c]) }
            for c in 0..<4 { precondition(filledPixels[(200*400+200)*4+c] == boundedPixels[(200*400+200)*4+c]) }
            precondition(alpha(filledPixels,0,0) == 0)
        }
        let earlier=try JSONDecoder().decode(PageSurface.self,from: Data(#"{"kind":"sphere","radius":400}"#.utf8))
        precondition(earlier.outsideFill == .transparent && earlier.validRadius == 400)
        print("PASS Sphere outside fill persists, renders white/black/transparent, and preserves canvas content and disk clipping")
    }
    static func checkGuides(device: MTLDevice,queue: MTLCommandQueue,library: MTLLibrary) throws {
        struct Quad {
            var origin: SIMD2<Float>; var size: SIMD2<Float>
            var viewport = SIMD2<Float>(256,256)
            var zoom: Float; var rotation: Float
            var pan = SIMD2<Float>(128,128)
            var bounds = SIMD4<Float>(-.infinity,-.infinity,.infinity,.infinity)
        }
        struct Guide { var rect: SIMD4<Float>; var zoomAndPadding: SIMD4<Float>; var color = SIMD4<Float>(0.18,0.48,0.95,1) }
        let d=MTLRenderPipelineDescriptor()
        d.vertexFunction=library.makeFunction(name: "tileVertex")
        d.fragmentFunction=library.makeFunction(name: "pageGuideFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline=try device.makeRenderPipelineState(descriptor: d)
        let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 256,height: 256,mipmapped: false)
        td.storageMode = .shared; td.usage = [.renderTarget]
        let texture=device.makeTexture(descriptor: td)!
        for zoom: Float in [0.01,0.3,1,4] {
            for rotation: Float in [0,0.4,1.3] {
                let r: Float=60/zoom, padding: Float=2/zoom
                var quad=Quad(origin: SIMD2(repeating: -r-padding),size: SIMD2(repeating: 2*(r+padding)),zoom: zoom,rotation: rotation)
                var guide=Guide(rect: SIMD4(0,0,r,0),zoomAndPadding: SIMD4(zoom,1,0,0))
                let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
                pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
                let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&quad,length: MemoryLayout<Quad>.stride,index: 0)
                encoder.setFragmentBytes(&guide,length: MemoryLayout<Guide>.stride,index: 0)
                encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
                encoder.endEncoding();command.commit();command.waitUntilCompleted()
                precondition(command.status == .completed)
                var pixels=[UInt8](repeating: 0,count: 256*256*4)
                texture.getBytes(&pixels,bytesPerRow: 256*4,from: MTLRegionMake2D(0,0,256,256),mipmapLevel: 0)
                var count=0
                for y in 0..<256 { for x in 0..<256 where pixels[(y*256+x)*4+3]>0 {
                    count += 1
                    precondition(abs(hypot(Double(x)+0.5-128,Double(y)+0.5-128)-60)<0.81)
                } }
                precondition(count>550 && count<700)
                precondition(pixels[(128*256+188)*4+3] == 255)
            }
        }
        print("PASS Editor sphere guide retains its viewport center, blue content-guide style and screen line width under zoom and rotation")
    }

}
