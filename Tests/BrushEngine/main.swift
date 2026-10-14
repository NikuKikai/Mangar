import Foundation
import CoreGraphics
import Metal
import ImageIO
import UniformTypeIdentifiers

@main
struct BrushEngineChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        BundledBrushTips.resourceDirectory = root.appendingPathComponent("Mangar/Brushes/Presets/Assets")
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        var source = try String(contentsOf: root.appendingPathComponent("Mangar/Rendering/BrushShaderSource.txt"), encoding: .utf8) + "\n" +
            String(contentsOf: root.appendingPathComponent("Mangar/Brushes/GPU/PigmentMixing.txt"), encoding: .utf8) + "\n" +
            String(contentsOf: root.appendingPathComponent("Mangar/Brushes/GPU/BrushKernels.txt"), encoding: .utf8)
        source += """
        kernel void layerCurveCheck(device float4 *out [[buffer(0)]], texture2d<float> curves [[texture(0)]], uint i [[thread_position_in_grid]]) {
            if (i != 0) return;
            LayerCompositeUniforms u = {}; u.padding = 4;
            out[0] = applyLayerCurve(float4(0.1, 0.2, 0.3, 0.5), curves, u.padding);
            out[1] = applyLayerCurve(float4(0), curves, u.padding);
            u.padding = 0;
            out[2] = applyLayerCurve(float4(0.1, 0.2, 0.3, 0.5), curves, u.padding);
        }
        kernel void pigmentMixCheck(device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
            if (i != 0) return;
            out[0] = float4(spectral_mix(float3(1,1,0), float3(0,0,1), 0.5), 1);
            out[1] = float4(spectral_mix(float3(0), float3(0), 0.5), 1);
            out[2] = float4(spectral_mix(float3(1), float3(1), 0.5), 1);
        }
        """
        let library = try await device.makeLibrary(source: source, options: nil)
        let engine = try MetalBrushEngine(device: device, queue: queue, library: library)
        let layer = UUID()
        func command(_ preset: BrushPresetID, _ samples: [StrokeSample], size: Double = 24) -> StrokeCommand {
            var brush = MangaBrushes.configuration(preset)
            brush.size = size; brush.red = 0; brush.green = 0; brush.blue = 0
            let assets = try! BrushResourceStore.shared.assets(for: brush)
            return StrokeCommand(tipAssets: assets, definition: MangaBrushes.definition(preset), layerID: layer,
                                 samples: samples, brush: brush, seed: 123456789, tool: .brush)
        }
        func dot(_ preset: BrushPresetID, pressure: Double = 1, time: Double = 0, altitude: Double = .pi/2) -> StrokeCommand {
            var samples = [StrokeSample(x: 128, y: 128, pressure: pressure, altitude: altitude)]
            if time > 0 { samples.append(StrokeSample(x: 128, y: 128, pressure: pressure, time: time, altitude: altitude)) }
            return command(preset, samples)
        }
        func bytes(_ texture: MTLTexture) -> [UInt8] {
            let channels = texture.pixelFormat == .r8Unorm ? 1 : 4
            var data = [UInt8](repeating: 0, count: 256 * 256 * channels)
            texture.getBytes(&data, bytesPerRow: 256 * channels, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
            return data
        }
        func image(_ result: MetalBrushEngine.Result) -> [TileKey: [UInt8]] {
            engine.synchronize()
            return result.tiles.mapValues(bytes)
        }
        func paint(_ stroke: StrokeCommand, base: [TileKey: MTLTexture] = [:], selection: SelectionSnapshot? = nil) -> MetalBrushEngine.Result {
            engine.finish(stroke, base: base, selection: selection, width: 600, height: 600)
        }
        let key = TileKey(layerID: layer, x: 0, y: 0, target: .content)
        func alpha(_ result: MetalBrushEngine.Result) -> [UInt8] {
            let data = image(result)[key]!
            return stride(from: 3, to: data.count, by: 4).map { data[$0] }
        }
        func area(_ result: MetalBrushEngine.Result) -> Int { alpha(result).filter { $0 > 0 }.count }
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), "FAILED: \(name)")
            FileHandle.standardOutput.write(Data("PASS \(name)\n".utf8))
        }
        let identityEffect = LayerCurveEffect()
        check((0...255).allSatisfy { abs(identityEffect.map(Double($0)/255, channel: .master) - Double($0)/255) < 0.000001 }, "Layer curve identity")
        var effect = LayerCurveEffect(); effect.master = [1, 0.75, 0.5, 0.25, 0]
        let lutDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 256, height: 4, mipmapped: false)
        lutDescriptor.storageMode = .shared; lutDescriptor.usage = .shaderRead
        let lut = device.makeTexture(descriptor: lutDescriptor)!
        let lutValues = effect.lookupTable
        lutValues.withUnsafeBytes { lut.replace(region: MTLRegionMake2D(0, 0, 256, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 1024) }
        let curvePipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "layerCurveCheck")!)
        let curveOutput = device.makeBuffer(length: 48)!
        let curveCommand = queue.makeCommandBuffer()!, curveEncoder = curveCommand.makeComputeCommandEncoder()!
        curveEncoder.setComputePipelineState(curvePipeline); curveEncoder.setBuffer(curveOutput, offset: 0, index: 0); curveEncoder.setTexture(lut, index: 0)
        curveEncoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); curveEncoder.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            curveCommand.addCompletedHandler { _ in continuation.resume() }; curveCommand.commit()
        }
        let curveResult = curveOutput.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3)
        check(abs(curveResult[0].x - 0.4) < 0.0001 && abs(curveResult[0].y - 0.3) < 0.0001 && abs(curveResult[0].z - 0.2) < 0.0001 && curveResult[0].w == 0.5,
            "Metal curve operates on straight color and preserves alpha")
        check(curveResult[1] == .zero && curveResult[2] == SIMD4<Float>(0.1, 0.2, 0.3, 0.5), "Metal curve transparent pixels and disabled bypass")
        var effectLayer = LayerRecord(name: "curve check"); effectLayer.curves = effect
        let decodedEffectLayer = try JSONDecoder().decode(LayerRecord.self, from: JSONEncoder().encode(effectLayer))
        check(decodedEffectLayer.curves == effect, "Layer curve serialization")
        let oldLayerJSON = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"old\",\"kind\":\"paint\",\"isVisible\":true,\"opacity\":1}"
        let oldLayer = try JSONDecoder().decode(LayerRecord.self, from: Data(oldLayerJSON.utf8))
        check(oldLayer.curves == nil, "Legacy layer has no curve effect")

        func region(_ source: [SelectionTileKey: Data], width: Int = 32, height: Int = 32, gap: Int = 0,
                    selection: [SelectionTileKey: Data]? = nil, defaultCoverage: UInt8 = 255) -> [FillSpan] {
            BucketRegionResolver.resolve(width: width, height: height, x: 16, y: 16, target: .content,
                source: source, settings: BucketSettings(tolerance: 0, closeGap: gap), selection: selection, selectionDefault: defaultCoverage)
        }
        func countRegion(_ spans: [FillSpan]) -> Int { spans.reduce(0) { $0 + $1.x1 - $1.x0 } }
        var boundary = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 8...24 { for x in 8...24 where x == 8 || x == 24 || y == 8 || y == 24 { boundary[(y*256+x)*4+3] = 255 } }
        let regionKey = SelectionTileKey(x: 0, y: 0)
        check(countRegion(region([regionKey: Data(boundary)])) == 15 * 15, "Bucket enclosed region")
        boundary[(8*256+16)*4+3] = 0
        let openCount = countRegion(region([regionKey: Data(boundary)]))
        let closed = region([regionKey: Data(boundary)], gap: 2)
        check(openCount > 800 && countRegion(closed) < 250 && countRegion(closed) >= 225, "Bucket close gap stops leakage and recovers edge strip")
        boundary[(8*256+15)*4+3] = 0; boundary[(8*256+17)*4+3] = 0
        check(countRegion(region([regionKey: Data(boundary)], gap: 2)) > 800, "Bucket preserves gaps larger than closure diameter")
        check(countRegion(region([regionKey: Data(boundary)], gap: 4)) < 260, "Bucket closure strength bridges larger gap")
        check(countRegion(region([:], width: 600, height: 300)) == 600 * 300, "Bucket sparse transparent canvas across tiles and partial page edges")
        var wallTile = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 0..<256 { wallTile[(y*256+44)*4+3] = 255 }
        let acrossWall = region([SelectionTileKey(x:1,y:0):Data(wallTile), SelectionTileKey(x:1,y:1):Data(wallTile)], width:600,height:300)
        check(countRegion(acrossWall) == 300 * 300 && acrossWall.allSatisfy { $0.x1 <= 300 }, "Bucket connected region crosses sparse tile seam and stops at distant wall")
        check(countRegion(region([:], selection: [:], defaultCoverage: 0)) == 0, "Bucket empty selection is a no-op")
        var selectedRegion = [UInt8](repeating: 0, count: 256 * 256)
        for y in 12..<20 { for x in 12..<20 { selectedRegion[y*256+x] = 128 } }
        check(countRegion(region([:], selection: [regionKey: Data(selectedRegion)], defaultCoverage: 0)) == 64, "Bucket selection connectivity accepts fractional coverage")
        check(countRegion(BucketRegionResolver.resolve(width: 32, height: 32, x: 16, y: 16, target: .mask, source: [:], settings: BucketSettings())) == 1024,
            "Bucket implicit mask is white")
        let fillRecord = BucketFillCommand(layerID: layer, spans: closed, brush: MangaBrushes.configuration(.gPen), target: .content, erases: false)
        let restoredFill = try JSONDecoder().decode(BucketFillCommand.self, from: JSONEncoder().encode(fillRecord))
        check(restoredFill.spans == closed, "Bucket command freezes compact region for replay")
        check(MemoryLayout<BrushGPUInput>.stride == 32 && MemoryLayout<BrushGPUUniforms>.stride == 224, "Metal ABI")
        let lowG = area(paint(dot(.gPen, pressure: 0.15)))
        let highG = area(paint(dot(.gPen)))
        check(highG > lowG * 8, "G pen pressure width")
        let binary = alpha(paint(dot(.binaryPen)))
        check(binary.contains(255) && binary.allSatisfy { $0 == 0 || $0 == 255 }, "Binary pen has no antialiasing")
        let pencil = alpha(paint(dot(.pencil)))
        check(Set(pencil.filter { $0 > 0 }).count > 8, "Pencil grain and flow")
        let upright = area(paint(dot(.pencil)))
        let tilted = area(paint(dot(.pencil, altitude: 0.15)))
        check(tilted > upright * 3 / 2, "Pencil tilt footprint")
        func height(_ alpha: [UInt8]) -> Int {
            let rows = (0..<256).filter { y in (0..<256).contains { x in alpha[y*256+x] > 0 } }
            return (rows.last ?? 0) - (rows.first ?? 0)
        }
        check(height(alpha(paint(dot(.pencil, altitude: 0.15)))) > height(alpha(paint(dot(.pencil)))) * 3 / 2,
              "Pencil tilt expands diameter as well as ellipse aspect")
        var tilting = dot(.pencil)
        tilting.samples.append(StrokeSample(x: 128, y: 128, pressure: 1, time: 0.1, altitude: 0.15))
        check(height(alpha(paint(tilting))) > height(alpha(paint(dot(.pencil)))) * 3 / 2,
              "Stationary pencil tilt updates contact footprint")
        check(area(paint(dot(.gPen, altitude: 0.15))) == area(paint(dot(.gPen))), "Ink pen does not inherit pencil tilt sizing")
        check(area(paint(dot(.technicalPen, pressure: 0.05))) == area(paint(dot(.technicalPen))), "Technical pen fixed width")
        let firstInk = area(paint(dot(.technicalPen)))
        let held = paint(dot(.technicalPen, time: 1))
        check(area(held) > firstInk * 3 / 2, "Stationary time input pools ink")
        var flat = dot(.gPen, time: 1)
        flat.samples += [StrokeSample(x: 180, y: 128, pressure: 1, time: 1.1), StrokeSample(x: 128, y: 128, pressure: 1, time: 1.2)]
        flat.brush.opacity = 0.4
        check(alpha(paint(flat)).max()! <= 102, "Flat overlap opacity cap")
        var flowing = dot(.technicalPen, time: 1)
        flowing.brush.opacity = 0.3
        let ink = alpha(paint(flowing))
        check(ink.max()! <= 77 && ink.max()! > 60, "Solid ink respects explicit stroke opacity")

        for preset in [BrushPresetID.gPen, .technicalPen] {
            var lowFlow = dot(preset)
            lowFlow.brush.flow = 0.08
            lowFlow.brush.red = 0.2; lowFlow.brush.green = 0.4; lowFlow.brush.blue = 0.8
            let painted = paint(lowFlow)
            let data = image(painted)[key]!
            let index = (128*256+128)*4
            check(Array(data[index..<index+4]) == [51,102,204,255], "\(preset.rawValue) low supply keeps original ink RGB and opaque core")
            check(area(painted) < area(paint(dot(preset))) / 2, "\(preset.rawValue) supply changes footprint instead of dilution")
        }
        func line(duration: Double, supply: Double = 1) -> StrokeCommand {
            var stroke = command(.technicalPen, [StrokeSample(x: 40,y: 128,pressure: 1),
                StrokeSample(x: 220,y: 128,pressure: 1,time: duration)])
            stroke.brush.flow = supply
            return stroke
        }
        let slow = alpha(paint(line(duration: 1)))
        let fast = alpha(paint(line(duration: 0.06)))
        func width(_ data: [UInt8], at x: Int) -> Int {
            (0..<256).filter { data[$0*256+x] > 127 }.count
        }
        check(width(fast, at: 180) < width(slow, at: 180) * 3 / 4, "Technical pen thins with velocity")
        check(fast[128*256+180] == 255 && slow[128*256+180] == 255, "Fast ink stays opaque")
        let thin = alpha(paint(line(duration: 0.1, supply: 0.1)))
        check((50..<215).allSatisfy { thin[128*256+$0] >= 250 }, "Narrow flowing ink has continuous solid center")

        check(MemoryLayout<BrushGPUCurve>.stride == 64, "GPU response curve ABI")
        for parameter in BrushParameter.allCases {
            for input in BrushDynamicInput.allCases {
                var controlled = dot(.binaryPen)
                controlled.brush.size = 64
                controlled.brush.opacity = 0.8
                var dynamics = BrushDynamics()
                let factor = parameter == .flow ? 0.25 : 0.5
                dynamics[parameter][input] = BrushResponseCurve(enabled: true, outputs: [Double](repeating: factor, count: 5))
                controlled.brush.resolvedDynamics = dynamics
                let pixels = alpha(paint(controlled))
                let expectedAlpha = parameter == .opacity ? 102 : 204
                check(Int(pixels[128*256+128]) == expectedAlpha,
                    "\(parameter.rawValue)/\(input.rawValue) preserves base times curve alpha semantics")
                if parameter != .opacity {
                    check(width(pixels, at: 128) == 32,
                        "\(parameter.rawValue)/\(input.rawValue) multiplies size or ink supply")
                }
                controlled.brush.resolvedDynamics[parameter][input].enabled = false
                let disabled = alpha(paint(controlled))
                check(width(disabled, at: 128) == 64 && disabled[128*256+128] == 204,
                    "\(parameter.rawValue)/\(input.rawValue) disabled means factor one")
            }
        }
        var multiplied = dot(.binaryPen)
        multiplied.brush.size = 64
        var combined = BrushDynamics()
        for input in BrushDynamicInput.allCases {
            combined.size[input] = BrushResponseCurve(enabled: true, outputs: [0.5,0.5,0.5,0.5,0.5])
        }
        multiplied.brush.resolvedDynamics = combined
        check(width(alpha(paint(multiplied)), at: 128) == 8, "Three enabled curves multiply rather than add")
        combined.size.pressure.outputs = [0,0,0,0,0]
        multiplied.brush.resolvedDynamics = combined
        check(area(paint(multiplied)) == 0, "Zero size multiplier leaves no residual dot")
        var growth = dot(.binaryPen)
        growth.brush.size = 64
        growth.samples[0].x = 240
        var grow = BrushDynamics()
        grow.size.tilt = BrushResponseCurve(enabled: true, outputs: [3,3,3,3,3])
        growth.brush.resolvedDynamics = grow
        let growing = image(paint(growth))
        check(growing.contains { $0.key.x == 1 && $0.value.contains(255) }, "Curve growth is included in tile scheduling bounds")
        var inkOff = line(duration: 0.06)
        inkOff.brush.resolvedDynamics = BrushDynamics()
        var slowOff = inkOff
        slowOff.id = UUID()
        slowOff.samples[1].time = 1
        check(width(alpha(paint(inkOff)), at: 180) == width(alpha(paint(slowOff)), at: 180),
            "Disabling velocity curve removes hidden technical pen size response")
        var pressureOff = dot(.gPen, pressure: 0.1)
        pressureOff.brush.resolvedDynamics = BrushDynamics()
        var pressureHigh = pressureOff; pressureHigh.id = UUID(); pressureHigh.samples[0].pressure = 1
        check(area(paint(pressureOff)) == area(paint(pressureHigh)), "Disabling pressure curve removes hidden G pen response")
        var tiltedOff = dot(.pencil, altitude: 0.15)
        tiltedOff.brush.resolvedDynamics = BrushDynamics()
        var roundTip = tiltedOff.brush.tipSettings; roundTip.tiltElongation = 0
        tiltedOff.brush.tipSettings = roundTip; tiltedOff.definition = tiltedOff.brush.definition
        var verticalOff = tiltedOff; verticalOff.id = UUID(); verticalOff.samples[0].altitude = .pi/2
        check(area(paint(tiltedOff)) == area(paint(verticalOff)), "Disabling tilt curve removes hidden pencil diameter response")
        let descending = BrushResponseCurve(enabled: true, outputs: [1,0.75,0.5,0.25,0])
        let peaked = BrushResponseCurve(enabled: true, outputs: [0,0.8,0.2,1,0.1])
        check((0...1000).allSatisfy { (0...1).contains(descending.map(Double($0)/1000)) &&
            (0...1).contains(peaked.map(Double($0)/1000)) }, "Smooth decreasing and nonmonotonic curves do not overshoot")
        var dynamicOpacity = dot(.pencil, time: 1)
        dynamicOpacity.brush.opacity = 0.6
        var pigmentDynamics = BrushDynamics()
        pigmentDynamics.opacity.tilt = BrushResponseCurve(enabled: true, outputs: [0.5,0.5,0.5,0.5,0.5])
        dynamicOpacity.brush.resolvedDynamics = pigmentDynamics
        var tipSettings = dynamicOpacity.brush.tipSettings
        tipSettings.timeRate = 60; tipSettings.grain = 0
        dynamicOpacity.brush.tipSettings = tipSettings; dynamicOpacity.definition = dynamicOpacity.brush.definition
        check(alpha(paint(dynamicOpacity)).max()! <= 77, "Pigment flow respects dynamic opacity cap")

        var path: [StrokeSample] = []
        for i in 0...40 {
            path.append(StrokeSample(x: 20 + Double(i) * 12, y: 180 + sin(Double(i) * 0.3) * 40,
                pressure: 0.2 + Double(i % 7) / 9, time: Double(i) / 60, altitude: 0.8, azimuth: 0.4))
        }
        for preset in BrushPresetID.allCases {
            var stroke = command(preset, path)
            stroke.brush.sizeJitter = 0.3; stroke.brush.opacityJitter = 0.25; stroke.brush.positionJitter = 0.2
            var replayDynamics = stroke.brush.resolvedDynamics
            replayDynamics.opacity.tilt = BrushResponseCurve(enabled: true, outputs: [1,0.8,0.6,0.4,0.2])
            replayDynamics.flow.speed = BrushResponseCurve(enabled: true, outputs: [0.3,0.8,0.5,0.9,0.4])
            stroke.brush.resolvedDynamics = replayDynamics
            let full = image(paint(stroke))
            for count in 1...path.count {
                var prefix = stroke; prefix.samples = Array(path.prefix(count))
                _ = engine.update(prefix, base: [:], selection: nil, width: 600, height: 600)
            }
            let incremental = image(paint(stroke))
            check(full == incremental, "\(preset.rawValue) deterministic incremental replay")
            check(full.keys.contains { $0.x == 1 }, "\(preset.rawValue) crosses tile boundary")
        }
        // R8 selection: repeated dabs may not compound fractional clipping.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let mask = device.makeTexture(descriptor: descriptor)!
        let maskData = [UInt8](repeating: 128, count: 256*256)
        maskData.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0,0,256,256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256) }
        func runRegionKernel(maskTarget: Bool, erases: UInt32) async throws -> [UInt8] {
            let fmt: MTLPixelFormat = maskTarget ? .r8Unorm : .rgba8Unorm
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 256, height: 256, mipmapped: false)
            desc.storageMode = .shared; desc.usage = [.shaderRead, .shaderWrite]
            let base = device.makeTexture(descriptor: desc)!, out = device.makeTexture(descriptor: desc)!
            let channelCount = maskTarget ? 1 : 4
            let initial = [UInt8](repeating: maskTarget || erases != 0 ? 255 : 0, count: 256 * 256 * channelCount)
            initial.withUnsafeBytes { base.replace(region: MTLRegionMake2D(0,0,256,256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256 * channelCount) }
            let shape = device.makeTexture(descriptor: descriptor)!
            let full = [UInt8](repeating: 255, count: 256*256)
            full.withUnsafeBytes { shape.replace(region: MTLRegionMake2D(0,0,256,256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256) }
            let pipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: maskTarget ? "fillLassoLayerMask" : "fillLasso")!)
            let c = queue.makeCommandBuffer()!, e = c.makeComputeCommandEncoder()!
            var color = SIMD4<Float>(0.2, 0.6, 0.8, 0.5), erase = erases
            var bounds: [UInt32] = [256,256,0,0]
            let b = device.makeBuffer(bytes: &bounds, length: 16)!
            e.setComputePipelineState(pipeline); e.setTexture(base,index:0); e.setTexture(shape,index:1); e.setTexture(mask,index:2); e.setTexture(out,index:3)
            e.setBytes(&color,length:16,index:0); e.setBuffer(b,offset:0,index:1); e.setBytes(&erase,length:4,index:2)
            e.dispatchThreads(MTLSize(width:256,height:256,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1)); e.endEncoding()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in c.addCompletedHandler { _ in continuation.resume() }; c.commit() }
            check(c.status == .completed, "Bucket Metal dispatch completed")
            let extents = b.contents().bindMemory(to: UInt32.self,capacity:4)
            check(extents[0] == 0 && extents[1] == 0 && extents[2] == 256 && extents[3] == 256, "Bucket GPU changed bounds")
            return bytes(out)
        }
        let regionPaint = try await runRegionKernel(maskTarget:false,erases:0)
        check(regionPaint[3] == 64 && abs(Int(regionPaint[0])-13) <= 1 && abs(Int(regionPaint[1])-38) <= 1,
            "Bucket GPU applies fractional selection and opacity once")
        let regionErase = try await runRegionKernel(maskTarget:false,erases:1)
        check(regionErase[3] == 191, "Bucket transparent color erases by selected coverage")
        let regionMask = try await runRegionKernel(maskTarget:true,erases:0)
        check(abs(Int(regionMask[0])-204) <= 1, "Bucket R8 mask fill preserves partial coverage")
        let regionMaskErase = try await runRegionKernel(maskTarget:true,erases:1)
        check(regionMaskErase[0] == 255, "Bucket R8 transparent color restores white")

        struct TintQuad { var origin = SIMD2<Float>(0,0); var size = SIMD2<Float>(256,256); var viewport = SIMD2<Float>(256,256); var zoom: Float = 1; var rotation: Float = 0; var pan = SIMD2<Float>(0,0) }
        struct TintUniforms { var origin = SIMD2<Float>(0,0); var canvas = SIMD2<Float>(256,256); var zoom: Float = 1; var phase: Float = 0 }
        let tintInput = device.makeTexture(descriptor: descriptor)!
        var tintValues = [UInt8](repeating: 0, count: 256*256)
        for y in 0..<256 { for x in 0..<256 { tintValues[y*256+x] = [0,64,128,255][x/64] } }
        tintValues.withUnsafeBytes { tintInput.replace(region: MTLRegionMake2D(0,0,256,256), mipmapLevel:0, withBytes:$0.baseAddress!, bytesPerRow:256) }
        let tintDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width:256, height:256, mipmapped:false)
        tintDesc.storageMode = .shared; tintDesc.usage = .renderTarget
        let tintOut = device.makeTexture(descriptor:tintDesc)!
        let tintPipelineDesc = MTLRenderPipelineDescriptor()
        tintPipelineDesc.vertexFunction = library.makeFunction(name:"tileVertex"); tintPipelineDesc.fragmentFunction = library.makeFunction(name:"selectionTintFragment")
        tintPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let tintPipeline = try await device.makeRenderPipelineState(descriptor:tintPipelineDesc)
        let tintPass = MTLRenderPassDescriptor(); tintPass.colorAttachments[0].texture = tintOut
        tintPass.colorAttachments[0].loadAction = .clear; tintPass.colorAttachments[0].storeAction = .store
        let tc = queue.makeCommandBuffer()!, te = tc.makeRenderCommandEncoder(descriptor:tintPass)!
        var tq = TintQuad(), tu = TintUniforms()
        te.setRenderPipelineState(tintPipeline); te.setVertexBytes(&tq,length:MemoryLayout<TintQuad>.stride,index:0)
        te.setFragmentBytes(&tu,length:MemoryLayout<TintUniforms>.stride,index:0); te.setFragmentTexture(tintInput,index:0)
        te.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); te.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in tc.addCompletedHandler { _ in continuation.resume() }; tc.commit() }
        let tintBytes = bytes(tintOut)
        let observedTint = [32,96,160,224].map { Int(tintBytes[(128*256+$0)*4+3]) }
        check(observedTint == [0,64,128,255], "Selection tint renders continuous R8 values including below one half")
        let selectionKey = SelectionTileKey(x: 0, y: 0)
        let selection = SelectionSnapshot(defaultCoverage: 0, tiles: [selectionKey: mask],
            tileBounds: [selectionKey: CGRect(x: 0, y: 0, width: 256, height: 256)],
            bounds: CGRect(x: 0, y: 0, width: 256, height: 256), outlineKeys: [])
        check(alpha(paint(dot(.technicalPen, time: 1), selection: selection)).max()! <= 128, "Fractional selection multiplied once")
        var masked = dot(.gPen); masked.target = .mask
        let maskKey = TileKey(layerID: layer, x: 0, y: 0, target: .mask)
        let maskedResult = paint(masked, selection: selection)
        let maskedBytes = image(maskedResult)[maskKey]!
        check(maskedBytes[128*256+128] == 127 && maskedBytes[0] == 255, "R8 mask painting and default white")
        masked.tool = .eraser
        let erasedMask = image(paint(masked, base: maskedResult.tiles))[maskKey]!
        check(erasedMask[128*256+128] == 255, "Mask eraser restores white")
        let base = paint(dot(.gPen))
        let baseImage = image(base)
        var eraser = dot(.gPen); eraser.tool = .eraser
        _ = engine.update(eraser, base: base.tiles, selection: nil, width: 600, height: 600)
        engine.cancel(); engine.synchronize()
        check(base.tiles.mapValues(bytes) == baseImage, "Cancelled preview never modifies committed tiles")
        let erased = paint(eraser, base: base.tiles)
        check(alpha(erased)[128*256+128] == 0, "Content eraser")
        var preview = dot(.gPen)
        let live = engine.update(preview, base: [:], selection: nil, width: 600, height: 600)
        let final = paint(preview)
        check(live.tiles[key] === final.tiles[key], "Commit promotes preview texture without redraw")
        engine.synchronize()
        let measured = final.measuredBounds[key]!.contents().bindMemory(to: UInt32.self, capacity: 4)
        check(measured[0] >= 115 && measured[2] <= 141 && measured[2] > measured[0], "GPU pixel bounding box")
        preview.samples = [StrokeSample(x: 255, y: 255, pressure: 1)]
        let crossing = image(paint(preview))
        check(crossing.keys.contains { $0.x == 1 && $0.y == 1 }, "Four-tile dab")
        let tracker = BrushChangeTracker()
        var trackedTiles: [TileKey: MTLTexture] = [:]
        var dirty: [TileKey: CGRect] = [:]
        var edgeDot = dot(.gPen)
        edgeDot.samples = [StrokeSample(x: 258, y: 258, pressure: 0.1)]
        let scheduled = paint(edgeDot)
        tracker.record(scheduled, tiles: trackedTiles, dirty: dirty)
        trackedTiles.merge(scheduled.tiles) { _, new in new }
        dirty = scheduled.dirtyBounds
        engine.synchronize()
        tracker.resolve(tiles: &trackedTiles, dirty: &dirty)
        check(trackedTiles.count == 1 && trackedTiles.keys.first!.x == 1 &&
            dirty.values.first!.width < 5, "Readback refines GPU bounds and prunes untouched candidate tiles")
        var cursorStroke = dot(.gPen)
        cursorStroke.brush.flow = 0.25
        let observedRadius: CGFloat = await withCheckedContinuation { continuation in
            engine.onTipRadius = { id, radius in
                precondition(id == cursorStroke.id)
                engine.onTipRadius = nil
                continuation.resume(returning: radius)
            }
            _ = engine.update(cursorStroke, base: [:], selection: nil, width: 600, height: 600)
        }
        engine.cancel()
        check(abs(observedRadius - 6) < 0.01, "Async cursor readback reports actual ink footprint")
        // Identical explicit settings must render identically regardless of preset identity.
        var custom = dot(.gPen, time: 0.2)
        custom.brush.wetSettings = BrushWetSettings()
        custom.brush.stampSettings = BrushStampSettings()
        custom.brush.resolvedDynamics = BrushDynamics()
        custom.brush.tipSettings = BrushTipSettings(hardness: 0.6, grain: 0.2, timeRate: 60)
        custom.brush.opacity = 0.3; custom.brush.flow = 0.4
        for deposition in BrushDeposition.allCases {
            for binary in [false, true] {
                for mode in BrushAccumulation.allCases {
                    custom.brush.renderingSettings = BrushRenderingSettings(deposition: deposition, binary: binary, accumulation: mode)
                    custom.definition = custom.brush.definition
                    let expected = image(paint(custom))
                    for preset in BrushPresetID.allCases {
                        var other = custom
                        other.brush.preset = preset; other.definition = other.brush.definition
                        check(image(paint(other)) == expected, "Explicit rendering settings ignore preset identity: \(preset)/\(deposition)/\(binary)/\(mode)")
                    }
                }
            }
        }
        custom.brush.tipSettings = BrushTipSettings(timeRate: 60)
        custom.brush.flow = 1
        custom.brush.renderingSettings = BrushRenderingSettings(deposition: .solidInk, accumulation: .flat)
        custom.definition = custom.brush.definition
        let flatInk = alpha(paint(custom)).max()!
        custom.brush.renderingSettings.accumulation = .flow
        let flowInk = alpha(paint(custom)).max()!
        custom.brush.renderingSettings.accumulation = .buildUp
        let buildInk = alpha(paint(custom)).max()!
        check(flatInk <= 77 && flowInk <= 77 && buildInk > 77, "Ink accumulation is editable and respects explicit opacity semantics")
        let solidTip = try BrushTipAsset(width: 16, height: 16, coverage: Data(repeating: 255, count: 256))
        let faintTip = try BrushTipAsset(width: 16, height: 16, coverage: Data(repeating: 64, count: 256))
        let halfTip = try BrushTipAsset(width: 16, height: 16,
            coverage: Data((0..<256).map { $0 < 128 ? UInt8(255) : UInt8(0) }))
        func stamp(_ assets: [BrushTipAsset]) -> StrokeCommand {
            var value = dot(.gPen)
            value.brush.size = 64; value.brush.flow = 1; value.brush.opacity = 1
            value.brush.resolvedDynamics = BrushDynamics(); value.brush.tipSettings = BrushTipSettings()
            value.brush.renderingSettings = BrushRenderingSettings(deposition: .pigment)
            value.brush.stampSettings = BrushStampSettings(assetIDs: assets.map(\.id), rotation: .fixed)
            value.definition = value.brush.definition; value.tipAssets = assets
            return value
        }
        let square = stamp([solidTip])
        let squarePixels = alpha(paint(square))
        check(squarePixels[154*256+154] > 240, "Image tip covers square corners outside a procedural circle")
        var skinny = square; skinny.brush.stampSettings.aspect = 0.5
        let skinnyPixels = alpha(paint(skinny))
        check((0..<256).filter { skinnyPixels[128*256+$0] > 127 }.count == 32, "Image aspect controls footprint width")
        skinny.brush.stampSettings.angle = 90
        let rotatedPixels = alpha(paint(skinny))
        check((0..<256).filter { rotatedPixels[128*256+$0] > 127 }.count == 64, "Fixed image angle rotates footprint")
        let halfPixels = alpha(paint(stamp([halfTip])))
        check(halfPixels[112*256+128] > 240 && halfPixels[144*256+128] == 0, "Image tip preserves source row orientation")
        var direction = square
        direction.brush.stampSettings.aspect = 0.25; direction.brush.stampSettings.rotation = .direction
        direction.samples = [StrokeSample(x: 128, y: 80, pressure: 1), StrokeSample(x: 128, y: 128, pressure: 1, time: 0.5)]
        let directionalPixels = alpha(paint(direction))
        check((0..<256).filter { directionalPixels[128*256+$0] > 127 }.count > 55, "Image tip follows vertical travel direction")
        var ordered = stamp([solidTip, faintTip])
        ordered.brush.size = 24; ordered.brush.spacing = 1
        ordered.samples = [StrokeSample(x: 128, y: 128, pressure: 1), StrokeSample(x: 224, y: 128, pressure: 1, time: 0.4)]
        let sequencePixels = alpha(paint(ordered))
        check(sequencePixels[128*256+128] == 255 && sequencePixels[128*256+152] == 64 &&
              sequencePixels[128*256+176] == 255, "Multiple image tips alternate in order")
        for mode in BrushTipSequence.allCases {
            ordered.brush.stampSettings.sequence = mode
            ordered.samples = (0...40).map { StrokeSample(x: 220 + Double($0)*4, y: 180 + sin(Double($0)/4)*30,
                pressure: 1, time: Double($0)*0.01) }
            let expected = image(paint(ordered))
            var split = ordered; split.id = UUID(); split.samples = []
            for sample in ordered.samples {
                split.samples.append(sample)
                _ = engine.update(split, base: [:], selection: nil, width: 600, height: 600)
            }
            check(image(paint(split)) == expected, "Image selection and direction replay deterministically: \(mode)")
            check(expected.keys.contains { $0.x == 1 }, "Image tip crosses tile boundaries")
        }
        var corner = square
        corner.brush.stampSettings.angle = 45
        corner.samples = [StrokeSample(x: 215, y: 128, pressure: 1)]
        check(image(paint(corner)).keys.contains { $0.x == 1 }, "Rotated square corners schedule neighboring tile")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Mangar-resource-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let resourceStore = BrushResourceStore(root: scratch)
        try resourceStore.store(solidTip); try resourceStore.store(solidTip)
        let tipFiles = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("tips").path)
        check(tipFiles.count == 1,
              "Tip assets deduplicate by immutable content hash")
        var resourceConfig = square.brush
        let originalRevision = BrushRecipe(resourceConfig).revision
        let resource = try resourceStore.create(name: "Test", configuration: resourceConfig)
        resourceConfig = try resourceStore.configuration(resource, color: resourceConfig)
        try resourceStore.rename(resource.id, name: "Renamed")
        resourceConfig.size = 80
        try resourceStore.update(resourceConfig)
        let reloaded = BrushResourceStore(root: scratch)
        let listed = try reloaded.resources()
        check(listed[0].id == resource.id && listed[0].name == "Renamed" && listed[0].revision != originalRevision,
              "Brush rename preserves ID; edits publish a new revision")
        let oldRecipe = try reloaded.configuration(resource, color: resourceConfig)
        check(oldRecipe.size == 64,
              "Old recipe revision remains immutable")
        let loadedTips = try reloaded.assets(for: resourceConfig)
        check(loadedTips == [solidTip], "Raw R8 tip assets reload with integrity validation")
        let savedSnapshot = try JSONEncoder().encode(square)
        resourceConfig.stampSettings.assetIDs = []
        try reloaded.update(resourceConfig)
        let frozen = try JSONDecoder().decode(StrokeCommand.self, from: savedSnapshot)
        check(image(paint(frozen)) == image(paint(square)), "Frozen history survives resource edits")
        let reset = try reloaded.reset(resource.id, color: resourceConfig)
        check(reset.size == 64 && reset.stampSettings.assetIDs == [solidTip.id], "Reset restores copied recipe and tip references")
        resourceConfig.red = 0.8
        check(BrushRecipe(resourceConfig).revision == BrushRecipe({ var b = resourceConfig; b.red = 0; return b }()).revision,
              "Resource recipe revision excludes current color")
        let imageURL = scratch.appendingPathComponent("import.png")
        let rgba: [UInt8] = [0,0,0,255, 255,255,255,255, 0,0,0,128, 0,0,0,0]
        let imageProvider = CGDataProvider(data: Data(rgba) as CFData)!
        let importImage = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: imageProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, importImage, nil)
        check(CGImageDestinationFinalize(destination), "PNG import fixture writes")
        let importedAlpha = try BrushTipImporter.load(imageURL, channel: .alpha)
        let importedDarkness = try BrushTipImporter.load(imageURL, channel: .darkness)
        check(Array(importedAlpha.coverage) == [255,255,128,0], "Alpha image import preserves orientation and coverage")
        check(Array(importedDarkness.coverage) == [255,0,128,0], "Black grayscale image import combines luminance with alpha")
        let tipURL = scratch.appendingPathComponent("tips/" + solidTip.id + ".tip")
        try Data([1,2,3]).write(to: tipURL)
        do { _ = try BrushResourceStore(root: scratch).assets(for: reset); check(false, "Corrupt tip must fail") }
        catch { print("PASS Corrupt tip is rejected") }
        let spectralPipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "pigmentMixCheck")!)
        let spectralResults = device.makeBuffer(length: 48, options: .storageModeShared)!
        let spectralCommand = queue.makeCommandBuffer()!
        let spectralEncoder = spectralCommand.makeComputeCommandEncoder()!
        spectralEncoder.setComputePipelineState(spectralPipeline); spectralEncoder.setBuffer(spectralResults, offset: 0, index: 0)
        spectralEncoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        spectralEncoder.endEncoding()
        await withCheckedContinuation { continuation in
            spectralCommand.addCompletedHandler { _ in continuation.resume() }
            spectralCommand.commit()
        }
        let mixed = spectralResults.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3)
        check(mixed[0].y > mixed[0].x + 0.08 && mixed[0].y > mixed[0].z + 0.08, "Spectral yellow and blue mix to green")
        check(mixed[1] == SIMD4(0,0,0,1) && mixed[2] == SIMD4(1,1,1,1), "Spectral equal-color black/white endpoints stay exact")
        var blueSource = command(.binaryPen, [StrokeSample(x: 80, y: 128, pressure: 1), StrokeSample(x: 285, y: 128, pressure: 1, time: 0.4)], size: 90)
        blueSource.brush.blue = 1
        let substrate = paint(blueSource)
        let substrateImage = image(substrate)
        func wetStroke(_ mode: BrushMedium = .oil) -> StrokeCommand {
            var stroke = dot(.gPen)
            stroke.brush.size = 36; stroke.brush.spacing = 0.15; stroke.brush.flow = 1
            stroke.brush.red = 1; stroke.brush.green = 1; stroke.brush.blue = 0
            stroke.brush.resolvedDynamics = BrushDynamics()
            stroke.brush.renderingSettings = BrushRenderingSettings(deposition: .pigment, accumulation: .flow)
            stroke.brush.wetSettings = BrushWetSettings(medium: mode, pickup: 0.6, mixing: 1, load: 1,
                persistence: 0.8, dilution: 0, granulation: 0, edgeDarkening: 0)
            stroke.definition = stroke.brush.definition
            return stroke
        }
        func pixel(_ result: MetalBrushEngine.Result, x: Int, y: Int = 128) -> [UInt8] {
            let tile = image(result)[TileKey(layerID: layer, x: x/256, y: y/256)]!
            let offset = ((y%256)*256 + x%256)*4
            return Array(tile[offset..<(offset+4)])
        }
        let wetDot = paint(wetStroke(), base: substrate.tiles)
        let mixedPixel = pixel(wetDot, x: 128)
        check(mixedPixel[1] > mixedPixel[0] + 15 && mixedPixel[1] > mixedPixel[2] + 15,
              "Wet brush picks up blue substrate and deposits green pigment")
        var carrier = wetStroke()
        carrier.brush.wetSettings.load = 0; carrier.brush.wetSettings.pickup = 1
        carrier.samples = (0...20).map { StrokeSample(x: 260 + Double($0)*7, y: 128, pressure: 1, time: Double($0)*0.01) }
        let carried = paint(carrier, base: substrate.tiles)
        let carriedPixel = pixel(carried, x: 370)
        check(carriedPixel[3] > 20 && carriedPixel[2] >= carriedPixel[3] - 1 && carriedPixel[0] == 0,
              "Zero-load brush carries original substrate color into transparent canvas across tiles")
        var noPaint = carrier
        noPaint.brush.wetSettings.pickup = 0
        check(alpha(paint(noPaint)).allSatisfy { $0 == 0 }, "Zero load and zero pickup produces no paint")
        var exhausted = wetStroke()
        exhausted.brush.size = 20; exhausted.brush.wetSettings.pickup = 0
        exhausted.brush.wetSettings.persistence = 0
        exhausted.samples = [StrokeSample(x: 20, y: 128, pressure: 1), StrokeSample(x: 500, y: 128, pressure: 1, time: 1)]
        let dryTrail = paint(exhausted)
        check(pixel(dryTrail, x: 25)[3] > pixel(dryTrail, x: 460)[3] + 100,
              "Finite pigment load depletes along travel")
        var water = wetStroke(.watercolor)
        water.brush.wetSettings.pickup = 0
        let undiluted = alpha(paint(water)).max()!
        water.brush.wetSettings.dilution = 1
        check(alpha(paint(water)).max()! < undiluted / 3, "Water dilution produces a translucent wash")
        water.brush.wetSettings.dilution = 0; water.brush.wetSettings.edgeDarkening = 1
        let ring = alpha(paint(water))
        check(ring[128*256+141] > ring[128*256+128] + 50, "Watercolor rim deposits more pigment than center")
        water.brush.wetSettings.edgeDarkening = 0; water.brush.wetSettings.granulation = 1
        let grains = alpha(paint(water))
        check(Set((120...135).map { grains[128*256+$0] }).count > 8, "Watercolor granulation varies with fixed paper coordinates")
        var clippedWet = wetStroke()
        let unselectedAlpha = alpha(paint(clippedWet))[128*256+128]
        let selectedAlpha = alpha(paint(clippedWet, selection: selection))[128*256+128]
        check(abs(Int(selectedAlpha) - Int(unselectedAlpha)/2) <= 1, "Wet fractional selection applies once")
        clippedWet.tool = .eraser
        let wetErased = pixel(paint(clippedWet, base: substrate.tiles), x: 128)
        check(wetErased[3] == 0, "Wet brush settings do not alter eraser semantics")
        clippedWet.tool = .brush; clippedWet.target = .mask; clippedWet.brush.red = 0
        let wetMask = image(paint(clippedWet))[TileKey(layerID: layer, x: 0, y: 0, target: .mask)]!
        check(wetMask[128*256+128] == 0 && wetMask[0] == 255, "Wet brush settings do not mix mask values")
        for mode in [BrushMedium.oil, .watercolor] {
            var stroke = wetStroke(mode)
            stroke.samples = carrier.samples
            if mode == .watercolor { stroke.brush.wetSettings.dilution = 0.7; stroke.brush.wetSettings.granulation = 0.4; stroke.brush.wetSettings.edgeDarkening = 0.5 }
            let expected = image(paint(stroke, base: substrate.tiles))
            var incremental = stroke; incremental.id = UUID(); incremental.samples = []
            for sample in stroke.samples {
                incremental.samples.append(sample)
                _ = engine.update(incremental, base: substrate.tiles, selection: nil, width: 600, height: 600)
            }
            let replayed = image(paint(incremental, base: substrate.tiles))
            if replayed != expected {
                for (tile, bytes) in expected {
                    if let actual = replayed[tile] {
                        let differences = zip(bytes, actual).map { abs(Int($0) - Int($1)) }.filter { $0 > 0 }
                        FileHandle.standardOutput.write(Data("WET DIFF \(mode) tile \(tile.x),\(tile.y) count \(differences.count) max \(differences.max() ?? 0)\n".utf8))
                    }
                }
            }
            check(replayed == expected,
                  "Colored wet pickup and stroke pigment replay deterministically: \(mode)")
            _ = engine.update(stroke, base: substrate.tiles, selection: nil, width: 600, height: 600)
            engine.cancel(); engine.synchronize()
            check(substrate.tiles.mapValues(bytes) == substrateImage, "Cancelled wet preview preserves original tiles")
            let previewWet = engine.update(stroke, base: substrate.tiles, selection: nil, width: 600, height: 600)
            let commitWet = paint(stroke, base: substrate.tiles)
            check(previewWet.tiles[key] === commitWet.tiles[key], "Wet commit promotes preview without replay")
        }
        let suiteName = "Mangar.BrushEngineChecks.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        var configuration = MangaBrushes.configuration(.pencil)
        configuration.size = 77; configuration.positionJitter = 0.3
        AppToolPreferences.saveBrush(configuration, to: suite)
        check(AppToolPreferences.loadBrush(from: suite) == configuration, "Application brush settings persistence")
        configuration.resolvedDynamics.opacity.speed = BrushResponseCurve(enabled: true, outputs: [0.2,0.8,1,0.4,0.1])
        configuration.tipSettings.hardness = 0.3
        configuration.tipSettings.pooling = 0.75
        configuration.wetSettings = BrushWetSettings(medium: .watercolor, pickup: 0.45, mixing: 0.8,
            load: 0.7, persistence: 0.6, dilution: 0.8, granulation: 0.55, edgeDarkening: 0.9)
        configuration.renderingSettings = BrushRenderingSettings(deposition: .solidInk, binary: true, accumulation: .buildUp)
        AppToolPreferences.saveBrush(configuration, to: suite)
        let savedPencil = configuration
        configuration.select(.gPen, from: suite)
        configuration.size = 42; configuration.opacity = 0.65; configuration.flow = 0.7
        configuration.spacing = 0.28; configuration.sizeJitter = 0.2
        configuration.opacityJitter = 0.4; configuration.positionJitter = 0.45
        configuration.accumulation = .buildUp
        AppToolPreferences.saveBrush(configuration, to: suite)
        let savedG = configuration
        configuration.select(.pencil, from: suite)
        check(configuration == savedPencil, "Switching restores every preset parameter")
        configuration.select(.gPen, from: suite)
        check(configuration == savedG, "G pen edits survive switching")
        configuration.select(.gPen, from: suite)
        check(configuration == savedG, "Re-selecting active preset never resets settings")
        check(AppToolPreferences.loadBrush(from: suite) == savedG &&
            AppToolPreferences.loadBrush(preset: .pencil, from: suite) == savedPencil,
            "Reload restores current preset and inactive preset edits")
        configuration.red = 0.3; configuration.green = 0.5; configuration.blue = 0.9
        AppToolPreferences.saveBrush(configuration, to: suite)
        configuration.select(.pencil, from: suite)
        check(configuration.red == 0.3 && configuration.green == 0.5 && configuration.blue == 0.9 &&
            configuration.size == savedPencil.size, "RGB stays shared while brush parameters remain independent")
        suite.removeObject(forKey: "Mangar.tools.brushLibrary.v3")
        suite.set(try JSONEncoder().encode(savedPencil), forKey: "Mangar.tools.brush.v2")
        check(AppToolPreferences.loadBrush(from: suite) == savedPencil, "Existing v2 settings migrate without loss")
        configuration = AppToolPreferences.loadBrush(from: suite)
        configuration.select(.technicalPen, from: suite)
        check(configuration.preset == .technicalPen && AppToolPreferences.loadBrush(preset: .pencil, from: suite) == savedPencil,
            "Migration retains old preset after selecting another")
        configuration.select(.technicalPen, from: suite)
        configuration.select(.pencil, from: suite)
        check(AppToolPreferences.loadLastInkPreset(from: suite) == .technicalPen,
              "Ink tool remembers selection while pencil is active")
        configuration = AppToolPreferences.loadBrush(from: suite)
        check(configuration.preset == .pencil && AppToolPreferences.loadLastInkPreset(from: suite) == .technicalPen,
              "Tool group selection survives reload")
        let builtinBeforeCustom = AppToolPreferences.loadBrush(preset: .gPen, from: suite)
        var customConfig = savedG
        customConfig.resourceID = resource.id
        customConfig.stampSettings.assetIDs = [solidTip.id]
        customConfig.size = 33
        AppToolPreferences.saveBrush(customConfig, to: suite)
        check(AppToolPreferences.loadBrush(from: suite) == customConfig, "Custom resource selection and stamp settings persist")
        check(AppToolPreferences.loadBrush(preset: .gPen, from: suite) == builtinBeforeCustom,
              "Custom resource edits never overwrite its source preset")
        customConfig.select(.pencil, from: suite)
        check(customConfig.resourceID == nil && AppToolPreferences.loadLastBrushResource(from: suite) == resource.id,
              "Pencil selection retains remembered custom tool group resource")
        customConfig.select(.gPen, from: suite)
        check(AppToolPreferences.loadLastBrushResource(from: suite) == nil, "Selecting built-in ink replaces remembered custom resource")
        var oil = MangaBrushes.configuration(.oilFlat)
        let bundled = try BrushResourceStore.shared.assets(for: oil)
        check(bundled.count == 1 && bundled[0].id == BundledBrushTips.oilFlatID &&
            bundled[0].coverage.contains(0) && bundled[0].coverage.contains(where: { $0 > 200 }),
            "Oil preset resolves the bundled bristle tip with transparent gaps")
        check(area(paint(dot(.oilFlat))) > area(paint(dot(.oilFlat, pressure: 0.2))) * 2,
              "Oil preset has visible pressure size response")
        oil.size = 113; oil.flow = 0.43; oil.stampSettings.angle = 18
        AppToolPreferences.saveBrush(oil, to: suite)
        oil.select(.gPen, from: suite)
        oil.select(.oilFlat, from: suite)
        check(oil.size == 113 && oil.flow == 0.43 && oil.stampSettings.angle == 18 &&
              oil.stampSettings.assetIDs == [BundledBrushTips.oilFlatID], "Oil tool keeps independent parameters and bundled tip across switching")
        check(AppToolPreferences.loadLastInkPreset(from: suite) == .gPen, "Oil tool does not replace remembered ink tool")
        print("All GPU brush checks passed")
    }
}
