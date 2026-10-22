import Foundation
import Metal
import CoreGraphics
import ImageIO

@MainActor
enum BookPreviewChecks {
    static func run(device: MTLDevice, queue: MTLCommandQueue) throws {
        let symmetryLibrary=try device.makeLibrary(source: BookShaders.source+"""

        kernel void turnSymmetryCheck(device float4 *out [[buffer(0)]],constant Uniforms *fixtures [[buffer(1)]],uint id [[thread_position_in_grid]]) {
            if (id >= 9) return;
            float t=0.2+float(id%3)*0.4;
            Surface forward=bookSurface(float2(t,0.5),fixtures[id*2]);
            Surface reverse=bookSurface(float2(t,0.5),fixtures[id*2+1]);
            out[id*4]=float4(forward.position,1); out[id*4+1]=float4(reverse.position,1);
            out[id*4+2]=float4(forward.normal,0); out[id*4+3]=float4(reverse.normal,0);
        }
        """,options: nil)
        let symmetryPipeline=try device.makeComputePipelineState(function: symmetryLibrary.makeFunction(name: "turnSymmetryCheck")!)
        let symmetryOutput=device.makeBuffer(length: 36*MemoryLayout<SIMD4<Float>>.stride,options: .storageModeShared)!
        var symmetryFixtures: [MetalBookRenderer.Uniforms]=[]
        for i in 0..<9 {
            let p: Float=0.15+Float(i/3)*0.35
            var fixture=MetalBookRenderer.Uniforms(pose: .zero,paper: SIMD4(-1,p,1.414,sin(p*Float.pi)*0.012),
                frontUV: .zero,backUV: .zero,stack: .zero,shape: SIMD4(0.22,1,0,0))
            symmetryFixtures.append(fixture)
            fixture.paper.y=1-p; fixture.shape.y = -1
            symmetryFixtures.append(fixture)
        }
        let symmetryInput=device.makeBuffer(bytes: symmetryFixtures,length: symmetryFixtures.count*MemoryLayout<MetalBookRenderer.Uniforms>.stride)!
        let symmetryCommand=queue.makeCommandBuffer()!, symmetryEncoder=symmetryCommand.makeComputeCommandEncoder()!
        symmetryEncoder.setComputePipelineState(symmetryPipeline)
        symmetryEncoder.setBuffer(symmetryOutput,offset: 0,index: 0)
        symmetryEncoder.setBuffer(symmetryInput,offset: 0,index: 1)
        symmetryEncoder.dispatchThreads(MTLSize(width: 9,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 9,height: 1,depth: 1))
        symmetryEncoder.endEncoding(); symmetryCommand.commit(); symmetryCommand.waitUntilCompleted()
        precondition(symmetryCommand.status == .completed)
        let symmetryValues=symmetryOutput.contents().bindMemory(to: SIMD4<Float>.self,capacity: 36)
        for i in 0..<9 {
            let f=symmetryValues[i*4], r=symmetryValues[i*4+1]
            let fn=symmetryValues[i*4+2], rn=symmetryValues[i*4+3]
            precondition(abs(f.x+r.x)<0.00001 && abs(f.y-r.y)<0.00001 && abs(f.z-r.z)<0.00001)
            precondition(abs(fn.x-rn.x)<0.00001 && abs(fn.z+rn.z)<0.00001)
        }
        print("PASS: opposite turn directions mirror GPU page curvature and surface normals")
        let bindingVertices=BookSpineMesh.vertices()
        var edges: [String:Int]=[:]
        func point(_ v: BookSpineVertex) -> String { "\(v.position.x),\(v.position.y),\(v.position.z)" }
        for i in stride(from: 0,to: bindingVertices.count,by: 3) {
            let triangle=(0..<3).map { point(bindingVertices[i+$0]) }
            for j in 0..<3 {
                let key=[triangle[j],triangle[(j+1)%3]].sorted().joined(separator: "|")
                edges[key,default: 0]+=1
            }
        }
        precondition(edges.values.allSatisfy { $0 == 2 })
        print("PASS: binding mesh is watertight across top, underside, walls and end caps")
        let forward=PageTurnTransition(start: 0.42,end: 1,startedAt: 10,destination: 2)
        precondition(abs(forward.value(at: 10)-0.42) < 0.00001)
        precondition(forward.value(at: 10+forward.duration/2) > 0.42)
        precondition(forward.value(at: 11) == 1 && forward.isComplete(at: 11))
        let cancel=PageTurnTransition(start: -0.25,end: 0,startedAt: 20,destination: nil)
        precondition(cancel.value(at: 20) == -0.25 && cancel.value(at: 21) == 0)
        precondition(cancel.value(at: 20+cancel.duration/2) > -0.25)
        print("PASS: page turn settlement preserves release position, completes and cancels smoothly")
        let a=UUID(), b=UUID(), spread=UUID()
        var manifest=ProjectManifest(name: "Test",pageIDs: [a,b],selectedPageID: a)
        let layout=BookPreviewLayout(manifest: manifest)
        precondition(layout.openings.count == 1)
        precondition(layout.openings[0].right.source == a && layout.openings[0].left.source == b)
        manifest.startingSide = .left
        manifest.pageIDs=[a,spread]; manifest.spreadPageIDs=[spread]
        let shifted=BookPreviewLayout(manifest: manifest)
        precondition(shifted.openings.count == 2 && shifted.openings[0].right.source == nil)
        precondition(shifted.openings[1].left.u1 == 0.5 && shifted.openings[1].right.u0 == 0.5)
        precondition(shifted.openings[1].left.source == spread && shifted.openings[1].right.source == spread)
        precondition(DocumentPreviewForm.resolve(manifest) != nil)
        manifest.purpose = .unrestricted
        precondition(DocumentPreviewForm.resolve(manifest) == nil)
        manifest.purpose = .book; manifest.pageStructure = .cards
        precondition(DocumentPreviewForm.resolve(manifest) == nil)
        print("PASS: book opening parity, blank faces, spread UV partition and presentation routing")

        // Execute the production shaders with different colored front/back sources.
        let renderer=try MetalBookRenderer(layout: shifted)
        renderer.pitch=0; renderer.yaw=0
        func solid(_ pixel: UInt32) -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: 1,height: 1,mipmapped: false)
            let t=device.makeTexture(descriptor: d)!
            var p=pixel
            t.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &p,bytesPerRow: 4)
            return t
        }
        renderer.images=[a:solid(0xff0000ff),spread:solid(0xffff0000)] // red vs blue
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 256,height: 192,mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .shared
        let color=device.makeTexture(descriptor: d)!
        d.pixelFormat = .depth32Float; d.storageMode = .private
        let depth=device.makeTexture(descriptor: d)!
        func render(_ turn: Float) -> [UInt8] {
            renderer.turn=turn
            let pass=MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture=color; pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth=1
            let command=queue.makeCommandBuffer()!
            renderer.encode(pass: pass,command: command,viewport: CGSize(width: 256,height: 192))
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            var bytes=[UInt8](repeating: 0,count: 256*192*4)
            color.getBytes(&bytes,bytesPerRow: 256*4,from: MTLRegionMake2D(0,0,256,192),mipmapLevel: 0)
            return bytes
        }
        let flat=render(0), curl=render(0.5), reverse=render(0.999)
        let left=(96*256+80)*4, right=(96*256+176)*4
        precondition(flat[left+2] > 160 && flat[left] < 10) // red first left page
        precondition(reverse[right] > 160 && reverse[right+2] < 10) // blue reverse sheet
        precondition(curl != flat && curl != reverse)
        print("PASS: Metal book mesh renders front/back faces, curved transition and depth")

        renderer.pitch = -0.24; renderer.yaw=0.2
        let nearEnd=render(0.99999)
        renderer.opening=1
        let settled=render(0)
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a,b).reduce(0) { $0+abs(Int($1.0)-Int($1.1)) })/Double(a.count)
        }
        if let path=ProcessInfo.processInfo.environment["MANGAR_PREVIEW_CHECK_IMAGE"] {
            writeImage(nearEnd,path: path+".before.png")
            writeImage(settled,path: path+".after.png")
        }
        precondition(difference(nearEnd,settled) < 1.5,"Endpoint difference: \(difference(nearEnd,settled))")
        let nearPrevious=render(-0.99999)
        renderer.opening=0
        let previous=render(0)
        precondition(difference(nearPrevious,previous) < 1.5)
        let cancelling=render(0.00001)
        precondition(difference(cancelling,previous) < 1.5)
        print("PASS: forward/backward settlement and cancel preserve neighboring page pixels")
        renderer.images=[:]; renderer.gutterCurvature=0
        let noGutter=render(0)
        renderer.gutterCurvature=0.32
        let curved=render(0)
        precondition(difference(noGutter,curved) > 0.5)
        renderer.yaw = -0.55
        let rotated=render(0)
        precondition(difference(curved,rotated) > 0.5)
        print("PASS: gutter parameter changes mesh/shadow output and fixed light responds to book rotation")
        // Project interior binding points into the camera. Each camera ray must
        // encounter opaque geometry, throughout both directions of a page turn.
        renderer.images=[:]
        let aspect: Float=256.0/192.0
        let fit=min(0.82*aspect,1.65/renderer.paperAspect)
        for curvature: Float in [0,0.4] {
            renderer.gutterCurvature=curvature
            for yaw: Float in [-0.95,0,0.95] { for pitch: Float in [-0.9,0.6] {
                renderer.yaw=yaw; renderer.pitch=pitch
                for direction: Float in [-1,1] {
                    renderer.opening=direction < 0 ? 1 : 0
                    for progress: Float in [0.001,0.25,0.5,0.75,0.999] {
                        let frame=render(direction*progress)
                        for fraction: Float in [-0.4,0,0.4] {
                            let x: Float = -0.01*sin(yaw), z: Float = -0.01*cos(yaw)
                            let y=fraction*renderer.paperAspect*cos(pitch)-z*sin(pitch)
                            let px=Int((x*fit/aspect*0.5+0.5)*256)
                            let py=Int((0.5-y*fit*0.5)*192)
                            precondition(frame[(py*256+px)*4+3] == 255,
                                         "Binding leak: curve \(curvature), yaw \(yaw), pitch \(pitch), turn \(direction*progress)")
                        }
                    }
                }
            }}
        }
        print("PASS: binding stays opaque across both turn directions, extreme poses and curvature limits")
        // No opaque placeholder may fill the silhouettes of real transparent
        // pages, including a blank facing slot and the underlying paper stack.
        let transparentManifest=ProjectManifest(pageIDs:[a,b,spread],selectedPageID:a)
        renderer.layout=BookPreviewLayout(manifest:transparentManifest)
        renderer.opening=0;renderer.pitch=0;renderer.yaw=0;renderer.gutterCurvature=0
        renderer.images=[a:solid(0),b:solid(0),spread:solid(0x80800000)]
        let backOnly=render(0)
        precondition(abs(Int(backOnly[left+3])-128)<=1 && backOnly[left]>70)
        precondition(backOnly[right+3] == 0)
        renderer.images[b]=solid(0x80000080)
        let mixed=render(0)
        precondition(abs(Int(mixed[left+3])-192)<=2)
        precondition(mixed[left+2]>70 && mixed[left]>30)
        renderer.images=[a:solid(0),b:solid(0),spread:solid(0)]
        let holes=render(0)
        precondition(holes[left+3] == 0 && holes[right+3] == 0)
        let nearTransparentEnd=render(0.99999)
        renderer.opening=1
        precondition(difference(nearTransparentEnd,render(0))<1.5)
        print("PASS: transparent book silhouettes, continuous alpha, opposite-face color and transparent turn settlement")
        renderer.layout=shifted;renderer.images=[:]
        renderer.opening=0; renderer.gutterCurvature=0.32
        if let path=ProcessInfo.processInfo.environment["MANGAR_PREVIEW_CHECK_IMAGE"] {
            renderer.yaw=0.28; renderer.pitch = -0.4
            let pixels=Data(render(0))
            writeImage(Array(pixels),path: path)
        }
    }
    private static func writeImage(_ pixels: [UInt8],path: String) {
        let provider=CGDataProvider(data: Data(pixels) as CFData)!
        let image=CGImage(width: 256,height: 192,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 256*4,
                          space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                          provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil)
        precondition(CGImageDestinationFinalize(destination))
    }

}
