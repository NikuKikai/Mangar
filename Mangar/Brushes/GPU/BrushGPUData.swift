import Foundation
import simd

struct BrushGPUInput {
    var positionPressureTime: SIMD4<Float>
    var orientation: SIMD4<Float>
    init(_ sample: StrokeSample, origin: SIMD2<Double> = .zero) {
        positionPressureTime = SIMD4(Float(sample.x-origin.x), Float(sample.y-origin.y), Float(sample.pressure), Float(sample.time))
        orientation = SIMD4(Float(sample.altitude), Float(sample.azimuth), 0, 0)
    }
}

/// Layout is shared with BrushKernels.txt; use float4/uint4 to keep ABI explicit.
struct BrushGPUUniforms {
    var settings: SIMD4<Float>
    var dynamics: SIMD4<Float>
    var surface: SIMD4<Float>
    var jitter: SIMD4<Float>
    var color: SIMD4<Float>
    var counts: SIMD4<UInt32>
    var tile: SIMD4<Float>
    var modes: SIMD4<UInt32>
    var ink: SIMD4<Float>
    var stamp: SIMD4<Float>
    var images: SIMD4<UInt32>
    var wet: SIMD4<Float>
    var medium: SIMD4<Float>
    var pickupTiles: SIMD4<Int32>
    var clip: SIMD4<Float> = .zero

    init(stroke: StrokeCommand, inputCount: Int, capacity: Int, width: Int, height: Int) {
        let b = stroke.brush.validated
        let d = stroke.definition
        settings = SIMD4(Float(b.size), Float(b.opacity), Float(b.flow), Float(b.spacing))
        dynamics = SIMD4(Float(d.tip.tiltElongation), 0, 0, 0)
        surface = SIMD4(Float(d.tip.hardness), Float(d.tip.grain), Float(d.tip.timeRate), Float(d.tip.pooling))
        jitter = SIMD4(Float(b.sizeJitter), Float(b.opacityJitter), Float(b.positionJitter), 0)
        color = SIMD4(Float(b.red), Float(b.green), Float(b.blue), 1)
        counts = SIMD4(UInt32(inputCount), UInt32(truncatingIfNeeded: stroke.seed), UInt32(truncatingIfNeeded: stroke.seed >> 32), b.renderingSettings.accumulation.rawValue)
        tile = SIMD4(0, 0, Float(width), Float(height))
        let moisture = b.wetSettings
        let activeMedium: BrushMedium = stroke.tool == .eraser || stroke.target == .mask ? .dry : moisture.medium
        wet = SIMD4(Float(moisture.pickup), Float(moisture.mixing), Float(moisture.load), Float(moisture.persistence))
        medium = SIMD4(Float(activeMedium.rawValue), Float(moisture.dilution), Float(moisture.granulation), Float(moisture.edgeDarkening))
        pickupTiles = .zero
        clip = CanvasBoundary(width: width, height: height).gpuClip(relativeTo: .zero)
        let tip = b.stampSettings
        stamp = SIMD4(Float(tip.aspect), Float(tip.angle * .pi / 180), Float(tip.rotation.rawValue), 0)
        images = SIMD4(UInt32(stroke.tipAssets?.count ?? 0), tip.sequence.rawValue, 0, 0)
        ink = SIMD4(Float(d.deposition.rawValue), 0, 0, 0)
        modes = SIMD4(stroke.tool == .eraser ? 1 : 0, stroke.target == .mask ? 1 : 0,
                      d.binary ? 1 : 0, UInt32(capacity))
    }
}
