import Foundation
import Metal

struct BrushGPUCurve {
    var values: SIMD4<Float>
    var tail: SIMD4<Float>
    var tangents: SIMD4<Float>
    var tangentTail: SIMD4<Float>
    init(_ curve: BrushResponseCurve) {
        values = SIMD4(Float(curve.outputs[0]), Float(curve.outputs[1]), Float(curve.outputs[2]), Float(curve.outputs[3]))
        tail = SIMD4(Float(curve.outputs[4]), curve.enabled ? 1 : 0, 0, 0)
        tangents = SIMD4(Float(curve.tangent(at: 0)), Float(curve.tangent(at: 1)),
                         Float(curve.tangent(at: 2)), Float(curve.tangent(at: 3)))
        tangentTail = SIMD4(Float(curve.tangent(at: 4)), 0, 0, 0)
    }
}

/// Compile immutable curves once per stroke, not on every Pencil move or GPU batch.
struct CompiledBrush {
    var uniforms: BrushGPUUniforms
    let curves: MTLBuffer
    let maximumReach: Double
    let tips: MTLTexture
    init(device: MTLDevice, queue: MTLCommandQueue, cache: BrushTipTextureCache, stroke: StrokeCommand, capacity: Int, width: Int, height: Int) {
        tips = cache.texture(assets: stroke.tipAssets ?? [], device: device, queue: queue)
        uniforms = BrushGPUUniforms(stroke: stroke, inputCount: 0, capacity: capacity, width: width, height: height)
        let settings = stroke.brush.validated
        let dynamics = settings.resolvedDynamics
        let data = BrushParameter.allCases.flatMap { parameter in
            BrushDynamicInput.allCases.map { BrushGPUCurve(dynamics[parameter][$0]) }
        }
        curves = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<BrushGPUCurve>.stride)!
        maximumReach = stroke.definition.maximumReach(settings)
    }
}
