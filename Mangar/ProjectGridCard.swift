import SwiftUI

/// The grid and every card share these measurements. Content never determines
/// the outer card size, including empty previews, long names and current badges.
enum ProjectCardMetrics {
    static let minimumWidth: CGFloat = 210
    static let maximumWidth: CGFloat = 250
    static let spacing: CGFloat = 18
    static let gridPadding: CGFloat = 28
    static let previewHeight: CGFloat = 140
    static let detailsHeight: CGFloat = 56
    static let detailsPadding: CGFloat = 9
    static var height: CGFloat { previewHeight + detailsHeight }
}

enum ProjectCardAppearance {
    case create
    case project(isCurrent: Bool)
}

/// Owns sizing, clipping, background, border and hit shape for all grid cards.
/// Callers supply content and behavior, without defining another outer frame.
struct ProjectGridCard<Content: View>: View {
    let appearance: ProjectCardAppearance
    private let content: Content

    init(appearance: ProjectCardAppearance, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    var body: some View {
        content
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .frame(height: ProjectCardMetrics.height)
            .clipped()
            .background(background)
            .overlay(Rectangle().strokeBorder(border, style: stroke))
            .contentShape(Rectangle())
    }

    private var background: Color {
        switch appearance {
        case .create: .white.opacity(0.055)
        case .project: Color(red: 0.18, green: 0.19, blue: 0.20)
        }
    }

    private var border: Color {
        switch appearance {
        case .create: .white.opacity(0.2)
        case .project(let current): current ? .accentColor : .white.opacity(0.1)
        }
    }

    private var stroke: StrokeStyle {
        switch appearance {
        case .create: StrokeStyle(lineWidth: 1, dash: [5])
        case .project: StrokeStyle(lineWidth: 1)
        }
    }
}
