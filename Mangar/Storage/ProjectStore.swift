import Foundation

struct LoadedProject {
    var manifest: ProjectManifest
    var page: PageRecord
    var tiles: [TileKey: Data]
}

struct ProjectStore {
    enum StoreError: LocalizedError {
        case unsupportedVersion
        case missingPage

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "工程文件版本比当前 App 新，无法安全打开。"
            case .missingPage: "找不到工程中的页面文件。"
            }
        }
    }

    private let manager = FileManager.default
    let root: URL

    init() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Mangar.mangar", isDirectory: true)
    }

    func loadOrCreate() throws -> LoadedProject {
        let manifestURL = root.appendingPathComponent("project.json")
        guard manager.fileExists(atPath: manifestURL.path) else {
            let page = PageRecord.blank()
            let manifest = ProjectManifest(pageIDs: [page.id], selectedPageID: page.id)
            try save(manifest: manifest, page: page, tiles: [:])
            return LoadedProject(manifest: manifest, page: page, tiles: [:])
        }
        let manifest = try JSONDecoder().decode(ProjectManifest.self,
                                                 from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1 else { throw StoreError.unsupportedVersion }
        let pageID = manifest.pageIDs.contains(manifest.selectedPageID)
            ? manifest.selectedPageID : manifest.pageIDs.first
        guard let pageID else { throw StoreError.missingPage }
        let previousPage = try JSONDecoder().decode(
            PageRecord.self,
            from: Data(contentsOf: pageDirectory(pageID).appendingPathComponent("page.json")))
        let (page, tiles) = try loadPage(pageID)
        if previousPage.backgroundSchemaVersion != 3 {
            // Save any migration of a blank project created by the previous version.
            try save(manifest: manifest, page: page, tiles: tiles)
        }
        return LoadedProject(manifest: manifest, page: page, tiles: tiles)
    }

    func loadPage(_ id: UUID) throws -> (PageRecord, [TileKey: Data]) {
        let directory = pageDirectory(id)
        let metadata = directory.appendingPathComponent("page.json")
        guard manager.fileExists(atPath: metadata.path) else { throw StoreError.missingPage }
        var page = try JSONDecoder().decode(PageRecord.self, from: Data(contentsOf: metadata))
        let tileDirectory = directory.appendingPathComponent("tiles", isDirectory: true)
        var tiles: [TileKey: Data] = [:]
        let files = (try? manager.contentsOfDirectory(at: tileDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "rgba" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count == 3, let layerID = UUID(uuidString: String(parts[0])),
                  let x = Int(parts[1]), let y = Int(parts[2]) else { continue }
            let data = try Data(contentsOf: file)
            guard data.count == CanvasConstants.tileSize * CanvasConstants.tileSize * 4 else { continue }
            tiles[TileKey(layerID: layerID, x: x, y: y)] = data
        }
        if page.backgroundSchemaVersion != 3 {
            if !page.layers.contains(where: { $0.kind == .solidWhite }) {
                page.layers.insert(LayerRecord(name: "背景", kind: .solidWhite,
                                               isLocked: true), at: 0)
            }
            page.backgroundSchemaVersion = 3
        }
        return (page, tiles)
    }

    func save(manifest: ProjectManifest, page: PageRecord,
              tiles: [TileKey: Data]) throws {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let pages = root.appendingPathComponent("pages", isDirectory: true)
        try manager.createDirectory(at: pages, withIntermediateDirectories: true)
        let stage = pages.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        let stageTiles = stage.appendingPathComponent("tiles", isDirectory: true)
        try manager.createDirectory(at: stageTiles, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(page).write(to: stage.appendingPathComponent("page.json"), options: .atomic)
            for (key, data) in tiles where page.layers.contains(where: { $0.id == key.layerID }) {
                let filename = "\(key.layerID.uuidString)_\(key.x)_\(key.y).rgba"
                try data.write(to: stageTiles.appendingPathComponent(filename), options: .atomic)
            }
            let destination = pageDirectory(page.id)
            let backup = pages.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: backup)
            }
            do {
                try manager.moveItem(at: stage, to: destination)
                try encoder.encode(manifest).write(to: root.appendingPathComponent("project.json"),
                                                   options: .atomic)
                if manager.fileExists(atPath: backup.path) {
                    try? manager.removeItem(at: backup)
                }
            } catch {
                if manager.fileExists(atPath: destination.path) {
                    try? manager.removeItem(at: destination)
                }
                if manager.fileExists(atPath: backup.path) {
                    try? manager.moveItem(at: backup, to: destination)
                }
                throw error
            }
        } catch {
            try? manager.removeItem(at: stage)
            throw error
        }
    }

    func addPage(to manifest: inout ProjectManifest) throws -> PageRecord {
        let page = PageRecord.blank(name: "第 \(manifest.pageIDs.count + 1) 页")
        manifest.pageIDs.append(page.id)
        manifest.selectedPageID = page.id
        try save(manifest: manifest, page: page, tiles: [:])
        return page
    }

    private func pageDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
