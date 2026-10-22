import Foundation

/// Presentation is resolved from two independent document dimensions. New forms
/// can supply their own geometry without changing the editor's page arrangement.
enum DocumentPreviewForm {
    case book, sphere
    static func resolve(_ manifest: ProjectManifest, page: PageRecord? = nil) -> Self? {
        if manifest.purpose == .unrestricted, page?.pageSurface.kind == .sphere { return .sphere }
        return manifest.purpose == .book && manifest.pageStructure == .bookSpreads ? .book : nil
    }
}

enum DocumentPreviewRenderingError: Error { case unavailable }
