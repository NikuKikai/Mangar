import Foundation
import CoreGraphics

/// All coordinates here are logical view points and Double-precision world pixels.
nonisolated struct CanvasViewportGeometry: Equatable {
    var size: CGSize
    var zoom: CGFloat
    var rotation: CGFloat
    var pan: CGPoint
    var viewRect: CGRect { CGRect(origin:.zero,size:size) }
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let x=p.x*zoom,y=p.y*zoom,c=cos(rotation),s=sin(rotation)
        return CGPoint(x:x*c-y*s+pan.x,y:x*s+y*c+pan.y)
    }
    func canvasPoint(_ p: CGPoint) -> CGPoint {
        let x=p.x-pan.x,y=p.y-pan.y,c=cos(rotation),s=sin(rotation)
        return CGPoint(x:(x*c+y*s)/zoom,y:(-x*s+y*c)/zoom)
    }
    var canvasCorners: [CGPoint] { [CGPoint.zero,CGPoint(x:size.width,y:0),CGPoint(x:size.width,y:size.height),CGPoint(x:0,y:size.height)].map(canvasPoint) }
    var canvasBounds: CGRect {
        let p=canvasCorners
        return CGRect(x:p.map(\.x).min()!,y:p.map(\.y).min()!,width:p.map(\.x).max()!-p.map(\.x).min()!,height:p.map(\.y).max()!-p.map(\.y).min()!)
    }
    /// Segment clipping avoids AABB false positives when the canvas is rotated.
    static func clipSegment(_ a: CGPoint,_ b: CGPoint,to rect: CGRect) -> (CGPoint,CGPoint)? {
        let dx=b.x-a.x,dy=b.y-a.y
        var lo:CGFloat=0,hi:CGFloat=1
        for (p,q) in [(-dx,a.x-rect.minX),(dx,rect.maxX-a.x),(-dy,a.y-rect.minY),(dy,rect.maxY-a.y)] {
            if abs(p)<1e-12 { if q<0 { return nil }; continue }
            let t=q/p
            if p<0 { lo=max(lo,t) } else { hi=min(hi,t) }
            if lo>hi { return nil }
        }
        return (CGPoint(x:a.x+lo*dx,y:a.y+lo*dy),CGPoint(x:a.x+hi*dx,y:a.y+hi*dy))
    }
    func intersects(_ rect: CGRect) -> Bool {
        guard !rect.isNull,!rect.isEmpty,size.width>0,size.height>0 else { return false }
        let p=[CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)].map(viewPoint)
        let viewport=[CGPoint.zero,CGPoint(x:size.width,y:0),CGPoint(x:size.width,y:size.height),CGPoint(x:0,y:size.height)]
        let axes=[CGPoint(x:1,y:0),CGPoint(x:0,y:1),CGPoint(x:cos(rotation),y:sin(rotation)),CGPoint(x:-sin(rotation),y:cos(rotation))]
        for axis in axes {
            let tile=p.map { $0.x*axis.x+$0.y*axis.y }, view=viewport.map { $0.x*axis.x+$0.y*axis.y }
            if min(tile.max()!,view.max()!)-max(tile.min()!,view.min()!)<=1e-8 { return false }
        }
        return true
    }
    func zoomedAroundCenter(to scale: CGFloat) -> Self {
        let anchor=canvasPoint(CGPoint(x:size.width/2,y:size.height/2))
        var result=self
        result.zoom=scale
        result.pan=result.centeredPan(on:anchor)
        return result
    }
    func centeredPan(on world:CGPoint) -> CGPoint {
        let p=CanvasViewportGeometry(size:size,zoom:zoom,rotation:rotation,pan:.zero).viewPoint(world)
        return CGPoint(x:size.width/2-p.x,y:size.height/2-p.y)
    }
}

nonisolated struct CanvasRulerLayout {
    enum Axis { case xEdge,yEdge }
    struct Line {
        var axis:Axis
        var fixed:CGFloat
        var outside:CGPoint
        var edge:Bool
        var first:CGPoint
        var last:CGPoint
        var minimum:CGFloat
        var maximum:CGFloat
        var step:CGFloat
    }
    var geometry:CanvasViewportGeometry
    var boundary:CanvasBoundary
    static func tickStep(_ zoom:CGFloat) -> CGFloat {
        let desired=70/max(zoom,1e-12),base=pow(10,floor(log10(desired))),normalized=desired/base
        return base*(normalized<=1 ? 1 : normalized<=2 ? 2 : normalized<=5 ? 5 : 10)
    }
    func line(_ axis:Axis) -> Line? {
        let viewport=geometry.viewRect,world=geometry.canvasBounds,c=cos(geometry.rotation),s=sin(geometry.rotation)
        let candidates:[(CGFloat,CGFloat)] = axis == .xEdge
            ? (boundary.hasMinimumX ? [(0,-1)] : []) + (boundary.width.map { [(CGFloat($0),CGFloat(1))] } ?? [])
            : (boundary.hasMinimumY ? [(0,-1)] : []) + (boundary.height.map { [(CGFloat($0),CGFloat(1))] } ?? [])
        func endpoints(_ fixed:CGFloat, edge:Bool = false) -> (CGPoint,CGPoint)? {
            var minimum = axis == .xEdge ? world.minY : world.minX
            var maximum = axis == .xEdge ? world.maxY : world.maxX
            if edge {
                if axis == .xEdge {
                    if boundary.hasMinimumY { minimum=max(minimum,0) }
                    if let height=boundary.height { maximum=min(maximum,CGFloat(height)) }
                } else {
                    if boundary.hasMinimumX { minimum=max(minimum,0) }
                    if let width=boundary.width { maximum=min(maximum,CGFloat(width)) }
                }
            }
            guard maximum>minimum else { return nil }
            return axis == .xEdge ? (CGPoint(x:fixed,y:minimum),CGPoint(x:fixed,y:maximum)) : (CGPoint(x:minimum,y:fixed),CGPoint(x:maximum,y:fixed))
        }
        func make(_ fixed:CGFloat,_ offset:CGPoint,_ edge:Bool) -> Line? {
            // Edge eligibility uses the real canvas segment above. The displayed
            // ruler is a full line, reaching the viewport even beyond page corners.
            guard let points=endpoints(fixed) else { return nil }
            let extensionLength=20/max(geometry.zoom,1e-12)
            let worldPoints = axis == .xEdge
                ? (CGPoint(x:fixed,y:points.0.y-extensionLength),CGPoint(x:fixed,y:points.1.y+extensionLength))
                : (CGPoint(x:points.0.x-extensionLength,y:fixed),CGPoint(x:points.1.x+extensionLength,y:fixed))
            let a=geometry.viewPoint(worldPoints.0),b=geometry.viewPoint(worldPoints.1)
            let shiftedA=CGPoint(x:a.x+offset.x,y:a.y+offset.y),shiftedB=CGPoint(x:b.x+offset.x,y:b.y+offset.y)
            guard let clipped=CanvasViewportGeometry.clipSegment(shiftedA,shiftedB,to:viewport) else { return nil }
            let p=geometry.canvasPoint(CGPoint(x:clipped.0.x-offset.x,y:clipped.0.y-offset.y)),q=geometry.canvasPoint(CGPoint(x:clipped.1.x-offset.x,y:clipped.1.y-offset.y))
            let values=axis == .xEdge ? (p.y,q.y) : (p.x,q.x)
            return Line(axis:axis,fixed:fixed,outside:offset,edge:edge,first:clipped.0,last:clipped.1,minimum:min(values.0,values.1),maximum:max(values.0,values.1),step:Self.tickStep(geometry.zoom))
        }
        for (fixed,direction) in candidates {
            guard let endpoints=endpoints(fixed,edge:true) else { continue }
            guard let edge=CanvasViewportGeometry.clipSegment(geometry.viewPoint(endpoints.0),geometry.viewPoint(endpoints.1),to:viewport),hypot(edge.1.x-edge.0.x,edge.1.y-edge.0.y)>=96 else { continue }
            let normal=axis == .xEdge ? CGPoint(x:c*direction,y:s*direction) : CGPoint(x:-s*direction,y:c*direction)
            if let line=make(fixed,CGPoint(x:normal.x*10,y:normal.y*10),true) { return line }
        }
        let anchor=axis == .xEdge ? CGPoint(x:24,y:geometry.size.height/2) : CGPoint(x:geometry.size.width/2,y:24)
        let p=geometry.canvasPoint(anchor)
        return make(axis == .xEdge ? p.x : p.y,.zero,false)
    }
    func point(_ value:CGFloat,on line:Line) -> CGPoint {
        let p=geometry.viewPoint(line.axis == .xEdge ? CGPoint(x:line.fixed,y:value) : CGPoint(x:value,y:line.fixed))
        return CGPoint(x:p.x+line.outside.x,y:p.y+line.outside.y)
    }
}
