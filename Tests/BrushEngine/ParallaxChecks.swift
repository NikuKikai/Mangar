import Foundation
import CoreGraphics
import Metal

@MainActor
enum ParallaxChecks {
    static func run(device:MTLDevice,queue:MTLCommandQueue,library:MTLLibrary) throws {
        var page=PageRecord.blank(width:1000,height:1000)
        let folder=LayerRecord(name:"Group",kind:.folder,z:-40,isParallaxEnabled:true)
        let paint=LayerRecord(name:"Paint",parentID:folder.id,z:-60,isParallaxEnabled:true)
        let flat=LayerRecord(name:"Flat")
        page.layers=[folder,paint,flat]
        let offsets=LayerParallax.offsets(page:page,center:CGPoint(x:2500,y:500),strength:1)
        precondition(offsets[paint.id] == CGPoint(x:2000,y:0))
        precondition(offsets[folder.id] == CGPoint(x:800,y:0) && offsets[flat.id] == .zero)
        precondition(LayerParallax.offsets(page:page,center:LayerParallax.origin(page:page),strength:1).values.allSatisfy { $0 == .zero })
        precondition(LayerParallax.offsets(page:page,center:CGPoint(x:2500,y:500),strength:0).values.allSatisfy { $0 == .zero })
        var disabled=page
        disabled.layers[0].isParallaxEnabled=false
        let inherited=LayerParallax.offsets(page:disabled,center:CGPoint(x:2500,y:500),strength:1)
        precondition(inherited[folder.id] == .zero && inherited[paint.id] == CGPoint(x:1200,y:0))
        disabled.layers[1].isParallaxEnabled=false
        precondition(LayerParallax.offsets(page:disabled,center:CGPoint(x:2500,y:500),strength:1)[paint.id] == .zero)
        precondition(disabled.layers[0].z == -40 && disabled.layers[1].z == -60)
        precondition(LayerParallax.label(99) == "z+99" && LayerParallax.label(-99) == "z-99" && LayerParallax.label(0) == "z=0")
        let restored=try JSONDecoder().decode(PageRecord.self,from:JSONEncoder().encode(page))
        precondition(restored.layers == page.layers)
        let key=TileKey(layerID:paint.id,x:-8,y:0)
        let window=CGRect(x:0,y:0,width:1000,height:1000)
        precondition(CanvasTileIndex([key]).query(window).isEmpty)
        precondition(CanvasTileIndex([key]).query(window.offsetBy(dx:-2000,dy:0)).contains(key))
        print("PASS Layer z persists, adds ancestor depth, preserves order and queries signed local tiles beyond finite page bounds")

        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:256,height:256,mipmapped:false)
        d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite]
        let mask=device.makeTexture(descriptor:d)!
        var data=Data(repeating:0,count:65536)
        for y in 0..<128 { for x in 0..<128 { data[y*256+x]=128 } }
        data.withUnsafeBytes { mask.replace(region:MTLRegionMake2D(0,0,256,256),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256) }
        let selection=SelectionSnapshot(defaultCoverage:0,tiles:[.init(x:0,y:0):mask],tileBounds:[.init(x:0,y:0):CGRect(x:0,y:0,width:128,height:128)],bounds:.null,outlineKeys:[])
        let projector=try LayerSelectionProjection(device:device)
        func value(_ s:SelectionSnapshot,_ x:Int,_ y:Int)->UInt8 {
            let key=SelectionTileKey(x:Int(floor(Double(x)/256)),y:Int(floor(Double(y)/256)))
            guard let tile=s.tiles[key] else { return s.defaultCoverage }
            var pixel:UInt8=0
            tile.getBytes(&pixel,bytesPerRow:1,from:MTLRegionMake2D(x-key.x*256,y-key.y*256,1,1),mipmapLevel:0)
            return pixel
        }
        let shift=CGPoint(x:257.5,y:-13.25)
        let projected=projector.project(selection,offset:shift)!
        precondition(value(projected,-248,23) == 128 && value(projected,-130,23) == 64)
        precondition(value(projected,10,10) == 0)
        let inverted=projector.project(selection.inverted(),offset:shift)!
        precondition(abs(Int(value(projected,-130,23))+Int(value(inverted,-130,23))-255)<=1)
        precondition(value(inverted,1000,-1000) == 255)
        let all=SelectionSnapshot(defaultCoverage:255,tiles:[:],tileBounds:[:],bounds:.infinite,outlineKeys:[])
        let clipped=projector.project(all,offset:CGPoint(x:2000,y:0),boundary:page.boundary,only:[.init(x:-8,y:0)])!
        precondition(value(clipped,-2010,20) == 0 && value(clipped,-1990,20) == 255)
        print("PASS GPU selection projection preserves fractional alpha, inversion and shifted finite-window clipping across tile boundaries")

        var brush=MangaBrushes.configuration(.binaryPen)
        brush.size=20;brush.red=0;brush.green=0;brush.blue=0
        let stroke=StrokeCommand(canvasOffset:CGPoint(x:2000,y:0),definition:MangaBrushes.definition(.binaryPen),
            layerID:paint.id,samples:[StrokeSample(x:5,y:100,pressure:1)],brush:brush,seed:1,tool:.brush)
        let engine=try MetalBrushEngine(device:device,queue:queue,library:library)
        let result=engine.finish(stroke,base:[:],selection:nil,width:1000,height:1000,boundary:page.boundary,canvasOffset:stroke.canvasOffset)
        engine.synchronize()
        precondition(!result.tiles.isEmpty && result.tiles.keys.allSatisfy { $0.x<0 })
        var count=0
        for (key,tile) in result.tiles {
            var pixels=[UInt8](repeating:0,count:256*256*4)
            tile.getBytes(&pixels,bytesPerRow:1024,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0)
            for y in 0..<256 { for x in 0..<256 where pixels[(y*256+x)*4+3]>0 {
                count+=1;precondition(key.x*256+x+2000>=0 && key.x*256+x+2000<1000)
            }}
        }
        precondition(count>0)
        let localSelection=projector.project(selection,offset:stroke.canvasOffset)
        let selectedResult=engine.finish(stroke,base:[:],selection:localSelection,width:1000,height:1000,boundary:page.boundary,canvasOffset:stroke.canvasOffset)
        engine.synchronize()
        var peak:UInt8=0
        for tile in selectedResult.tiles.values {
            var pixels=[UInt8](repeating:0,count:256*256*4)
            tile.getBytes(&pixels,bytesPerRow:1024,from:MTLRegionMake2D(0,0,256,256),mipmapLevel:0)
            for i in stride(from:3,to:pixels.count,by:4) { peak=max(peak,pixels[i]) }
        }
        precondition(peak == 128)
        let replay=try JSONDecoder().decode(StrokeCommand.self,from:JSONEncoder().encode(stroke))
        precondition(replay.canvasOffset == stroke.canvasOffset && replay.samples == stroke.samples)
        print("PASS GPU brush writes negative layer tiles through the shifted page window, clips footprint correctly and freezes history mapping")
    }
}
