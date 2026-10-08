import Foundation
import CoreGraphics
import Metal

@main
struct BrushEngineChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let source = try String(contentsOf: root.appendingPathComponent("Mangar/Rendering/BrushShaderSource.txt"), encoding: .utf8) + "\n" +
            String(contentsOf: root.appendingPathComponent("Mangar/Brushes/GPU/BrushKernels.txt"), encoding: .utf8)
        let library = try await device.makeLibrary(source: source, options: nil)
        let engine = try MetalBrushEngine(device: device, queue: queue, library: library)
        let layer = UUID()
        func command(_ preset: BrushPresetID, _ samples: [StrokeSample], size: Double = 24) -> StrokeCommand {
            var brush = MangaBrushes.configuration(preset)
            brush.size = size; brush.red = 0; brush.green = 0; brush.blue = 0
            return StrokeCommand(definition: MangaBrushes.definition(preset), layerID: layer,
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
        check(MemoryLayout<BrushGPUInput>.stride == 32 && MemoryLayout<BrushGPUUniforms>.stride == 144, "Metal ABI")
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
        print("All GPU brush checks passed")
    }
}
