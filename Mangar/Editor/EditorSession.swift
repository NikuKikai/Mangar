import Foundation
import Combine
import UIKit

@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var page: PageRecord
    @Published private(set) var manifest: ProjectManifest
    @Published private(set) var selectedLayerIDs: [UUID]
    @Published private(set) var selectedEditTarget: LayerEditTarget = .content
    @Published var brush = AppToolPreferences.loadBrush() {
        didSet {
            if brush != oldValue {
                AppToolPreferences.saveBrush(brush)
                scheduleBrushResourceSave()
            }
        }
    }
    @Published private(set) var brushResources: [BrushResource] = []
    private var resourceSaveTask: Task<Void, Never>?
    @Published var pressureCurve = AppToolPreferences.loadPressureCurve() {
        didSet {
            if pressureCurve != oldValue { AppToolPreferences.savePressureCurve(pressureCurve) }
        }
    }
    @Published var usesTransparentColor = AppToolPreferences.loadTransparentColor() {
        didSet { AppToolPreferences.saveTransparentColor(usesTransparentColor) }
    }
    @Published private(set) var colorPresets = AppToolPreferences.loadColorPresets()
    @Published var showsTargetTint = false
    @Published var showsSelectionTint = false
    @Published private(set) var isFilling = false
    @Published var bucketSettings = BucketSettings.load() {
        didSet { bucketSettings.save() }
    }
    @Published var selectedTool: DrawingTool = .brush
    @Published var activeModifiers: Set<EditorModifier> = []
    @Published var message: String?
    @Published var exportURL: URL?
    @Published private(set) var viewportRevision = 0
    @Published private(set) var contentRevision = 0
    @Published var showsRulers = UserDefaults.standard.bool(forKey:"MangarShowsRulers") {
        didSet { UserDefaults.standard.set(showsRulers,forKey:"MangarShowsRulers") }
    }
    @Published private(set) var historyRevision = 0
    @Published private(set) var needsSave = false
    @Published private(set) var pageThumbnails: [UUID: UIImage] = [:]

    @Published var showsFacingPage = UserDefaults.standard.object(forKey: "MangarShowsFacingPage") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsFacingPage,forKey: "MangarShowsFacingPage")
            renderer.showsFacingPage = showsFacingPage
        }
    }
    @Published var facingPageOpacity = UserDefaults.standard.object(forKey: "MangarFacingPageOpacity") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(facingPageOpacity,forKey: "MangarFacingPageOpacity")
            renderer.facingPageOpacity = facingPageOpacity
        }
    }
    var facingPagePair: FacingPagePair? { FacingPagePair.resolve(manifest: manifest,page: page) }
    private var loadedFacingPair: FacingPagePair?

    func refreshFacingPagePreview() {
        guard let pair = facingPagePair else {
            loadedFacingPair = nil; renderer.clearFacingPageImage(); return
        }
        guard pair != loadedFacingPair else { return }
        renderer.clearFacingPageImage()
        do {
            let partner = try store.pageRecord(pair.partnerID)
            loadPageThumbnail(pair.partnerID)
            guard let image = pageThumbnails[pair.partnerID]?.cgImage else { return }
            try renderer.setFacingPageImage(ownerID: page.id,
                rect: pair.destinationRect(current: page,partner: partner),image: image)
            loadedFacingPair = pair
        } catch { message = L10n.format("无法读取页面缩略图：%@", "\(error.localizedDescription)") }
    }

    let renderer: MetalCanvasRenderer
    private let store: ProjectStore

    func makeDocumentPreviewSource() throws -> DocumentPreviewSource {
        endStroke()
        endLayerPropertyEdit()
        releaseModifiers()
        return DocumentPreviewSource(manifest: manifest, currentPage: page,
            currentArchive: try renderer.checkpointArchive(), store: store)
    }
    private var history: CommandHistory
    private let inkClock = ContinuousInkClock()
    private var strokeStartTime: TimeInterval = 0
    private var activeStroke: StrokeCommand?
    private var regionTool: DrawingTool?
    private var selectionPath: [SelectionPoint] = []
    private var regionBrush: BrushConfiguration?
    private var regionErases = false
    private var regionTarget: LayerEditTarget = .content
    private var regionLayerID: UUID?
    private var selectionStart: CGPoint?
    private var selectionMode: SelectionCombineMode = .replace
    private var layerPropertyOriginal: [LayerRecord]?
    private var layerPropertyTargets: Set<UUID> = []

    init(projectURL: URL) throws {
        let store = ProjectStore(root: projectURL)
        let (manifest, initialPage, initialTiles) = try store.loadIndex()
        let renderer = try MetalCanvasRenderer(page: initialPage)
        try renderer.restore(initialTiles)
        self.store = store
        self.page = initialPage
        self.manifest = manifest
        self.renderer = renderer
        self.selectedLayerIDs = initialPage.layers.last.map { [$0.id] } ?? []
        self.history = CommandHistory(checkpoint: DocumentCheckpoint(page: initialPage,
                                                                      archive: initialTiles))
        renderer.showsFacingPage = showsFacingPage
        renderer.facingPageOpacity = facingPageOpacity
        renderer.onViewportChanged = { [weak self] in self?.viewportRevision += 1 }
        renderer.onContentChanged = { [weak self] in self?.contentRevision += 1 }
        renderer.onStorageError = { [weak self] error in self?.message = error.localizedDescription }
        do {
            try BrushResourceStore.shared.update(brush)
            brushResources = try BrushResourceStore.shared.resources()
        } catch { message = error.localizedDescription }
    }

    var inkPreset: BrushPresetID {
        BrushPresetID.inkPresets.contains(brush.preset) ? brush.preset : AppToolPreferences.loadLastInkPreset()
    }

    var inkBrushID: String {
        if let id = brush.resourceID { return id.uuidString }
        if !BrushPresetID.inkPresets.contains(brush.preset), let id = AppToolPreferences.loadLastBrushResource(),
           brushResources.contains(where: { $0.id == id }) { return id.uuidString }
        return inkPreset.rawValue
    }
    func activateInkBrush() {
        if let id = UUID(uuidString: inkBrushID), let resource = brushResources.first(where: { $0.id == id }) {
            if brush.resourceID == id { endStroke(); cancelSelection(); selectedTool = .brush }
            else { selectBrushResource(resource) }
        } else { selectBrush(inkPreset) }
    }

    func selectBrush(_ preset: BrushPresetID) {
        endStroke()
        cancelSelection()
        flushBrushResource()
        brush.select(preset)
        selectedTool = .brush
    }

    var brushName: String {
        brushResources.first(where: { $0.id == brush.resourceID })?.name ?? brush.preset.name
    }
    private func scheduleBrushResourceSave() {
        resourceSaveTask?.cancel()
        guard brush.resourceID != nil else { return }
        let configuration = brush
        resourceSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let self else { return }
                try BrushResourceStore.shared.update(configuration)
                self.brushResources = try BrushResourceStore.shared.resources()
            } catch is CancellationError { } catch { self?.message = error.localizedDescription }
        }
    }
    func flushBrushResource() {
        resourceSaveTask?.cancel()
        do {
            try BrushResourceStore.shared.update(brush)
            brushResources = try BrushResourceStore.shared.resources()
        } catch { message = error.localizedDescription }
    }
    func selectBrushResource(_ resource: BrushResource) {
        endStroke(); cancelSelection(); flushBrushResource()
        do {
            let current = try BrushResourceStore.shared.resources().first { $0.id == resource.id }
            guard let current else { throw BrushResourceError.invalidResource }
            let configuration = try BrushResourceStore.shared.configuration(current, color: brush)
            _ = try BrushResourceStore.shared.assets(for: configuration)
            brush = configuration; selectedTool = .brush
        } catch { message = error.localizedDescription }
    }
    func copyBrushResource() {
        endStroke(); flushBrushResource()
        do {
            let resource = try BrushResourceStore.shared.create(name: brushName + L10n.text(" 副本"), configuration: brush)
            brushResources = try BrushResourceStore.shared.resources()
            brush = try BrushResourceStore.shared.configuration(resource, color: brush)
            selectedTool = .brush
        } catch { message = error.localizedDescription }
    }
    func renameBrushResource(_ name: String) {
        guard let id = brush.resourceID else { return }
        do {
            try BrushResourceStore.shared.rename(id, name: name)
            brushResources = try BrushResourceStore.shared.resources()
        } catch { message = error.localizedDescription }
    }
    func resetBrushResource() {
        endStroke(); resourceSaveTask?.cancel()
        do {
            if let id = brush.resourceID { brush = try BrushResourceStore.shared.reset(id, color: brush) }
            else {
                var defaults = MangaBrushes.configuration(brush.preset)
                defaults.red = brush.red; defaults.green = brush.green; defaults.blue = brush.blue
                brush = defaults
            }
            brushResources = try BrushResourceStore.shared.resources()
        } catch { message = error.localizedDescription }
    }
    func importBrushTips(_ urls: [URL], channel: BrushTipChannel) {
        endStroke()
        guard urls.count + brush.stampSettings.assetIDs.count <= 16 else {
            message = L10n.text("每支笔刷最多使用 16 张笔尖素材。"); return
        }
        do {
            var assets: [BrushTipAsset] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let asset = try BrushTipImporter.load(url, channel: channel)
                try BrushResourceStore.shared.store(asset); assets.append(asset)
            }
            var stamp = brush.stampSettings
            if stamp.assetIDs.isEmpty { stamp.rotation = .fixed }
            stamp.assetIDs += assets.map(\.id)
            brush.stampSettings = stamp
        } catch { message = error.localizedDescription }
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selectedLayerID: UUID? { selectedLayerIDs.first }
    var selectedLayers: [LayerRecord] {
        selectedLayerIDs.compactMap { id in page.layers.first(where: { $0.id == id }) }
    }
    var selectedLayer: LayerRecord? {
        page.layers.first(where: { $0.id == selectedLayerID })
    }
    var selectedLockActionWillLock: Bool {
        !selectedLayers.allSatisfy(\.isLocked)
    }
    var canDeleteSelection: Bool {
        if selectedEditTarget == .mask {
            return selectedLayer.map { $0.hasMask && !page.isEffectivelyLocked($0.id) } ?? false
        }
        return !selectedLayerIDs.isEmpty && selectedLayerIDs.allSatisfy(canDeleteLayer)
    }
    var pageNumber: Int {
        manifest.firstPageNumber(for: page.id)
    }

    func beginStroke(at point: CGPoint, pressure: CGFloat, timestamp: TimeInterval,
                     altitude: CGFloat, azimuth: CGFloat) {
        guard !isFilling else { return }
        if selectedTool == .bucket { fillBucket(at: point); return }
        guard !selectedTool.isRegionTool else { return }
        guard let selectedLayerID, renderer.isInsideCanvas(point),
              page.layers.contains(where: { $0.id == selectedLayerID &&
                  (selectedEditTarget == .mask ? $0.hasMask : $0.kind == .paint) }),
              page.isEffectivelyVisible(selectedLayerID),
              !page.isEffectivelyLocked(selectedLayerID) else { return }
        cancelStroke()
        strokeStartTime = timestamp
        let configuration = editingBrush.validated
        let definition = configuration.definition
        let assets: [BrushTipAsset]
        do { assets = try BrushResourceStore.shared.assets(for: configuration) }
        catch { message = error.localizedDescription; return }
        activeStroke = StrokeCommand(tipAssets: assets, resourceRevision: BrushRecipe(configuration).revision, definition: definition, layerID: selectedLayerID,
            samples: [sample(point, pressure, time: 0, altitude: altitude, azimuth: azimuth)],
            brush: configuration, seed: UInt64.random(in: 1...UInt64.max),
            tool: usesTransparentColor ? .eraser : selectedTool, target: selectedEditTarget)
        renderer.preview(activeStroke!)
        if definition.timeRate > 0 {
            inkClock.onTick = { [weak self] time in self?.appendContinuousInk(at: time) }
            inkClock.start()
        }
    }

    func appendStroke(at point: CGPoint, pressure: CGFloat, timestamp: TimeInterval,
                      altitude: CGFloat, azimuth: CGFloat, renderPreview: Bool = true) {
        guard let last = activeStroke?.samples.last else { return }
        let lowerX = page.boundary.hasMinimumX ? max(0,point.x) : point.x
        let x = page.boundary.width.map { min(lowerX,CGFloat($0-1)) } ?? lowerX
        let lowerY = page.boundary.hasMinimumY ? max(0,point.y) : point.y
        let y = page.boundary.height.map { min(lowerY,CGFloat($0-1)) } ?? lowerY
        let next = sample(CGPoint(x: x, y: y), pressure,
                          time: max(last.time, timestamp - strokeStartTime), altitude: altitude, azimuth: azimuth)
        if next == last { return }
        activeStroke?.samples.append(next)
        if renderPreview { refreshStrokePreview() }
    }

    func refreshStrokePreview() {
        if let stroke = activeStroke { renderer.preview(stroke) }
    }

    private func appendContinuousInk(at timestamp: TimeInterval) {
        guard var next = activeStroke?.samples.last else { inkClock.stop(); return }
        next.time = max(next.time, timestamp - strokeStartTime)
        activeStroke?.samples.append(next)
        renderer.preview(activeStroke!)
    }

    func endStroke() {
        inkClock.stop()
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        perform(.stroke(stroke))
    }

    func cancelStroke() {
        inkClock.stop()
        activeStroke = nil
        renderer.clearPreview()
    }

    func beginSelection(at point: CGPoint, shift: Bool, option: Bool) {
        guard selectedTool.isRegionTool else { return }
        endStroke()
        cancelSelection()
        if selectedTool == .lassoFill {
            guard let layer = selectedLayer,
                  (selectedEditTarget == .mask ? layer.hasMask : layer.kind == .paint),
                  page.isEffectivelyVisible(layer.id), !page.isEffectivelyLocked(layer.id) else { return }
            regionLayerID = layer.id
            regionBrush = editingBrush
            regionErases = usesTransparentColor
            regionTarget = selectedEditTarget
        }
        regionTool = selectedTool
        selectionStart = point
        selectionPath = [SelectionPoint(x: point.x, y: point.y)]
        selectionMode = shift && option ? .intersect :
            shift ? .add : option ? .subtract : .replace
        if selectedTool == .selection { renderer.previewSelection(from: point, to: point) }
        else { renderer.previewLasso(selectionPath) }
    }

    func updateSelection(to point: CGPoint) { updateSelection(along: [point]) }

    func updateSelection(along points: [CGPoint]) {
        guard let selectionStart, let point = points.last else { return }
        if regionTool == .selection {
            renderer.previewSelection(from: selectionStart, to: point)
        } else {
            var changed = false
            for point in points {
                if let last = selectionPath.last,
                   hypot(point.x - last.x, point.y - last.y) * renderer.zoom < 0.75 { continue }
                selectionPath.append(SelectionPoint(x: point.x, y: point.y))
                changed = true
            }
            if changed { renderer.previewLasso(selectionPath) }
        }
    }

    func endSelection(at point: CGPoint) {
        guard let start = selectionStart, let tool = regionTool else { return }
        updateSelection(to: point)
        let path = selectionPath
        let fillBrush = regionBrush
        let fillLayerID = regionLayerID
        let fillTarget = regionTarget
        let fillErases = regionErases
        let mode = selectionMode
        cancelSelection()
        if tool != .selection {
            guard path.count >= 3 else { return }
            if tool == .lassoFill, let fillLayerID, let fillBrush,
               page.isEffectivelyVisible(fillLayerID), !page.isEffectivelyLocked(fillLayerID) {
                perform(.lassoFill(LassoFillCommand(layerID: fillLayerID, points: path, brush: fillBrush, target: fillTarget, erases: fillErases)))
            } else if tool == .lassoSelection {
                perform(.selection(.lasso(path, mode)))
            }
            return
        }
        let x0 = min(start.x, point.x)
        let y0 = min(start.y, point.y)
        let x1 = max(start.x, point.x)
        let y1 = max(start.y, point.y)
        guard x1 - x0 >= 0.5, y1 - y0 >= 0.5 else { return }
        perform(.selection(.rectangle(SelectionRect(x: x0, y: y0,
                                                     width: x1 - x0, height: y1 - y0), mode)))
    }

    func cancelSelection() {
        selectionStart = nil
        selectionPath = []
        regionTool = nil
        regionLayerID = nil
        regionBrush = nil
        renderer.clearSelectionPreview()
    }

    func changeSelection(_ command: SelectionCommand) {
        cancelStroke()
        cancelSelection()
        perform(.selection(command))
    }

    func setModifier(_ modifier: EditorModifier, pressed: Bool) {
        var modifiers = activeModifiers
        if pressed {
            modifiers.insert(modifier)
        } else {
            modifiers.remove(modifier)
        }
        activeModifiers = modifiers
    }

    func releaseModifiers() {
        activeModifiers.removeAll()
    }

    func pickColor(at point: CGPoint) {
        guard let color = renderer.sampleColor(at: point) else { return }
        usesTransparentColor = false
        brush.red = Double(color.x)
        brush.green = Double(color.y)
        brush.blue = Double(color.z)
    }

    func selectLayer(_ id: UUID, shift: Bool = false, command: Bool = false) {
        let previousPrimary = selectedLayerID
        defer { if previousPrimary != selectedLayerID { selectedEditTarget = .content } }
        guard page.layers.contains(where: { $0.id == id }) else { return }
        if shift, let primaryID = selectedLayerID {
            let displayed = page.layerDisplayEntries.map(\.id)
            guard let start = displayed.firstIndex(of: primaryID),
                  let end = displayed.firstIndex(of: id) else { return }
            var selection = selectedLayerIDs
            if start != end {
                let step = start < end ? 1 : -1
                for index in stride(from: start + step, through: end, by: step) {
                    let next = displayed[index]
                    if !selection.contains(next) { selection.append(next) }
                }
            }
            selectedLayerIDs = selection
        } else if command, !selectedLayerIDs.isEmpty {
            if let index = selectedLayerIDs.firstIndex(of: id) {
                if selectedLayerIDs.count > 1 { selectedLayerIDs.remove(at: index) }
            } else {
                selectedLayerIDs.append(id)
            }
        } else {
            selectedLayerIDs = [id]
        }
    }

    func selectLayerTarget(_ id: UUID, target: LayerEditTarget,
                           shift: Bool = false, command: Bool = false) {
        endStroke()
        cancelSelection()
        selectLayer(id, shift: shift, command: command)
        if selectedLayerID == id, target == .content || selectedLayer?.hasMask == true {
            selectedEditTarget = target
        }
    }

    var canAddLayerMask: Bool {
        guard let layer = selectedLayer else { return false }
        return !layer.hasMask && !page.isEffectivelyLocked(layer.id)
    }

    func addLayerMask() {
        guard canAddLayerMask, let id = selectedLayerID,
              let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
        endStroke()
        cancelSelection()
        endLayerPropertyEdit()
        var updated = page.layers
        updated[index].hasMask = true
        perform(.replaceLayerStack(updated))
        selectedEditTarget = .mask
    }

    func useColorPreset(_ index: Int) {
        guard colorPresets.indices.contains(index) else { return }
        let color = colorPresets[index]
        endStroke()
        usesTransparentColor = false
        var updated = brush
        updated.red = color.red; updated.green = color.green; updated.blue = color.blue
        updated.opacity = color.opacity
        brush = updated
    }

    func storeColorPreset(_ index: Int) {
        guard colorPresets.indices.contains(index) else { return }
        colorPresets[index] = AppColor(brush)
        AppToolPreferences.saveColorPresets(colorPresets)
    }

    private var editingBrush: BrushConfiguration {
        var result = brush
        if selectedEditTarget == .mask {
            let gray = min(1, max(0, brush.red * 0.2126 + brush.green * 0.7152 + brush.blue * 0.0722))
            result.red = gray; result.green = gray; result.blue = gray
        }
        return result
    }

    var hasSelection: Bool { renderer.selection != nil }

    func fillBucket(at point: CGPoint) {
        guard manifest.purpose != .unrestricted, !isFilling, renderer.isInsideCanvas(point), let layer = selectedLayer,
              (selectedEditTarget == .mask ? layer.hasMask : layer.kind == .paint),
              page.isEffectivelyVisible(layer.id), !page.isEffectivelyLocked(layer.id) else { return }
        endStroke(); endLayerPropertyEdit(); cancelSelection()
        let target = selectedEditTarget
        let source = renderer.snapshot(keys: Set(renderer.tileKeys.filter { $0.layerID == layer.id && $0.target == target }))
        let reference = Dictionary(uniqueKeysWithValues: source.map { (SelectionTileKey(x: $0.key.x, y: $0.key.y), $0.value) })
        let selection = renderer.selectionReadback()
        let settings = bucketSettings.validated, width = page.width, height = page.height
        let pageID = page.id, revision = historyRevision, color = editingBrush, erases = usesTransparentColor
        isFilling = true
        Task {
            let spans = await Task.detached(priority: .userInitiated) {
                BucketRegionResolver.resolve(width: width, height: height, x: Int(point.x), y: Int(point.y), target: target,
                    source: reference, settings: settings, selection: selection.tiles, selectionDefault: selection.defaultCoverage)
            }.value
            isFilling = false
            // Any intervening document/selection change invalidates the captured operation.
            guard page.id == pageID, historyRevision == revision, selectedLayerID == layer.id,
                  selectedEditTarget == target, page.isEffectivelyVisible(layer.id), !page.isEffectivelyLocked(layer.id), !spans.isEmpty else { return }
            perform(.bucketFill(BucketFillCommand(layerID: layer.id, spans: spans, brush: color, target: target, erases: erases)))
        }
    }

    var selectedCurvesWillEnable: Bool { !selectedLayers.allSatisfy { $0.curves?.isEnabled == true } }
    func toggleSelectedCurves() {
        guard !selectedLayerIDs.isEmpty else { return }
        endLayerPropertyEdit()
        let enabled = selectedCurvesWillEnable, ids = Set(selectedLayerIDs)
        var updated = page.layers
        for i in updated.indices where ids.contains(updated[i].id) {
            var effect = updated[i].curves ?? LayerCurveEffect()
            effect.isEnabled = enabled; updated[i].curves = effect
        }
        perform(.replaceLayerStack(updated))
    }
    func previewLayerCurve(channel: LayerCurveEffect.Channel, values: [Double]) {
        previewLayerProperties { layer in
            var effect = layer.curves ?? LayerCurveEffect(isEnabled: false)
            effect[channel] = values; layer.curves = effect
        }
    }

    var selectedToneWillEnable: Bool {
        !selectedLayers.allSatisfy { $0.tone?.isEnabled == true }
    }

    func toggleSelectedTone() {
        guard !selectedLayerIDs.isEmpty else { return }
        endLayerPropertyEdit()
        let enabled = selectedToneWillEnable
        let ids = Set(selectedLayerIDs)
        var updated = page.layers
        for index in updated.indices where ids.contains(updated[index].id) {
            var tone = updated[index].tone ?? LayerToneEffect()
            tone.isEnabled = enabled
            updated[index].tone = tone
        }
        perform(.replaceLayerStack(updated))
    }

    func previewLayerTone(frequency: Double? = nil, angle: Double? = nil, density: Double? = nil) {
        previewLayerProperties { layer in
            var tone = layer.tone ?? LayerToneEffect(isEnabled: false)
            if let frequency { tone.frequency = min(120, max(10, frequency)) }
            if let angle { tone.angle = min(180, max(0, angle)) }
            if let density { tone.density = min(1, max(0, density)) }
            layer.tone = tone
        }
    }

    func renameLayer(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        endStroke()
        endLayerPropertyEdit()
        guard let index = page.layers.firstIndex(where: { $0.id == id }),
              page.layers[index].name != name else { return }
        var updated = page.layers
        updated[index].name = name
        perform(.replaceLayerStack(updated))
    }

    func beginLayerPropertyEdit(_ id: UUID) {
        guard layerPropertyOriginal == nil, page.layers.contains(where: { $0.id == id }) else { return }
        endStroke()
        layerPropertyOriginal = page.layers
        layerPropertyTargets = Set(selectedLayerIDs.contains(id) ? selectedLayerIDs : [id])
    }

    func previewLayerOpacity(_ opacity: Double) {
        previewLayerProperties { $0.opacity = min(1, max(0, opacity)) }
    }

    func previewLayerBlendMode(_ mode: LayerBlendMode) {
        previewLayerProperties { $0.blendMode = mode }
    }

    private func previewLayerProperties(_ edit: (inout LayerRecord) -> Void) {
        guard layerPropertyOriginal != nil else { return }
        var updated = page.layers
        for index in updated.indices where layerPropertyTargets.contains(updated[index].id) {
            edit(&updated[index])
        }
        guard updated != page.layers else { return }
        page.layers = updated
        renderer.page = page
        renderer.view?.setNeedsDisplay()
    }

    func endLayerPropertyEdit(commit: Bool = true) {
        guard let original = layerPropertyOriginal else { return }
        let updated = page.layers
        layerPropertyOriginal = nil
        layerPropertyTargets = []
        page.layers = original
        renderer.page = page
        if commit, updated != original { perform(.replaceLayerStack(updated)) }
        else { renderer.view?.setNeedsDisplay() }
    }

    func addLayer() {
        insertLayer(kind: .paint)
    }

    func addFolder() {
        insertLayer(kind: .folder)
    }

    private func insertLayer(kind: LayerRecord.Kind) {
        cancelStroke()
        let count = page.layers.filter { $0.kind == kind }.count + 1
        var layer = LayerRecord(name: kind == .folder ? L10n.format("文件夹 %@", "\(count)") : L10n.format("图层 %@", "\(count)"), kind: kind)
        var updated = page.layers
        if let selectedLayerID,
           let selected = page.layers.first(where: { $0.id == selectedLayerID }) {
            let intendedParent = selected.kind == .folder ? selected.id : selected.parentID
            layer.parentID = intendedParent.flatMap { page.isEffectivelyLocked($0) ? nil : $0 }
            let index = page.subtreeRange(of: selected.id)?.upperBound ?? updated.count
            updated.insert(layer, at: layer.parentID == intendedParent ? index : updated.count)
        } else {
            updated.append(layer)
        }
        perform(.replaceLayerStack(updated))
        selectedLayerIDs = [layer.id]
        selectedEditTarget = .content
    }

    func deleteSelectedLayer() {
        guard canDeleteSelection else { return }
        cancelStroke()
        cancelSelection()
        endLayerPropertyEdit()
        if selectedEditTarget == .mask, let id = selectedLayerID,
           let index = page.layers.firstIndex(where: { $0.id == id }) {
            var updated = page.layers
            updated[index].hasMask = false
            perform(.replaceLayerStack(updated))
            return
        }
        var removed = Set<UUID>()
        for id in selectedLayerIDs {
            guard let range = page.subtreeRange(of: id) else { continue }
            removed.formUnion(page.layers[range].map(\.id))
        }
        var updated = page.layers
        updated.removeAll { removed.contains($0.id) }
        perform(.replaceLayerStack(updated))
    }

    var canClearSelectedTarget: Bool {
        guard let layer = selectedLayer, !page.isEffectivelyLocked(layer.id) else { return false }
        return selectedEditTarget == .mask ? layer.hasMask : layer.kind == .paint
    }

    func clearSelectedTarget() {
        guard canClearSelectedTarget, let id = selectedLayerID else { return }
        endStroke()
        cancelSelection()
        endLayerPropertyEdit()
        perform(.clearLayer(ClearLayerCommand(layerID: id, target: selectedEditTarget)))
    }

    private func canDeleteLayer(_ id: UUID) -> Bool {
        guard !page.isEffectivelyLocked(id), let range = page.subtreeRange(of: id) else { return false }
        return !page.layers[range].contains { $0.isLocked }
    }

    func moveLayer(_ id: UUID, relativeTo targetID: UUID, placement: LayerDropPlacement) {
        cancelStroke()
        let requested = selectedLayerIDs.contains(id) ? selectedLayerIDs : [id]
        guard let updated = page.movingLayers(requested, relativeTo: targetID,
                                              placement: placement) else { return }
        perform(.replaceLayerStack(updated))
    }

    func toggleVisibility(_ id: UUID) {
        let targets = selectedLayerIDs.contains(id) ? selectedLayerIDs : [id]
        let layers = targets.compactMap { target in page.layers.first(where: { $0.id == target }) }
        guard !layers.isEmpty else { return }
        let makeVisible = layers.allSatisfy { !$0.isVisible }
        var updated = page.layers
        for index in updated.indices where targets.contains(updated[index].id) {
            updated[index].isVisible = makeVisible
        }
        perform(.replaceLayerStack(updated))
    }

    func toggleLock(_ id: UUID) {
        let targets = selectedLayerIDs.contains(id) ? selectedLayerIDs : [id]
        let layers = targets.compactMap { target in page.layers.first(where: { $0.id == target }) }
        guard !layers.isEmpty else { return }
        let lock = !layers.allSatisfy(\.isLocked)
        cancelStroke()
        var updated = page.layers
        for index in updated.indices where targets.contains(updated[index].id) {
            updated[index].isLocked = lock
        }
        perform(.replaceLayerStack(updated))
    }

    func toggleSelectedLock() {
        guard let selectedLayerID else { return }
        toggleLock(selectedLayerID)
    }

    func undo() {
        endLayerPropertyEdit()
        cancelStroke()
        cancelSelection()
        guard history.canUndo else { return }
        let command = history.commands[history.cursor - 1]
        history.cursor -= 1
        rebuild(to: history.cursor)
        historyRevision += 1
        if case .selection = command { return }
        renderer.markAllTilesDirty()
        needsSave = true
    }

    func redo() {
        endLayerPropertyEdit()
        cancelStroke()
        cancelSelection()
        guard history.canRedo else { return }
        let command = history.commands[history.cursor]
        history.cursor += 1
        rebuild(to: history.cursor)
        historyRevision += 1
        if case .selection = command { return }
        renderer.markAllTilesDirty()
        needsSave = true
    }

    @discardableResult
    func saveNow() -> Bool {
        endLayerPropertyEdit()
        if activeStroke != nil { endStroke() }
        return persist()
    }

    func addPage(at index: Int, isSpread: Bool) {
        guard (0...manifest.pageIDs.count).contains(index), saveNow() else { return }
        do {
            if manifest.pageStructure == .cards {
                let newPage = PageRecord.blank(name: L10n.text("新页面"), width: page.width, height: page.height,
                    boundary: manifest.initialBoundary ?? page.boundary, surface: page.pageSurface)
                let preview = try MetalCanvasRenderer(page: newPage).projectThumbnailPNG()
                var updated = manifest
                try store.insertPage(newPage, at: index, into: &updated, thumbnail: preview)
                manifest = updated; pageThumbnails[newPage.id] = UIImage(data: preview)
                return
            }
            var layout = manifest.singlePageLayout ?? page.comicLayout
            layout?.pageSpan = isSpread ? 2 : 1
            let singleWidth = page.isDoublePage ? Int(page.contentRect.width) / 2 : page.width
            let width = layout?.canvasWidthPixels ?? (singleWidth * (isSpread ? 2 : 1))
            let height = layout?.canvasHeightPixels ?? page.height
            guard width <= 16384, height <= 16384 else {
                message = L10n.text("对开画布尺寸超出当前支持的 16384 px 上限，请使用较小的单页尺寸或分辨率。")
                return
            }
            let newPage = PageRecord.blank(name: L10n.text("新页面"), width: width, height: height,
                                            comicLayout: layout, isSpread: isSpread)
            let thumbnail = PageThumbnail.whitePNG(for: CGSize(width: width, height: height))
            var updated = manifest
            try store.insertPage(newPage, at: index, into: &updated, thumbnail: thumbnail)
            manifest = updated
            pageThumbnails[newPage.id] = UIImage(data: thumbnail)
        } catch {
            message = L10n.format("无法新增页面：%@", "\(error.localizedDescription)")
        }
    }

    func movePage(_ id: UUID, to insertionIndex: Int) {
        guard let source = manifest.pageIDs.firstIndex(of: id),
              (0...manifest.pageIDs.count).contains(insertionIndex) else { return }
        var order = manifest.pageIDs
        order.remove(at: source)
        order.insert(id, at: insertionIndex - (source < insertionIndex ? 1 : 0))
        guard order != manifest.pageIDs else { return }
        manifest.pageIDs = order
        needsSave = true
    }

    func mergePartner(for id: UUID) -> UUID? {
        for container in PageContainer.arrange(manifest) {
            if case .page(let right, _) = container.right,
               case .page(let left, _) = container.left, container.spreadID == nil {
                if id == right { return left }
                if id == left { return right }
            }
        }
        return nil
    }

    func mergePages(_ id: UUID) {
        guard let partner = mergePartner(for: id), saveNow() else { return }
        do {
            let ids = [id, partner].sorted {
                manifest.pageIDs.firstIndex(of: $0)! < manifest.pageIDs.firstIndex(of: $1)!
            }
            let r = try store.loadPage(ids[0]), l = try store.loadPage(ids[1])
            let output = try PageConversion.merge(right: ConvertedPage(page: r.0, tiles: r.1),
                                                  left: ConvertedPage(page: l.0, tiles: l.1))
            try replacePages(ids, outputs: [output])
        } catch { message = L10n.format("合并失败：%@", "\(error.localizedDescription)") }
    }

    func splitPage(_ id: UUID) {
        guard manifest.spreadPageIDs.contains(id), saveNow() else { return }
        do {
            let source = try store.loadPage(id)
            try replacePages([id], outputs: PageConversion.split(ConvertedPage(page: source.0, tiles: source.1)))
        } catch { message = L10n.format("拆分失败：%@", "\(error.localizedDescription)") }
    }

    func deletePage(_ id: UUID) {
        guard manifest.pageIDs.contains(id), saveNow() else { return }
        do {
            // Keep an editable project when deleting its last page.
            let outputs: [ConvertedPage] = manifest.pageIDs.count == 1 ?
                [ConvertedPage(page: .blank(width: page.width, height: page.height,
                    comicLayout: page.comicLayout, isSpread: page.isDoublePage, boundary: page.boundary, surface: page.pageSurface), tiles: [:])] : []
            try replacePages([id], outputs: outputs)
        } catch { message = L10n.format("删除失败：%@", "\(error.localizedDescription)") }
    }

    private func replacePages(_ ids: [UUID], outputs: [ConvertedPage]) throws {
        guard let index = manifest.pageIDs.firstIndex(where: { ids.contains($0) }) else { return }
        var updated = manifest
        updated.pageIDs.removeAll { ids.contains($0) }
        updated.pageIDs.insert(contentsOf: outputs.map { $0.page.id }, at: index)
        updated.spreadPageIDs.removeAll { ids.contains($0) }
        updated.spreadPageIDs.append(contentsOf: outputs.filter { $0.page.isDoublePage }.map { $0.page.id })
        if ids.contains(page.id) {
            updated.selectedPageID = outputs.first?.page.id ?? updated.pageIDs[min(index, updated.pageIDs.count - 1)]
        }
        var thumbnails: [UUID: Data] = [:]
        for output in outputs {
            let preview = try MetalCanvasRenderer(page: output.page)
            preview.restore(output.tiles)
            thumbnails[output.page.id] = try preview.projectThumbnailPNG()
        }
        // Resolve the next current page before committing or deleting source files.
        let next: ConvertedPage? = ids.contains(page.id) ?
            (try outputs.first ?? { let loaded = try store.loadPage(updated.selectedPageID)
                return ConvertedPage(page: loaded.0, tiles: loaded.1) }()) : nil
        try store.replacePages(with: outputs, removing: ids, manifest: updated, thumbnails: thumbnails)
        if let next { switchTo(page: next.page, tiles: next.tiles, manifest: updated) }
        else { manifest = updated }
        for id in ids { pageThumbnails.removeValue(forKey: id) }
        for (id, data) in thumbnails { pageThumbnails[id] = UIImage(data: data) }
        needsSave = false
    }

    func setStartingSide(_ side: PageStartSide) {
        guard manifest.startingSide != side else { return }
        manifest.startingSide = side
        needsSave = true
    }

    @discardableResult
    func selectPage(_ id: UUID) -> Bool {
        endLayerPropertyEdit()
        guard manifest.pageIDs.contains(id) else { return false }
        guard id != page.id else { return true }
        cancelStroke()
        cancelSelection()
        guard persist() else { return false }
        do {
            let (newPage, archive) = try store.loadPageIndex(id)
            var updated = manifest
            updated.selectedPageID = id
            try store.saveManifest(updated)
            try switchTo(page: newPage, archive: archive, manifest: updated)
            needsSave = true
            return persist()
        } catch {
            message = L10n.format("无法打开页面：%@", "\(error.localizedDescription)")
            return false
        }
    }

    func refreshCurrentPageThumbnail() {
        do {
            pageThumbnails[page.id] = UIImage(data: try renderer.projectThumbnailPNG())
        } catch {
            message = L10n.format("无法生成页面缩略图：%@", "\(error.localizedDescription)")
        }
    }

    func loadPageThumbnail(_ id: UUID) {
        guard manifest.pageIDs.contains(id), pageThumbnails[id] == nil else { return }
        if id == page.id {
            refreshCurrentPageThumbnail()
            return
        }
        if let data = store.pageThumbnail(id), let image = UIImage(data: data) {
            pageThumbnails[id] = image
            return
        }
        // Generate missing thumbnails lazily for older projects, using a separate
        // renderer so the open page, its history and viewport stay intact.
        do {
            let (record, tiles) = try store.loadPageIndex(id)
            let thumbnailRenderer = try MetalCanvasRenderer(page: record)
            try thumbnailRenderer.restore(tiles)
            let data = try thumbnailRenderer.projectThumbnailPNG()
            try store.savePageThumbnail(data, pageID: id)
            pageThumbnails[id] = UIImage(data: data)
        } catch {
            message = L10n.format("无法读取页面缩略图：%@", "\(error.localizedDescription)")
        }
    }

    func exportPNG(cropToContent: Bool) {
        do {
            let data = try renderer.exportPNG(cropToContent: cropToContent)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(L10n.format("Mangar-第%@页-%@.png", "\(pageNumber)", "\(UUID().uuidString)"))
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            message = L10n.format("PNG 导出失败：%@", "\(error.localizedDescription)")
        }
    }

    func mappedPressure(_ pressure: CGFloat) -> Double {
        pressureCurve.map(Double(pressure))
    }

    private func sample(_ point: CGPoint, _ pressure: CGFloat, time: Double,
                        altitude: CGFloat, azimuth: CGFloat) -> StrokeSample {
        StrokeSample(x: Double(point.x), y: Double(point.y), pressure: mappedPressure(pressure),
                     time: time, altitude: Double(altitude), azimuth: Double(azimuth))
    }

    private func perform(_ command: EditCommand) {
        endLayerPropertyEdit()
        if history.cursor < history.commands.count {
            history.commands.removeSubrange(history.cursor...)
        }
        apply(command)
        reconcileLayerSelection()
        history.commands.append(command)
        history.cursor += 1
        if history.commands.count > history.limit {
            let currentCursor = history.cursor
            rebuild(to: 1)
            do { history.checkpoint = DocumentCheckpoint(page: page, archive: try renderer.checkpointArchive(), selection: renderer.selection) } catch {
                rebuild(to:currentCursor)
                message = error.localizedDescription; historyRevision += 1; needsSave = true
                return
            }
            history.commands.removeFirst()
            history.cursor = currentCursor - 1
            rebuild(to: history.cursor)
            renderer.markAllTilesDirty()
        }
        historyRevision += 1
        if case .selection = command { return }
        needsSave = true
    }

    private func rebuild(to count: Int) {
        page = history.checkpoint.page
        renderer.page = page
        if let archive = history.checkpoint.archive { do { try renderer.restore(archive) } catch { message = error.localizedDescription; return } } else { renderer.restore(history.checkpoint.tiles) }
        renderer.restoreSelection(history.checkpoint.selection)
        for command in history.commands.prefix(count) { apply(command) }
        reconcileLayerSelection()
    }

    private func reconcileLayerSelection() {
        let previousPrimary = selectedLayerID
        let existing = Set(page.layers.map(\.id))
        let kept = selectedLayerIDs.filter { existing.contains($0) }
        selectedLayerIDs = kept.isEmpty ? page.layers.last.map { [$0.id] } ?? [] : kept
        if previousPrimary != selectedLayerID || selectedLayer?.hasMask != true { selectedEditTarget = .content }
    }

    func setPageSurface(_ surface: PageSurface) {
        endStroke()
        let value = surface.normalized
        guard value != page.pageSurface else { return }
        perform(.setPageSurface(value))
    }

    private func apply(_ command: EditCommand) {
        switch command {
        case .setPageSurface(let surface):
            page.surface = surface.normalized
        case .clearLayer(let clear):
            guard page.layers.contains(where: { $0.id == clear.layerID }) else { return }
            renderer.commitClear(clear)
        case .bucketFill(let fill):
            guard page.layers.contains(where: { $0.id == fill.layerID }) else { return }
            renderer.commitBucketFill(fill)
        case .lassoFill(let fill):
            guard page.layers.contains(where: { $0.id == fill.layerID }) else { return }
            renderer.commitLassoFill(fill)
        case .stroke(let stroke):
            guard page.layers.contains(where: { $0.id == stroke.layerID }) else { return }
            renderer.commit(stroke)
        case .selection(let operation):
            renderer.applySelection(operation)
        case .addLayer(let layer, let index):
            page.layers.insert(layer, at: min(max(0, index), page.layers.count))
        case .removeLayer(let id):
            page.layers.removeAll { $0.id == id }
            renderer.removeTiles(for: id)
        case .moveLayer(let id, let index):
            guard let old = page.layers.firstIndex(where: { $0.id == id }) else { return }
            let layer = page.layers.remove(at: old)
            page.layers.insert(layer, at: min(max(0, index), page.layers.count))
        case .setVisibility(let id, let visible):
            guard let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
            page.layers[index].isVisible = visible
        case .setLocked(let id, let locked):
            guard let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
            page.layers[index].isLocked = locked
        case .replaceLayerStack(let layers):
            let retained = Set(layers.map(\.id))
            for old in page.layers where !retained.contains(old.id) {
                renderer.removeTiles(for: old.id)
            }
            for old in page.layers where old.hasMask && layers.contains(where: { $0.id == old.id && !$0.hasMask }) {
                renderer.removeTiles(for: old.id, target: .mask)
            }
            page.layers = layers
        }
        renderer.page = page
        renderer.view?.setNeedsDisplay()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            if !needsSave && renderer.dirtyTileKeys.isEmpty &&
                !store.requiresFullSnapshot(page.id) && store.hasThumbnail { return true }
            renderer.prepareForReadback()
            let allKeys = renderer.tileKeys
            let keys = store.requiresFullSnapshot(page.id) ? allKeys : renderer.dirtyTileKeys
            let changed = renderer.snapshot(keys: keys)
            let thumbnail = try renderer.projectThumbnailPNG()
            try renderer.checkStorageIntegrity()
            try store.save(manifest: manifest, page: page, changedTiles: changed,
                           allTileKeys: allKeys, thumbnail: thumbnail, tileBounds: renderer.tileContentBounds)
            pageThumbnails[page.id] = UIImage(data: thumbnail)
            renderer.clearSavedDirtyTiles()
            needsSave = false
            return true
        } catch {
            message = L10n.format("保存失败：%@", "\(error.localizedDescription)")
            return false
        }
    }

    private func switchTo(page newPage: PageRecord, archive: CanvasTileArchive, manifest newManifest: ProjectManifest) throws {
        endLayerPropertyEdit(commit:false)
        manifest = newManifest; page = newPage; renderer.page = newPage
        try renderer.restore(archive); renderer.resetViewport()
        selectedLayerIDs = newPage.layers.last.map { [$0.id] } ?? []; selectedEditTarget = .content
        history = CommandHistory(checkpoint:DocumentCheckpoint(page:newPage,archive:archive)); historyRevision += 1
    }

    private func switchTo(page newPage: PageRecord, tiles: [TileKey: Data],
                          manifest newManifest: ProjectManifest) {
        endLayerPropertyEdit(commit: false)
        manifest = newManifest
        page = newPage
        renderer.page = newPage
        renderer.restore(tiles)
        renderer.resetViewport()
        selectedLayerIDs = newPage.layers.last.map { [$0.id] } ?? []
        selectedEditTarget = .content
        history = CommandHistory(checkpoint: DocumentCheckpoint(page: newPage, tiles: tiles))
        historyRevision += 1
    }
}
