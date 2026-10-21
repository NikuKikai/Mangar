import simd

/// Closed parametric volume: the shader maps x to binding width and z to
/// depth below the curved top. Subdivided end caps share the top's boundary.
struct BookSpineVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}

enum BookSpineMesh {
    static func vertices() -> [BookSpineVertex] {
        var result: [BookSpineVertex]=[]
        func quad(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>,_ d: SIMD3<Float>,_ normal: SIMD3<Float>) {
            result += [a,b,c,b,d,c].map {
                BookSpineVertex(position: SIMD4($0.x,$0.y,$0.z,1),normal: SIMD4(normal.x,normal.y,normal.z,0))
            }
        }
        let segments=32
        for i in 0..<segments {
            let x0=Float(i)*2/Float(segments)-1, x1=Float(i+1)*2/Float(segments)-1
            for z: Float in [0,1] {
                quad(SIMD3(x0,-0.5,z),SIMD3(x1,-0.5,z),SIMD3(x0,0.5,z),SIMD3(x1,0.5,z),SIMD3(0,0,z == 0 ? 1 : -1))
            }
            for y: Float in [-0.5,0.5] {
                quad(SIMD3(x0,y,0),SIMD3(x1,y,0),SIMD3(x0,y,1),SIMD3(x1,y,1),SIMD3(0,y > 0 ? 1 : -1,0))
            }
        }
        for x: Float in [-1,1] {
            quad(SIMD3(x,-0.5,0),SIMD3(x,0.5,0),SIMD3(x,-0.5,1),SIMD3(x,0.5,1),SIMD3(x,0,0))
        }
        return result
    }
}
