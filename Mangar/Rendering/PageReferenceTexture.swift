import Foundation
import CoreGraphics
import Metal

/// A display-only source region. Reverse faces mirror their horizontal UV range.
struct PageReferenceTexture {
    var rect: CGRect
    var texture: MTLTexture
    var uv: SIMD2<Float> = SIMD2(0,1)
}

/// Captures reference alpha as replayable, compressed R8 tiles, independent of
/// subsequent edits to the referenced document. Empty/full tiles need no pixels.
@MainActor
final class PageReferenceCoverage {
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void referenceCoverage(texture2d<float> image [[texture(0)]],
        texture2d<float,access::read_write> mask [[texture(1)]],
        constant float4 &rect [[buffer(0)]], constant float2 &uv [[buffer(1)]],
        uint2 p [[thread_position_in_grid]]) {
        float2 q=(float2(p)+0.5-rect.xy)/rect.zw;
        if (any(q<0) || any(q>=1)) return;
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float a=image.sample(s,float2(mix(uv.x,uv.y,q.x),q.y)).a;
        mask.write(float4(max(mask.read(p).r,a)),p);
    }
    kernel void referenceBounds(texture2d<float,access::read> mask [[texture(0)]],
        device atomic_uint *bounds [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
        float a=mask.read(p).r;
        if (a>0) {
            atomic_fetch_min_explicit(bounds,p.x,memory_order_relaxed);
            atomic_fetch_min_explicit(bounds+1,p.y,memory_order_relaxed);
            atomic_fetch_max_explicit(bounds+2,p.x+1,memory_order_relaxed);
            atomic_fetch_max_explicit(bounds+3,p.y+1,memory_order_relaxed);
        }
        if (a<1) atomic_store_explicit(bounds+4,1,memory_order_relaxed);
    }
    """
    static func capture(_ sources: [PageReferenceTexture], device: MTLDevice,
                        boundary: CanvasBoundary) throws -> [SelectionCoverageTile] {
        guard let queue=device.makeCommandQueue() else { throw TileCodec.CodecError.invalidTile }
        let library=try device.makeLibrary(source:shader,options:nil)
        let pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"referenceCoverage")!)
        let reduce=try device.makeComputePipelineState(function:library.makeFunction(name:"referenceBounds")!)
        var keys=Set<SelectionTileKey>()
        for source in sources {
            let r=boundary.clip(source.rect)
            guard !r.isEmpty,!r.isNull else { continue }
            for y in Int(floor(r.minY/256))..<Int(ceil(r.maxY/256)) {
                for x in Int(floor(r.minX/256))..<Int(ceil(r.maxX/256)) { keys.insert(.init(x:x,y:y)) }
            }
        }
        let sorted=keys.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var result:[SelectionCoverageTile]=[]
        for start in stride(from:0,to:sorted.count,by:16) {
            guard let command=queue.makeCommandBuffer() else { throw TileCodec.CodecError.invalidTile }
            var pending:[(SelectionTileKey,MTLTexture,MTLBuffer)]=[]
            for key in sorted[start..<min(start+16,sorted.count)] {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:256,height:256,mipmapped:false)
                d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
                guard let mask=device.makeTexture(descriptor:d) else { throw TileCodec.CodecError.invalidTile }
                let zeros=Data(repeating:0,count:65536)
                zeros.withUnsafeBytes { mask.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256) }
                let tile=CGRect(x:key.x*256,y:key.y*256,width:256,height:256)
                for source in sources where source.rect.intersects(tile) {
                    guard let encoder=command.makeComputeCommandEncoder() else { throw TileCodec.CodecError.invalidTile }
                    var rect=SIMD4<Float>(Float(source.rect.minX-tile.minX),Float(source.rect.minY-tile.minY),Float(source.rect.width),Float(source.rect.height))
                    var uv=source.uv
                    encoder.setComputePipelineState(pipeline)
                    encoder.setTexture(source.texture,index:0); encoder.setTexture(mask,index:1)
                    encoder.setBytes(&rect,length:16,index:0); encoder.setBytes(&uv,length:8,index:1)
                    encoder.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
                    encoder.endEncoding()
                }
                let initial:[UInt32]=[256,256,0,0,0]
                guard let bounds=device.makeBuffer(bytes:initial,length:20),
                      let encoder=command.makeComputeCommandEncoder() else { throw TileCodec.CodecError.invalidTile }
                encoder.setComputePipelineState(reduce);encoder.setTexture(mask,index:0);encoder.setBuffer(bounds,offset:0,index:0)
                encoder.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
                encoder.endEncoding()
                pending.append((key,mask,bounds))
            }
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw TileCodec.CodecError.invalidTile }
            for (key,mask,buffer) in pending {
                let bounds=buffer.contents().bindMemory(to:UInt32.self,capacity:5)
                let x0=Int(bounds[0]),y0=Int(bounds[1]),x1=Int(bounds[2]),y1=Int(bounds[3])
                guard x1>x0,y1>y0 else { continue }
                var encoded:Data?
                if bounds[4] != 0 {
                    var pixels=Data(count:65536)
                    pixels.withUnsafeMutableBytes { mask.getBytes($0.baseAddress!,bytesPerRow:256,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0) }
                    encoded=try TileCodec.encode(pixels)
                }
                result.append(SelectionCoverageTile(x:key.x,y:key.y,
                    bounds:SelectionRect(x:Double(key.x*256+x0),y:Double(key.y*256+y0),width:Double(x1-x0),height:Double(y1-y0)),
                    pixels:encoded))
            }
        }
        return result
    }
}
