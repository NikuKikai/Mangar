import Foundation
import CoreGraphics

/// The page boundary is an output window. Each layer owns independent, signed
/// local coordinates; z changes translation only, never size or compositing order.
enum LayerParallax {
    static let depthRange = -99...99
    static func label(_ z:Int,prefix:String = "z") -> String {
        prefix + (z == 0 ? "=0" : z>0 ? "+\(z)" : "\(z)")
    }
    static func origin(page:PageRecord) -> CGPoint {
        let rect=page.boundary.finiteRect ?? page.boundary.initialRect
        return CGPoint(x:rect.midX,y:rect.midY)
    }
    static func offsets(page:PageRecord,center:CGPoint,strength:Double) -> [UUID:CGPoint] {
        let anchor=origin(page:page),strength=min(1,max(0,strength))
        let layers=Dictionary(uniqueKeysWithValues:page.layers.map { ($0.id,$0) })
        return Dictionary(uniqueKeysWithValues:page.layers.map { layer in
            var z=0,current:UUID?=layer.id,seen=Set<UUID>()
            while let id=current,seen.insert(id).inserted,let entry=layers[id] {
                if entry.isParallaxEnabled { z += min(depthRange.upperBound,max(depthRange.lowerBound,entry.z)) }
                current=entry.parentID
            }
            let factor = -Double(z)*strength/100
            return (layer.id,CGPoint(x:(center.x-anchor.x)*factor,y:(center.y-anchor.y)*factor))
        })
    }
}
