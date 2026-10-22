import Foundation
import Metal

@MainActor
enum PageRenderTexture {
    static func read(_ texture: MTLTexture,device:MTLDevice) throws -> PageRenderImage {
        let row=((texture.width*4+255)/256)*256
        guard let queue=device.makeCommandQueue(),let command=queue.makeCommandBuffer(),
              let buffer=device.makeBuffer(length:row*texture.height,options:.storageModeShared),
              let blit=command.makeBlitCommandEncoder() else { throw PageRenderCache.CacheError.invalidData }
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
            sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),to:buffer,
            destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:row*texture.height)
        blit.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw PageRenderCache.CacheError.invalidData }
        var pixels=Data(count:texture.width*texture.height*4)
        pixels.withUnsafeMutableBytes { output in
            for y in 0..<texture.height {
                output.baseAddress!.advanced(by:y*texture.width*4).copyMemory(
                    from:buffer.contents().advanced(by:y*row),byteCount:texture.width*4)
            }
        }
        return PageRenderImage(width:texture.width,height:texture.height,pixels:pixels)
    }
    static func upload(_ image:PageRenderImage,device:MTLDevice,maxDimension:Int) throws -> MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:image.width,height:image.height,mipmapped:true)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:d),let queue=device.makeCommandQueue(),
              let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else { throw PageRenderCache.CacheError.invalidData }
        image.pixels.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,
            withBytes:$0.baseAddress!,bytesPerRow:image.width*4) }
        blit.generateMipmaps(for:texture)
        // Far paper stacks must not retain a 4096 px source just because the
        // persisted cache is high resolution. Reuse its GPU mip levels.
        var level=0
        while max(image.width >> level,image.height >> level)>max(1,maxDimension) { level+=1 }
        var result=texture
        if level>0 {
            let width=max(1,image.width >> level),height=max(1,image.height >> level)
            let target=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:true)
            target.storageMode = .private;target.usage = .shaderRead
            guard let smaller=device.makeTexture(descriptor:target) else { throw PageRenderCache.CacheError.invalidData }
            blit.copy(from:texture,sourceSlice:0,sourceLevel:level,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                sourceSize:MTLSize(width:width,height:height,depth:1),to:smaller,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
            blit.generateMipmaps(for:smaller);result=smaller
        }
        blit.endEncoding();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw PageRenderCache.CacheError.invalidData }
        return result
    }
}
