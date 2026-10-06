import Foundation
import Combine
import UIKit

@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var page: PageRecord
    @Published private(set) var manifest: ProjectManifest
    @Published private(set) var selectedLayerIDs: [UUID]
    @Published var brush = RoundBrush()
    @Published var selectedTool: DrawingTool = .brush
    @Published var activeModifiers: Set<EditorModifier> = []
    @Published var message: String?
    @Published var exportURL: URL?
    @Published private(set) var historyRevision = 0
    @Published private(set) var needsSave = false
    @Published private(set) var pageThumbnails: [UUID: UIImage] = [:]

    let renderer: MetalCanvasRenderer
    private let store: ProjectStore
    private var history: CommandHistory
    private var activeStroke: StrokeCommand?
    private var selectionStart: CGPoint?
    private var selectionMode: SelectionCombineMode = .replace

    init(projectURL: URL) throws {
        let store = ProjectStore(root: projectURL)
        let loaded = try store.load()
        let renderer = try MetalCanvasRenderer(page: loaded.page)
        renderer.restore(loaded.tiles)
        self.store = store
        self.page = loaded.page
        self.manifest = loaded.manifest
        self.renderer = renderer
        self.selectedLayerIDs = loaded.page.layers.last.map { [$0.id] } ?? []
        self.history = CommandHistory(checkpoint: DocumentCheckpoint(page: loaded.page,
                                                                      tiles: loaded.tiles))
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
        !selectedLayerIDs.isEmpty && selectedLayerIDs.allSatisfy(canDeleteLayer)
    }
    var pageNumber: Int {
        manifest.firstPageNumber(for: page.id)
    }

    func beginStroke(at point: CGPoint, pressure: CGFloat) {
        guard selectedTool != .selection else { return }
        guard let selectedLayerID, renderer.isInsideCanvas(point),
              page.layers.contains(where: { $0.id == selectedLayerID && $0.kind == .paint }),
              page.isEffectivelyVisible(selectedLayerID),
              !page.isEffectivelyLocked(selectedLayerID) else { return }
        activeStroke = StrokeCommand(layerID: selectedLayerID,
                                     samples: [sample(point, pressure)], brush: brush,
                                     seed: UInt64.random(in: 1...UInt64.max), tool: selectedTool)
        renderer.preview(activeStroke!)
    }

    func appendStroke(at point: CGPoint, pressure: CGFloat) {
        guard var stroke = activeStroke else { return }
        let x = min(max(0, point.x), CGFloat(page.width - 1))
        let y = min(max(0, point.y), CGFloat(page.height - 1))
        let next = sample(CGPoint(x: x, y: y), pressure)
        if let last = stroke.samples.last,
           hypot(next.x - last.x, next.y - last.y) < 0.25 { return }
        stroke.samples.append(next)
        activeStroke = stroke
        renderer.preview(stroke)
    }

    func endStroke() {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        renderer.clearPreview()
        perform(.stroke(stroke))
    }

    func cancelStroke() {
        activeStroke = nil
        renderer.clearPreview()
    }

    func beginSelection(at point: CGPoint, shift: Bool, option: Bool) {
        guard selectedTool == .selection else { return }
        selectionStart = point
        selectionMode = shift && option ? .intersect :
            shift ? .add : option ? .subtract : .replace
        renderer.previewSelection(from: point, to: point)
    }

    func updateSelection(to point: CGPoint) {
        guard let selectionStart else { return }
        renderer.previewSelection(from: selectionStart, to: point)
    }

    func endSelection(at point: CGPoint) {
        guard let start = selectionStart else { return }
        selectionStart = nil
        renderer.clearSelectionPreview()
        let x0 = max(0, min(Double(page.width), min(start.x, point.x)))
        let y0 = max(0, min(Double(page.height), min(start.y, point.y)))
        let x1 = max(0, min(Double(page.width), max(start.x, point.x)))
        let y1 = max(0, min(Double(page.height), max(start.y, point.y)))
        guard x1 - x0 >= 0.5, y1 - y0 >= 0.5 else { return }
        perform(.selection(.rectangle(SelectionRect(x: x0, y: y0,
                                                     width: x1 - x0, height: y1 - y0),
                                       selectionMode)))
    }

    func cancelSelection() {
        selectionStart = nil
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
        brush.red = Double(color.x)
        brush.green = Double(color.y)
        brush.blue = Double(color.z)
    }

    func selectLayer(_ id: UUID, shift: Bool = false, command: Bool = false) {
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

    func addLayer() {
        insertLayer(kind: .paint)
    }

    func addFolder() {
        insertLayer(kind: .folder)
    }

    private func insertLayer(kind: LayerRecord.Kind) {
        cancelStroke()
        let count = page.layers.filter { $0.kind == kind }.count + 1
        var layer = LayerRecord(name: kind == .folder ? "文件夹 \(count)" : "图层 \(count)", kind: kind)
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
    }

    func deleteSelectedLayer() {
        guard canDeleteSelection else { return }
        cancelStroke()
        var removed = Set<UUID>()
        for id in selectedLayerIDs {
            guard let range = page.subtreeRange(of: id) else { continue }
            removed.formUnion(page.layers[range].map(\.id))
        }
        var updated = page.layers
        updated.removeAll { removed.contains($0.id) }
        perform(.replaceLayerStack(updated))
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
        if activeStroke != nil { endStroke() }
        return persist()
    }

    func addPage(at index: Int, isSpread: Bool) {
        guard (0...manifest.pageIDs.count).contains(index), saveNow() else { return }
        do {
            var layout = manifest.singlePageLayout ?? page.comicLayout
            layout?.pageSpan = isSpread ? 2 : 1
            let singleWidth = page.isDoublePage ? Int(page.contentRect.width) / 2 : page.width
            let width = layout?.canvasWidthPixels ?? (singleWidth * (isSpread ? 2 : 1))
            let height = layout?.canvasHeightPixels ?? page.height
            guard width <= 16384, height <= 16384 else {
                message = "对开画布尺寸超出当前支持的 16384 px 上限，请使用较小的单页尺寸或分辨率。"
                return
            }
            let newPage = PageRecord.blank(name: "新页面", width: width, height: height,
                                            comicLayout: layout, isSpread: isSpread)
            let scale = min(320.0 / Double(width), 320.0 / Double(height), 1)
            let size = CGSize(width: max(1, Int((Double(width) * scale).rounded())),
                              height: max(1, Int((Double(height) * scale).rounded())))
            let thumbnail = UIGraphicsImageRenderer(size: size).pngData { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            var updated = manifest
            try store.insertPage(newPage, at: index, into: &updated, thumbnail: thumbnail)
            manifest = updated
            pageThumbnails[newPage.id] = UIImage(data: thumbnail)
        } catch {
            message = "无法新增页面：\(error.localizedDescription)"
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
        } catch { message = "合并失败：\(error.localizedDescription)" }
    }

    func splitPage(_ id: UUID) {
        guard manifest.spreadPageIDs.contains(id), saveNow() else { return }
        do {
            let source = try store.loadPage(id)
            try replacePages([id], outputs: PageConversion.split(ConvertedPage(page: source.0, tiles: source.1)))
        } catch { message = "拆分失败：\(error.localizedDescription)" }
    }

    func deletePage(_ id: UUID) {
        guard manifest.pageIDs.contains(id), saveNow() else { return }
        do {
            // Keep an editable project when deleting its last page.
            let outputs: [ConvertedPage] = manifest.pageIDs.count == 1 ?
                [ConvertedPage(page: .blank(width: page.width, height: page.height,
                    comicLayout: page.comicLayout, isSpread: page.isDoublePage), tiles: [:])] : []
            try replacePages([id], outputs: outputs)
        } catch { message = "删除失败：\(error.localizedDescription)" }
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
        guard manifest.pageIDs.contains(id) else { return false }
        guard id != page.id else { return true }
        cancelStroke()
        cancelSelection()
        guard persist() else { return false }
        do {
            let (newPage, tiles) = try store.loadPage(id)
            var updated = manifest
            updated.selectedPageID = id
            try store.saveManifest(updated)
            switchTo(page: newPage, tiles: tiles, manifest: updated)
            needsSave = true
            return persist()
        } catch {
            message = "无法打开页面：\(error.localizedDescription)"
            return false
        }
    }

    func refreshCurrentPageThumbnail() {
        do {
            pageThumbnails[page.id] = UIImage(data: try renderer.projectThumbnailPNG())
        } catch {
            message = "无法生成页面缩略图：\(error.localizedDescription)"
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
            let (record, tiles) = try store.loadPage(id)
            let thumbnailRenderer = try MetalCanvasRenderer(page: record)
            thumbnailRenderer.restore(tiles)
            let data = try thumbnailRenderer.projectThumbnailPNG()
            try store.savePageThumbnail(data, pageID: id)
            pageThumbnails[id] = UIImage(data: data)
        } catch {
            message = "无法读取页面缩略图：\(error.localizedDescription)"
        }
    }

    func exportPNG(cropToContent: Bool) {
        do {
            let data = try renderer.exportPNG(cropToContent: cropToContent)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mangar-第\(pageNumber)页-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            message = "PNG 导出失败：\(error.localizedDescription)"
        }
    }

    private func sample(_ point: CGPoint, _ pressure: CGFloat) -> StrokeSample {
        StrokeSample(x: Double(point.x), y: Double(point.y),
                     pressure: Double(min(1, max(0.15, pressure))))
    }

    private func perform(_ command: EditCommand) {
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
            history.checkpoint = DocumentCheckpoint(page: page, tiles: renderer.snapshot(),
                                                    selection: renderer.selection)
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
        renderer.restore(history.checkpoint.tiles)
        renderer.restoreSelection(history.checkpoint.selection)
        for command in history.commands.prefix(count) { apply(command) }
        reconcileLayerSelection()
    }

    private func reconcileLayerSelection() {
        let existing = Set(page.layers.map(\.id))
        let kept = selectedLayerIDs.filter { existing.contains($0) }
        selectedLayerIDs = kept.isEmpty ? page.layers.last.map { [$0.id] } ?? [] : kept
    }

    private func apply(_ command: EditCommand) {
        switch command {
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
            let allKeys = renderer.tileKeys
            let keys = store.requiresFullSnapshot(page.id) ? allKeys : renderer.dirtyTileKeys
            let changed = renderer.snapshot(keys: keys)
            let thumbnail = try renderer.projectThumbnailPNG()
            try store.save(manifest: manifest, page: page, changedTiles: changed,
                           allTileKeys: allKeys, thumbnail: thumbnail)
            pageThumbnails[page.id] = UIImage(data: thumbnail)
            renderer.clearSavedDirtyTiles()
            needsSave = false
            return true
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func switchTo(page newPage: PageRecord, tiles: [TileKey: Data],
                          manifest newManifest: ProjectManifest) {
        manifest = newManifest
        page = newPage
        renderer.page = newPage
        renderer.restore(tiles)
        renderer.resetViewport()
        selectedLayerIDs = newPage.layers.last.map { [$0.id] } ?? []
        history = CommandHistory(checkpoint: DocumentCheckpoint(page: newPage, tiles: tiles))
        historyRevision += 1
    }
}
