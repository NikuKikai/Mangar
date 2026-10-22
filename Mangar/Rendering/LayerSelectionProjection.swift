import Foundation
import CoreGraphics
import Metal

/// Reprojects sparse selection coverage into layer-local coordinates. Constant
/// coverage remains a flag, and bilinear sampling spans source tile boundaries.
@MainActor
final class LayerSelectionProjection {
    private let device:MTLDevice
    private let queue:MTLCommandQueue
    private let pipeline:MTLComputePipelineState
    private let empty:MTLTexture
    private let full:MTLTexture
    private var cached:(SelectionSnapshot,CGPoint,SelectionSnapshot)?
    private static let source="""
    #include <metal_stdlib>
    using namespace metal;
    float maskValue(int2 p,texture2d<float,access::read> a,texture2d<float,access::read> b,
        texture2d<float,access::read> c,texture2d<float,access::read> d) {
        uint2 q=uint2(p%256);
        return p.y<256 ? (p.x<256 ? a.read(q).r:b.read(q).r) : (p.x<256 ? c.read(q).r:d.read(q).r);
    }
    kernel void projectSelection(texture2d<float,access::read> a [[texture(0)]],
        texture2d<float,access::read> b [[texture(1)]],texture2d<float,access::read> c [[texture(2)]],
        texture2d<float,access::read> d [[texture(3)]],texture2d<float,access::write> out [[texture(4)]],
        constant float2 &shift [[buffer(0)]],constant uint &base [[buffer(1)]],
        device atomic_uint *bounds [[buffer(2)]],constant float4 &clip [[buffer(3)]],uint2 p [[thread_position_in_grid]]) {
        float2 q=float2(p)+shift;int2 lo=int2(floor(q));float2 f=fract(q);
        float v=mix(mix(maskValue(lo,a,b,c,d),maskValue(lo+int2(1,0),a,b,c,d),f.x),
                    mix(maskValue(lo+int2(0,1),a,b,c,d),maskValue(lo+int2(1),a,b,c,d),f.x),f.y);
        if(any(float2(p)+0.5<clip.xy) || any(float2(p)+0.5>=clip.zw)) v=0;
        uint value=uint(round(clamp(v,0.0,1.0)*255));out.write(float4(float(value)/255),p);
        if(value>0) {
            atomic_fetch_min_explicit(bounds,p.x,memory_order_relaxed);atomic_fetch_min_explicit(bounds+1,p.y,memory_order_relaxed);
            atomic_fetch_max_explicit(bounds+2,p.x+1,memory_order_relaxed);atomic_fetch_max_explicit(bounds+3,p.y+1,memory_order_relaxed);
        }
        if(value!=255) atomic_store_explicit(bounds+4,1,memory_order_relaxed);
        if(value!=base) atomic_store_explicit(bounds+5,1,memory_order_relaxed);
    }
    """
    init(device:MTLDevice) throws {
        self.device=device;queue=device.makeCommandQueue()!
        let library=try device.makeLibrary(source:Self.source,options:nil)
        pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"projectSelection")!)
        func constant(_ value:UInt8)->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:256,height:256,mipmapped:false)
            d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite]
            let t=device.makeTexture(descriptor:d)!,data=Data(repeating:value,count:65536)
            data.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256) };return t
        }
        empty=constant(0);full=constant(255)
    }
    func project(_ snapshot:SelectionSnapshot?,offset:CGPoint,boundary:CanvasBoundary? = nil,only suppliedKeys:Set<SelectionTileKey>? = nil) -> SelectionSnapshot? {
        guard let snapshot,offset != .zero || boundary != nil else { return snapshot }
        if boundary == nil,let cache=cached,cache.0.identity == snapshot.identity,cache.0.isInverted == snapshot.isInverted,cache.1 == offset { return cache.2 }
        let source=snapshot.tiles
        let defaultCoverage:UInt8 = boundary == nil ? snapshot.defaultCoverage : 0
        var keys=suppliedKeys ?? Set<SelectionTileKey>()
        for key in source.keys where suppliedKeys == nil {
            let rect=CGRect(x:Double(key.x*256)-offset.x,y:Double(key.y*256)-offset.y,width:256,height:256).insetBy(dx:-1,dy:-1)
            for y in Int(floor(rect.minY/256))..<Int(ceil(rect.maxY/256)) {
                for x in Int(floor(rect.minX/256))..<Int(ceil(rect.maxX/256)) { keys.insert(.init(x:x,y:y)) }
            }
        }
        var tiles:[SelectionTileKey:MTLTexture]=[:],bounds:[SelectionTileKey:CGRect]=[:]
        var fullKeys=Set<SelectionTileKey>(),zeroKeys=Set<SelectionTileKey>()
        let ordered=Array(keys)
        for start in stride(from:0,to:ordered.count,by:32) {
            let command=queue.makeCommandBuffer()!
            var pending:[(SelectionTileKey,MTLTexture,MTLBuffer)]=[]
            for key in ordered[start..<min(ordered.count,start+32)] {
                let x=Double(key.x*256)+offset.x,y=Double(key.y*256)+offset.y
                let sx=Int(floor(x/256)),sy=Int(floor(y/256))
                var shift=SIMD2<Float>(Float(x-Double(sx*256)),Float(y-Double(sy*256)))
                // Float rounding at 256 must not sample beyond the four sources.
                shift=SIMD2(min(shift.x,255.99997),min(shift.y,255.99997))
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:256,height:256,mipmapped:false)
                descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.shaderWrite]
                let output=device.makeTexture(descriptor:descriptor)!
                let initial:[UInt32]=[256,256,0,0,0,0],buffer=device.makeBuffer(bytes:initial,length:24)!
                let encoder=command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline)
                for i in 0..<4 {
                    encoder.setTexture(source[.init(x:sx+i%2,y:sy+i/2)] ?? (snapshot.defaultCoverage == 0 ? empty:full),index:i)
                }
                var base=UInt32(defaultCoverage)
                var clip=(boundary ?? .unlimited).gpuClip(relativeTo:SIMD2(Double(key.x*256)+offset.x,Double(key.y*256)+offset.y))
                encoder.setTexture(output,index:4);encoder.setBytes(&shift,length:8,index:0)
                encoder.setBytes(&base,length:4,index:1);encoder.setBuffer(buffer,offset:0,index:2)
                encoder.setBytes(&clip,length:16,index:3)
                encoder.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
                encoder.endEncoding();pending.append((key,output,buffer))
            }
            command.commit();command.waitUntilCompleted()
            precondition(command.status == .completed,"Selection projection failed")
            for (key,output,buffer) in pending {
                let b=buffer.contents().bindMemory(to:UInt32.self,capacity:6)
                guard b[5] != 0 else { continue }
                if b[0]<b[2],b[1]<b[3] {
                    bounds[key]=CGRect(x:key.x*256+Int(b[0]),y:key.y*256+Int(b[1]),width:Int(b[2]-b[0]),height:Int(b[3]-b[1]))
                    if b[4] == 0 { fullKeys.insert(key) } else { tiles[key]=output }
                } else { zeroKeys.insert(key) }
            }
        }
        let result=SelectionSnapshot(defaultCoverage:defaultCoverage,tiles:tiles,tileBounds:bounds,bounds:.null,outlineKeys:[],fullKeys:fullKeys,zeroKeys:zeroKeys)
        if boundary == nil { cached=(snapshot,offset,result) }
        return result
    }
}
