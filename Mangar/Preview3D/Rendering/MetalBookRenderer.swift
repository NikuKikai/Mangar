import MetalKit
import simd

@MainActor
final class MetalBookRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var pose: SIMD4<Float>
        var paper: SIMD4<Float>
        var frontUV: SIMD4<Float>
        var backUV: SIMD4<Float>
        var stack: SIMD4<Float>
        var shape: SIMD4<Float>
    }
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let spinePipeline: MTLRenderPipelineState
    private let spineShadowPipeline: MTLRenderPipelineState
    private let spineMesh: MTLBuffer
    private let spineVertexCount: Int
    private let shadowMap: MTLTexture
    private let depthState: MTLDepthStencilState
    private let mesh: MTLBuffer
    private let vertexCount: Int
    private let white: MTLTexture
    weak var view: MTKView?
    var layout: BookPreviewLayout
    var images: [UUID: MTLTexture] = [:]
    var opening = 0
    /// RTL forward: left sheet turns over onto the right of the next opening.
    var turn: Float = 0
    var yaw: Float = 0
    var pitch: Float = -0.24
    var zoom: Float = 1
    var paperAspect: Float = 1.414
    var gutterCurvature: Float = 0.22

    init(layout: BookPreviewLayout) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DocumentPreviewRenderingError.unavailable
        }
        self.device=device; self.queue=queue; self.layout=layout
        let library = try device.makeLibrary(source: BookShaders.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "bookVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bookFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction=library.makeFunction(name: "bookSpineVertex")
        spinePipeline=try device.makeRenderPipelineState(descriptor: descriptor)
        let shadowDescriptor=MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction=library.makeFunction(name: "bookShadowVertex")
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline=try device.makeRenderPipelineState(descriptor: shadowDescriptor)
        shadowDescriptor.vertexFunction=library.makeFunction(name: "bookSpineShadowVertex")
        spineShadowPipeline=try device.makeRenderPipelineState(descriptor: shadowDescriptor)
        let bindingVertices=BookSpineMesh.vertices()
        guard let binding=device.makeBuffer(bytes: bindingVertices,length: bindingVertices.count*MemoryLayout<BookSpineVertex>.stride) else { throw DocumentPreviewRenderingError.unavailable }
        spineMesh=binding; spineVertexCount=bindingVertices.count
        let shadowTexture=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,width: 1024,height: 1024,mipmapped: false)
        shadowTexture.storageMode = .private; shadowTexture.usage = [.shaderRead,.renderTarget]
        guard let map=device.makeTexture(descriptor: shadowTexture) else { throw DocumentPreviewRenderingError.unavailable }
        shadowMap=map
        let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .less; depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw DocumentPreviewRenderingError.unavailable }
        depthState = state
        var vertices: [SIMD2<Float>] = []
        let columns = 96, rows = 12
        for y in 0..<rows { for x in 0..<columns {
            let a = SIMD2(Float(x)/Float(columns),Float(y)/Float(rows))
            let b = SIMD2(Float(x+1)/Float(columns),a.y)
            let c = SIMD2(a.x,Float(y+1)/Float(rows))
            let d = SIMD2(b.x,c.y)
            vertices += [a,b,c,b,d,c]
        }}
        guard let buffer = device.makeBuffer(bytes: vertices,length: vertices.count*MemoryLayout<SIMD2<Float>>.stride),
              let texture = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,width: 1,height: 1,mipmapped: false)) else { throw DocumentPreviewRenderingError.unavailable }
        mesh=buffer; vertexCount=vertices.count; white=texture
        var pixel: UInt32 = 0xffffffff
        texture.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &pixel,bytesPerRow: 4)
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        #if os(iOS)
        view.setNeedsDisplay()
        #else
        view.needsDisplay = true
        #endif
    }
    func draw(in view: MTKView) {
        guard !layout.openings.isEmpty, let pass=view.currentRenderPassDescriptor,
              let drawable=view.currentDrawable, let command=queue.makeCommandBuffer() else { return }
        encode(pass: pass, command: command, viewport: view.drawableSize)
        command.present(drawable); command.commit()
    }
    /// Also used by offscreen GPU checks; geometry and shading follow the live path.
    func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, viewport: CGSize) {
        guard !layout.openings.isEmpty else { return }
        let aspect = Float(viewport.width / max(1,viewport.height))
        let fit = min(0.82*aspect,1.65/paperAspect)*zoom
        struct Sheet {
            var uniforms: Uniforms
            var front: MTLTexture
            var back: MTLTexture
            var isSpine: Bool = false
        }
        var sheets: [Sheet]=[]
        func draw(_ face: BookPageFace, back: BookPageFace? = nil, side: Float, progress: Float = 0, height: Float = 0, offset: SIMD2<Float> = .zero, tint: Float = 1, curlDirection: Float = 1) {
            let back = back ?? .blank
            let u = Uniforms(pose: SIMD4(yaw,pitch,fit,aspect),paper: SIMD4(side,progress,paperAspect,height),
                frontUV: SIMD4(face.u0,face.u1,0,0),backUV: SIMD4(back.u0,back.u1,0,0),
                stack: SIMD4(offset.x,offset.y,tint,0),shape: SIMD4(gutterCurvature,curlDirection,0,0))
            sheets.append(Sheet(uniforms: u,front: face.source.flatMap { images[$0] } ?? white,
                                back: back.source.flatMap { images[$0] } ?? white))
        }
        let current = layout.openings[min(opening,layout.openings.count-1)]
        // Offset both the plane and depth of the underlying leaves. Alternating
        // edge tones distinguish individual sheets even in a head-on view.
        let passed=Float(opening)+turn
        func stack(side: Float, count: Float) {
            guard count > 0 else { return }
            let amount=min(8,count)
            for i in (1...8).reversed() {
                let fraction=Float(i)/8
                draw(.blank,side: side,height: -0.006-amount*0.009*fraction,
                     offset: SIMD2(side*amount*0.004*fraction,-amount*0.003*fraction),
                     tint: i.isMultiple(of: 2) ? 0.80 : 0.97)
            }
        }
        stack(side: -1,count: Float(layout.openings.count-1)-passed)
        stack(side: 1,count: passed)
        let lift=sin(abs(turn)*Float.pi)*0.012
        let separation: Float=0.004
        if turn > 0, opening+1 < layout.openings.count {
            let next=layout.openings[opening+1]
            draw(current.right,side: 1,height: -separation*turn)
            draw(next.left,side: -1,height: -separation*(1-turn))
            draw(current.left,back: next.right,side: -1,progress: turn,height: lift)
        } else if turn < 0, opening > 0 {
            let previous=layout.openings[opening-1]
            draw(previous.right,side: 1,height: -separation*(1+turn))
            draw(current.left,side: -1,height: separation*turn)
            draw(previous.left,back: current.right,side: -1,progress: 1+turn,height: lift,curlDirection: -1)
        } else {
            draw(current.left,side: -1); draw(current.right,side: 1)
        }
        // The binding closes the roots, underside and both ends. Its top follows
        // the same gutter profile as the paper; it participates in both passes.
        let blockSize=min(8,max(passed,Float(layout.openings.count-1)-passed))
        let binding=Uniforms(pose: SIMD4(yaw,pitch,fit,aspect),paper: SIMD4(0,0,paperAspect,0),
            frontUV: SIMD4(0,1,0,0),backUV: SIMD4(0,1,0,0),stack: SIMD4(0,blockSize*0.003,0.46,0),
            shape: SIMD4(gutterCurvature,0,0.018,0.024+blockSize*0.009))
        sheets.append(Sheet(uniforms: binding,front: white,back: white,isSpine: true))
        let shadowPass=MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture=shadowMap
        shadowPass.depthAttachment.loadAction = .clear; shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth=1
        guard let shadowEncoder=command.makeRenderCommandEncoder(descriptor: shadowPass) else { return }
        shadowEncoder.label="Book geometry shadow map"
        shadowEncoder.setRenderPipelineState(shadowPipeline); shadowEncoder.setDepthStencilState(depthState)
        shadowEncoder.setCullMode(.none); shadowEncoder.setVertexBuffer(mesh,offset: 0,index: 0)
        for var sheet in sheets {
            shadowEncoder.setRenderPipelineState(sheet.isSpine ? spineShadowPipeline : shadowPipeline)
            shadowEncoder.setVertexBuffer(sheet.isSpine ? spineMesh : mesh,offset: 0,index: 0)
            shadowEncoder.setVertexBytes(&sheet.uniforms,length: MemoryLayout<Uniforms>.stride,index: 1)
            shadowEncoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: sheet.isSpine ? spineVertexCount : vertexCount)
        }
        shadowEncoder.endEncoding()
        guard let encoder=command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none); encoder.setVertexBuffer(mesh,offset: 0,index: 0)
        encoder.setFragmentTexture(shadowMap,index: 2)
        for var sheet in sheets {
            encoder.setRenderPipelineState(sheet.isSpine ? spinePipeline : pipeline)
            encoder.setVertexBuffer(sheet.isSpine ? spineMesh : mesh,offset: 0,index: 0)
            encoder.setVertexBytes(&sheet.uniforms,length: MemoryLayout<Uniforms>.stride,index: 1)
            encoder.setFragmentBytes(&sheet.uniforms,length: MemoryLayout<Uniforms>.stride,index: 1)
            encoder.setFragmentTexture(sheet.front,index: 0); encoder.setFragmentTexture(sheet.back,index: 1)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: sheet.isSpine ? spineVertexCount : vertexCount)
        }
        encoder.endEncoding()
    }
}
