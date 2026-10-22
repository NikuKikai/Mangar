import MetalKit

/// A single screen quad; the fragment shader inverse-projects an orthographic
/// hemisphere into a local, origin-relative patch of the canvas.
@MainActor
final class MetalSphereRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var viewport: SIMD4<Float>
        var sampling: SIMD4<Float>
        var bounds: SIMD4<Float>
        var outsideFill: SIMD4<Float>
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SphereVertex { float4 position [[position]]; float2 uv; };
    struct SphereUniforms { float4 viewport; float4 sampling; float4 bounds; float4 outsideFill; };
    vertex SphereVertex sphereVertex(uint id [[vertex_id]]) {
        const float2 p[6] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,1),float2(-1,-1),float2(1,-1)};
        SphereVertex o; o.position=float4(p[id],0,1); o.uv=p[id]*float2(0.5,-0.5)+0.5; return o;
    }
    fragment float4 sphereFragment(SphereVertex in [[stage_in]],
        constant SphereUniforms &u [[buffer(0)]],texture2d<float> image [[texture(0)]]) {
        float2 p=(in.uv-0.5)*u.viewport.xy/u.viewport.z;
        float r=length(p);
        float aa=max(fwidth(r),0.00001);
        if (r>1.0) discard_fragment();
        float2 arc=r>0.000001 ? p*(asin(min(r,1.0))/(r*M_PI_F*0.5)) : float2(0);
        float2 uv=u.sampling.xy+arc*u.sampling.zw;
        if (any(uv<0.0)||any(uv>1.0)) discard_fragment();
        float edge=smoothstep(0.0,aa,1.0-r);
        if (any(uv<u.bounds.xy)||any(uv>=u.bounds.zw)) return u.outsideFill*edge;
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
        float4 color=image.sample(s,uv);
        return color * edge;
    }
    """
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    weak var view: MTKView?
    var center: CGPoint
    let surface: PageSurface
    let boundary: CanvasBoundary
    var patchBounds: CGRect = .null
    var image: MTLTexture?
    var zoom: CGFloat = 1
    init(surface: PageSurface, center: CGPoint, boundary: CanvasBoundary = .unlimited) throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw DocumentPreviewRenderingError.unavailable }
        self.device=device; self.queue=queue; self.surface=surface; self.center=boundary.clampedPoint(center); self.boundary=boundary
        let library=try device.makeLibrary(source: Self.shader,options: nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name: "sphereVertex")
        descriptor.fragmentFunction=library.makeFunction(name: "sphereFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let blend=descriptor.colorAttachments[0]!
        blend.isBlendingEnabled=true
        blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.sourceAlphaBlendFactor = .one; blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline=try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }
    func diskRadius(in size: CGSize) -> CGFloat { min(size.width,size.height)*0.43*zoom }
    func uniforms(size: CGSize) -> Uniforms {
        let clip=boundary.gpuClip(relativeTo: SIMD2(patchBounds.minX,patchBounds.minY))
        let scale=SIMD4<Float>(Float(patchBounds.width),Float(patchBounds.height),Float(patchBounds.width),Float(patchBounds.height))
        return Uniforms(viewport: SIMD4(Float(size.width),Float(size.height),Float(diskRadius(in: size)),0),
            sampling: SIMD4(Float((center.x-patchBounds.minX)/patchBounds.width),Float((center.y-patchBounds.minY)/patchBounds.height),
                Float(surface.sourceRadius/patchBounds.width),Float(surface.sourceRadius/patchBounds.height)), bounds: clip/scale, outsideFill: surface.outsideFill.color)
    }
    func encode(encoder: MTLRenderCommandEncoder,size: CGSize) {
        guard let image, !patchBounds.isNull, size.width>0, size.height>0 else { return }
        var u=uniforms(size: size)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        encoder.setFragmentTexture(image,index: 0)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6)
    }
    func draw(in view: MTKView) {
        guard let pass=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,
              let command=queue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(encoder: encoder,size: view.drawableSize)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) { invalidate() }
    func invalidate() {
        #if os(iOS)
        view?.setNeedsDisplay()
        #else
        view?.needsDisplay=true
        #endif
    }
}
