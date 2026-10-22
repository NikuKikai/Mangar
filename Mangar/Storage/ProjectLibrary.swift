import Foundation
import UIKit

struct ProjectSummary: Identifiable {
    let url: URL
    let name: String
    let purpose: ProjectPurpose
    let pageCount: Int
    let modifiedAt: Date
    let thumbnail: Data?

    var id: String { Self.identity(for: url) }

    static func identity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct ProjectLibrary {
    enum LibraryError: LocalizedError {
        case invalidProject
        var errorDescription: String? { L10n.text("所选文件夹不是 Mangar 工程。") }
    }

    private let manager = FileManager.default
    let documents: URL

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documents = documents
    }

    func projects() throws -> [ProjectSummary] {
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var roots = (try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "mangar" }
        let legacy = documents.appendingPathComponent("Mangar.mangar", isDirectory: true)
        if manager.fileExists(atPath: legacy.path) { roots.append(legacy) }
        return roots.compactMap { root in
            let manifestURL = root.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: data) else {
                return nil
            }
            let modified = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let thumbnail = try? Data(contentsOf: root.appendingPathComponent("thumbnail.png"))
            return ProjectSummary(url: root, name: manifest.name, purpose:manifest.purpose,
                                  pageCount: manifest.logicalPageCount,
                                  modifiedAt: modified, thumbnail: thumbnail)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func create(_ request: ProjectCreation) throws -> URL {
        let name = request.name, pageCount = request.pageCount, startingSide = request.startingSide
        let layout = request.layout
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent(UUID().uuidString + ".mangar", isDirectory: true)
        let store = ProjectStore(root: root)
        let width = layout?.canvasWidthPixels ?? Int(request.boundary.initialRect.width)
        let height = layout?.canvasHeightPixels ?? Int(request.boundary.initialRect.height)
        let first = PageRecord.blank(width: width, height: height, comicLayout: layout, boundary: request.boundary, surface: request.surface)
        var manifest = ProjectManifest(name: name, pageIDs: [first.id], selectedPageID: first.id,
                                       startingSide: startingSide, singlePageLayout: layout, purpose: request.purpose,
                                       pageStructure: request.purpose == .book ? .bookSpreads : .cards, initialBoundary: request.boundary)
        let scale = min(320.0 / Double(width), 320.0 / Double(height), 1)
        let thumbnailSize = CGSize(width: max(1, Int((Double(width) * scale).rounded())),
                                   height: max(1, Int((Double(height) * scale).rounded())))
        let thumbnail = UIGraphicsImageRenderer(size: thumbnailSize).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: thumbnailSize))
        }
        do {
            try store.save(manifest: manifest, page: first, changedTiles: [:],
                           allTileKeys: [], thumbnail: thumbnail)
            if pageCount > 1 {
                for number in 2...pageCount {
                    let page = PageRecord.blank(name: L10n.format("第 %@ 页", "\(number)"), width: width,
                                                height: height, comicLayout: layout, boundary: request.boundary, surface: request.surface)
                    manifest.pageIDs.append(page.id)
                    try store.save(manifest: manifest, page: page,
                                   changedTiles: [:], allTileKeys: [], thumbnail: thumbnail)
                }
            }
            return root
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    func importProject(from source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let manifestURL = source.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: data),
              let first = manifest.pageIDs.first,
              manager.fileExists(atPath: source.appendingPathComponent("pages/\(first.uuidString)/state.json").path) ||
              manager.fileExists(atPath: source.appendingPathComponent("pages/\(first.uuidString)/page.json").path)
        else { throw LibraryError.invalidProject }
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".mangar",
                                                            isDirectory: true)
        try manager.copyItem(at: source, to: destination)
        return destination
    }

    func deleteProject(at url: URL) throws {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let legacy = documents.appendingPathComponent("Mangar.mangar", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.pathExtension == "mangar",
              root.deletingLastPathComponent() == directory || root == legacy else {
            throw LibraryError.invalidProject
        }
        try manager.removeItem(at: root)
    }
}
