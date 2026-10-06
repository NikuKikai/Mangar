import Foundation

enum PageStartSide: String, Codable, CaseIterable {
    case right, left
    var title: String { self == .right ? "右页起始" : "左页起始" }
}

enum PageContainerSlot: Equatable {
    case page(UUID, number: Int)
    case gap(insertionIndex: Int)
    /// Space before the first page when the project starts on the left.
    case beforeStart
}

struct PageContainer: Identifiable, Equatable {
    var id: Int
    var right: PageContainerSlot
    var left: PageContainerSlot
    var spreadID: UUID?
    var firstPageNumber: Int?
    var appendIndex: Int?

    static func arrange(_ manifest: ProjectManifest) -> [PageContainer] {
        var containers: [PageContainer] = []
        var position = manifest.startingSide == .right ? 0 : 1
        var number = 1
        if position == 1 {
            containers.append(PageContainer(id: 0, right: .beforeStart,
                                            left: .gap(insertionIndex: 0)))
        }
        for (index, id) in manifest.pageIDs.enumerated() {
            let spread = manifest.spreadPageIDs.contains(id)
            if spread && position % 2 == 1 {
                containers[position / 2].left = .gap(insertionIndex: index)
                position += 1
            }
            if position / 2 == containers.count {
                containers.append(PageContainer(id: containers.count,
                                                right: .gap(insertionIndex: index),
                                                left: .gap(insertionIndex: index)))
            }
            if spread {
                containers[position / 2].spreadID = id
                containers[position / 2].firstPageNumber = number
                position += 2
                number += 2
            } else {
                if position % 2 == 0 {
                    containers[position / 2].right = .page(id, number: number)
                } else {
                    containers[position / 2].left = .page(id, number: number)
                }
                position += 1
                number += 1
            }
        }
        if position % 2 == 1 {
            containers[position / 2].left = .gap(insertionIndex: manifest.pageIDs.count)
        } else {
            containers.append(PageContainer(id: containers.count,
                                            right: .gap(insertionIndex: manifest.pageIDs.count),
                                            left: .gap(insertionIndex: manifest.pageIDs.count),
                                            appendIndex: manifest.pageIDs.count))
        }
        return containers
    }
}
