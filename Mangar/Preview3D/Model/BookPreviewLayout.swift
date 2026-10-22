import Foundation

struct BookPageFace: Hashable {
    var source: UUID?
    /// Horizontal range within a trimmed source image; spreads share a texture.
    var u0: Float = 0
    var u1: Float = 1
    static let blank = BookPageFace(source: nil)
}

struct BookOpening: Equatable {
    var left: BookPageFace
    var right: BookPageFace
}

struct BookPreviewLayout {
    let openings: [BookOpening]
    init(manifest: ProjectManifest) {
        openings = PageContainer.arrange(manifest).filter { $0.appendIndex == nil }.map { container in
            if let id = container.spreadID {
                return BookOpening(left: BookPageFace(source: id, u0: 0, u1: 0.5),
                                   right: BookPageFace(source: id, u0: 0.5, u1: 1))
            }
            func face(_ slot: PageContainerSlot) -> BookPageFace {
                if case .page(let id, _) = slot { return BookPageFace(source: id) }
                return .blank
            }
            return BookOpening(left: face(container.left), right: face(container.right))
        }
    }
}

struct BookReverseFace: Hashable {
    var front: BookPageFace
    var reverse: BookPageFace
}

struct BookPageReferenceRequest: Hashable {
    var ownerID: UUID
    var facing: FacingPagePair?
    var reverses: [BookReverseFace]
}

extension BookPreviewLayout {
    func reverseFace(opening: Int, left: Bool) -> BookPageFace {
        let index = opening + (left ? 1 : -1)
        guard openings.indices.contains(index) else { return .blank }
        return left ? openings[index].right : openings[index].left
    }
    func references(manifest: ProjectManifest, page: PageRecord) -> BookPageReferenceRequest? {
        guard manifest.purpose == .book, manifest.pageStructure == .bookSpreads else { return nil }
        var reverse: [BookReverseFace] = []
        for (index, opening) in openings.enumerated() {
            for (left,face) in [(true,opening.left),(false,opening.right)] where face.source == page.id {
                let back = reverseFace(opening: index,left: left)
                if back.source != nil { reverse.append(BookReverseFace(front: face,reverse: back)) }
            }
        }
        return BookPageReferenceRequest(ownerID: page.id,
            facing: FacingPagePair.resolve(manifest: manifest,page: page),reverses: reverse)
    }
}
