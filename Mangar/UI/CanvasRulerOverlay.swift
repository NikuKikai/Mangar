import SwiftUI

struct CanvasRulerOverlay: View {
    @ObservedObject var session: EditorSession
    var body: some View {
        let _ = session.viewportRevision
        Canvas { context,size in
            let geometry = CanvasViewportGeometry(size:size,zoom:session.renderer.zoom,rotation:session.renderer.rotation,pan:session.renderer.pan)
            let layout = CanvasRulerLayout(geometry:geometry,boundary:session.page.boundary)
            for axis in [CanvasRulerLayout.Axis.xEdge,.yEdge] {
                guard let line=layout.line(axis) else { continue }
                var path=Path();path.move(to:line.first);path.addLine(to:line.last)
                context.stroke(path,with:.color(.accentColor.opacity(line.edge ? 0.95 : 0.8)),lineWidth:1)
                let angle=geometry.rotation
                let normal=axis == .xEdge ? CGPoint(x:cos(angle),y:sin(angle)) : CGPoint(x:-sin(angle),y:cos(angle))
                let minor=line.step/5
                let values:[CGFloat]
                if line.edge {
                    let lo=Int(ceil(line.minimum/minor)),hi=Int(floor(line.maximum/minor))
                    values=lo<=hi ? (lo...hi).map { CGFloat($0)*minor } : []
                } else {
                    let margin=18/max(geometry.zoom,1e-12)
                    let first=ceil((line.minimum+margin)/minor)*minor
                    let last=floor((line.maximum-margin)/minor)*minor
                    values=first<last ? [first,last] : [line.minimum+(line.maximum-line.minimum)*0.2,line.minimum+(line.maximum-line.minimum)*0.8]
                }
                for value in values {
                    let major = !line.edge || abs(value/line.step-(value/line.step).rounded())<0.001
                    let point=layout.point(value,on:line),length:CGFloat=major ? 4 : 2
                    var tick=Path();tick.move(to:CGPoint(x:point.x-normal.x*length,y:point.y-normal.y*length));tick.addLine(to:CGPoint(x:point.x+normal.x*length,y:point.y+normal.y*length))
                    context.stroke(tick,with:.color(.accentColor.opacity(major ? 1 : 0.7)),lineWidth:1)
                    guard major else { continue }
                    let label=Text(verbatim:String(format:"%.6g",Double(abs(value)<minor*0.0001 ? 0 : value))).font(.system(size:9,design:.monospaced)).foregroundColor(.accentColor)
                    let direction:CGFloat = line.edge && (line.outside.x*normal.x+line.outside.y*normal.y)<0 ? -1 : 1
                    let position=CGPoint(x:point.x+normal.x*direction*15,y:point.y+normal.y*direction*15)
                    if position.x >= 18 && position.x <= size.width-18 && position.y >= 6 && position.y <= size.height-6 {
                        context.draw(label,at:position)
                    }
                }
            }
        }.clipped()
    }
}
