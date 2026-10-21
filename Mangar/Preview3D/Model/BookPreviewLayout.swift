import Foundation

/// Presentation is resolved from two independent document dimensions. New forms
/// can supply their own geometry without changing the editor's page arrangement.
enum DocumentPreviewForm {
    case book
    static func resolve(_ manifest: ProjectManifest) -> Self? {
        manifest.purpose == .book && manifest.pageStructure == .bookSpreads ? .book : nil
    }
}

struct BookPageFace: Equatable {
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
