import Foundation
import CoreGraphics

struct LoadedProject {
    var manifest: ProjectManifest
    var page: PageRecord
    var tiles: [TileKey: Data]
}

private struct PageState: Codable {
    var version = 4
    var page: PageRecord
    var tileFiles: [String: String]
    var tileBounds: [String: CGRect]? = nil
}

struct ProjectStore {
    enum StoreError: LocalizedError {
        case unsupportedVersion, missingPage, missingTile, incompleteMigration

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: L10n.text("工程文件版本比当前 App 新，无法安全打开。")
            case .missingPage: L10n.text("找不到工程中的页面文件。")
            case .missingTile: L10n.text("工程中的绘画图块丢失或损坏。")
            case .incompleteMigration: L10n.text("旧工程迁移缺少图块数据。")
            }
        }
    }

    private let manager = FileManager.default
    let root: URL

    init(root: URL) { self.root = root }

    func load() throws -> LoadedProject {
        let manifest = try JSONDecoder().decode(ProjectManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("project.json")))
        guard manifest.formatVersion == 1 else { throw StoreError.unsupportedVersion }
        let pageID = manifest.pageIDs.contains(manifest.selectedPageID)
            ? manifest.selectedPageID : manifest.pageIDs.first
        guard let pageID else { throw StoreError.missingPage }
        let (page, tiles) = try loadPage(pageID)
        return LoadedProject(manifest: manifest, page: page, tiles: tiles)
    }

    func loadPage(_ id: UUID) throws -> (PageRecord, [TileKey: Data]) {
        let directory = pageDirectory(id)
        let stateURL = directory.appendingPathComponent("state.json")
        var page: PageRecord
        var tiles: [TileKey: Data] = [:]
        if manager.fileExists(atPath: stateURL.path) {
            let state = try JSONDecoder().decode(PageState.self, from: Data(contentsOf: stateURL))
            guard (2...4).contains(state.version) else { throw StoreError.unsupportedVersion }
            page = state.page
            for (name, filename) in state.tileFiles {
                guard let key = tileKey(name), filename == URL(fileURLWithPath: filename).lastPathComponent,
                      filename.hasSuffix(".tile") else { throw StoreError.missingTile }
                let file = directory.appendingPathComponent("tiles", isDirectory: true)
                    .appendingPathComponent(filename)
                guard manager.fileExists(atPath: file.path) else { throw StoreError.missingTile }
                let decoded = try TileCodec.decode(Data(contentsOf: file))
                guard decoded.count == key.rawSize else { throw StoreError.missingTile }
                tiles[key] = decoded
            }
        } else {
            let metadata = directory.appendingPathComponent("page.json")
            guard manager.fileExists(atPath: metadata.path) else { throw StoreError.missingPage }
            page = try JSONDecoder().decode(PageRecord.self, from: Data(contentsOf: metadata))
            let tileDirectory = directory.appendingPathComponent("tiles", isDirectory: true)
            let files = (try? manager.contentsOfDirectory(at: tileDirectory,
                                                          includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "rgba" {
                guard let key = tileKey(file.deletingPathExtension().lastPathComponent) else { continue }
                let data = try Data(contentsOf: file)
                guard data.count == TileCodec.rawSize else { throw StoreError.missingTile }
                tiles[key] = data
            }
        }
        if page.backgroundSchemaVersion != 3 {
            if !page.layers.contains(where: { $0.kind == .shape }) {
                page.layers.insert(LayerRecord(name: L10n.text("背景"), kind: .shape, isLocked: true,
                    shape: .rect(bounds: CGRect(x: 0, y: 0, width: page.width, height: page.height), fill: .white)), at: 0)
            }
            page.backgroundSchemaVersion = 3
        }
        return (page, tiles)
    }

    /// Metadata only: reference-page placement never decodes painting tiles.
    func pageRecord(_ id: UUID) throws -> PageRecord {
        let data = try Data(contentsOf: pageDirectory(id).appendingPathComponent("state.json"))
        let state = try JSONDecoder().decode(PageState.self, from: data)
        guard (2...4).contains(state.version) else { throw StoreError.unsupportedVersion }
        return state.page
    }

    func loadPageIndex(_ id: UUID) throws -> (PageRecord, CanvasTileArchive) {
        let directory = pageDirectory(id)
        let state = try JSONDecoder().decode(PageState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        guard (2...4).contains(state.version) else { throw StoreError.unsupportedVersion }
        let archive = CanvasTileArchive()
        for (name,filename) in state.tileFiles {
            guard let key = tileKey(name), filename == URL(fileURLWithPath:filename).lastPathComponent, filename.hasSuffix(".tile") else { throw StoreError.missingTile }
            try archive.importFile(directory.appendingPathComponent("tiles").appendingPathComponent(filename),for:key)
            archive.bounds[key] = state.tileBounds?[name] ?? CGRect(x:key.x*256,y:key.y*256,width:256,height:256)
        }
        return (state.page, archive)
    }

    func loadIndex() throws -> (ProjectManifest, PageRecord, CanvasTileArchive) {
        let manifest = try JSONDecoder().decode(ProjectManifest.self,from:Data(contentsOf:root.appendingPathComponent("project.json")))
        guard manifest.formatVersion == 1, let id = manifest.pageIDs.contains(manifest.selectedPageID) ? manifest.selectedPageID : manifest.pageIDs.first else { throw StoreError.missingPage }
        let (page, archive) = try loadPageIndex(id)
        return (manifest,page,archive)
    }

    func requiresFullSnapshot(_ pageID: UUID) -> Bool {
        let directory = pageDirectory(pageID)
        return manager.fileExists(atPath: directory.appendingPathComponent("page.json").path)
            && !manager.fileExists(atPath: directory.appendingPathComponent("state.json").path)
    }

    var hasThumbnail: Bool {
        manager.fileExists(atPath: root.appendingPathComponent("thumbnail.png").path)
    }

    func save(manifest: ProjectManifest, page: PageRecord, changedTiles: [TileKey: Data],
              allTileKeys: Set<TileKey>, thumbnail: Data? = nil,
              updateProjectThumbnail: Bool = true, updateManifest: Bool = true, tileBounds: [TileKey: CGRect]? = nil) throws {
        let directory = pageDirectory(page.id)
        let tileDirectory = directory.appendingPathComponent("tiles", isDirectory: true)
        try manager.createDirectory(at: tileDirectory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        let previous = manager.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(PageState.self, from: Data(contentsOf: stateURL)) : nil
        if requiresFullSnapshot(page.id) && !allTileKeys.isSubset(of: Set(changedTiles.keys)) {
            throw StoreError.incompleteMigration
        }
        let validLayers = Set(page.layers.map(\.id))
        let maskedLayers = Set(page.layers.filter(\.hasMask).map(\.id))
        let retainedKeys = allTileKeys.filter {
            validLayers.contains($0.layerID) && ($0.target == .content || maskedLayers.contains($0.layerID))
        }
        var files = previous?.tileFiles.filter { name, _ in
            tileKey(name).map { retainedKeys.contains($0) } ?? false
        } ?? [:]
        if previous == nil && !retainedKeys.isSubset(of: Set(changedTiles.keys)) {
            throw StoreError.incompleteMigration
        }
        for (key, raw) in changedTiles where retainedKeys.contains(key) {
            guard raw.count == key.rawSize else { throw StoreError.missingTile }
            let filename = UUID().uuidString + ".tile"
            try TileCodec.encode(raw).write(to: tileDirectory.appendingPathComponent(filename),
                                            options: .atomic)
            files[tileName(key)] = filename
        }
        guard Set(files.keys) == Set(retainedKeys.map(tileName)) else {
            throw StoreError.incompleteMigration
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // This one atomic file is the commit point for metadata and every tile reference.
        try encoder.encode(PageState(page: page, tileFiles: files, tileBounds: tileBounds.map { Dictionary(uniqueKeysWithValues:$0.map { (tileName($0.key), $0.value) }) })).write(to: stateURL,
                                                                          options: .atomic)
        if updateManifest { try saveManifest(manifest) }
        if let thumbnail {
            try savePageThumbnail(thumbnail, pageID: page.id)
            if updateProjectThumbnail {
                try thumbnail.write(to: root.appendingPathComponent("thumbnail.png"), options: .atomic)
            }
        }
        // Old generations remain valid until state.json has committed.
        let referenced = Set(files.values)
        let contents = (try? manager.contentsOfDirectory(at: tileDirectory,
                                                          includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.pathExtension == "tile" && !referenced.contains(file.lastPathComponent) {
            try? manager.removeItem(at: file)
        }
        for file in contents where file.pathExtension == "rgba" {
            try? manager.removeItem(at: file)
        }
        try? manager.removeItem(at: directory.appendingPathComponent("page.json"))
    }

    func pageThumbnail(_ pageID: UUID) -> Data? {
        try? Data(contentsOf: pageDirectory(pageID).appendingPathComponent("thumbnail.png"))
    }

    func savePageThumbnail(_ data: Data, pageID: UUID) throws {
        try data.write(to: pageDirectory(pageID).appendingPathComponent("thumbnail.png"), options: .atomic)
    }

    func insertPage(_ page: PageRecord, at index: Int, into manifest: inout ProjectManifest,
                    thumbnail: Data) throws {
        var updated = manifest
        updated.pageIDs.insert(page.id, at: index)
        if page.isDoublePage { updated.spreadPageIDs.append(page.id) }
        try save(manifest: updated, page: page, changedTiles: [:], allTileKeys: [],
                 thumbnail: thumbnail, updateProjectThumbnail: false)
        manifest = updated
    }

    func saveManifest(_ manifest: ProjectManifest) throws {
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("project.json"), options: .atomic)
    }

    /// New UUID directories are staged before the manifest atomically switches references.
    func replacePages(with outputs: [ConvertedPage], removing ids: [UUID],
                      manifest: ProjectManifest, thumbnails: [UUID: Data]) throws {
        do {
            for output in outputs {
                try save(manifest: manifest, page: output.page, changedTiles: output.tiles,
                         allTileKeys: Set(output.tiles.keys), thumbnail: thumbnails[output.page.id],
                         updateProjectThumbnail: false, updateManifest: false)
            }
            try saveManifest(manifest)
        } catch {
            for output in outputs { try? manager.removeItem(at: pageDirectory(output.page.id)) }
            throw error
        }
        for id in ids { try? manager.removeItem(at: pageDirectory(id)) }
        if let thumbnail = thumbnails[manifest.selectedPageID] ?? pageThumbnail(manifest.selectedPageID) {
            try? thumbnail.write(to: root.appendingPathComponent("thumbnail.png"), options: .atomic)
        }
    }

    private func pageDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func tileName(_ key: TileKey) -> String {
        "\(key.layerID.uuidString)_\(key.target == .mask ? "mask_" : "")\(key.x)_\(key.y)"
    }

    private func tileKey(_ name: String) -> TileKey? {
        let parts = name.split(separator: "_")
        let masked = parts.count == 4 && parts[1] == "mask"
        guard parts.count == 3 || masked, let id = UUID(uuidString: String(parts[0])),
              let x = Int(parts[masked ? 2 : 1]), let y = Int(parts[masked ? 3 : 2]) else { return nil }
        return TileKey(layerID: id, x: x, y: y, target: masked ? .mask : .content)
    }
}
