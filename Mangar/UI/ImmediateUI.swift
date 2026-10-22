import SwiftUI

/// Applied to each hosting root so state changes never inherit an animated transaction.
struct ImmediateUIModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentTransition(.identity)
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

extension View {
    func immediateUI() -> some View { modifier(ImmediateUIModifier()) }
}

/// Shared square targets; glyph sizing stays independent of button geometry.
enum CompactButtonSize: CGFloat {
    case toolbar = 24
    case panel = 18
    case tool = 34
}
enum CompactControlMetrics {
    static let buttonSpacing: CGFloat = 1
    static var toolbarHeight: CGFloat { CompactButtonSize.toolbar.rawValue + 2 }
}
extension View {
    /// Apply inside a Button label, after sizing its glyph.
    func compactIconTarget(_ size: CompactButtonSize = .toolbar) -> some View {
        frame(width: size.rawValue, height: size.rawValue)
            .contentShape(Rectangle())
    }
}

/// Shared press feedback is immediate and layers over existing selected colors.
struct ImmediatePressFeedback: ViewModifier {
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.overlay {
            if pressed && enabled {
                Rectangle().fill(Color.white.opacity(0.18)).allowsHitTesting(false)
            }
        }.immediateUI()
    }
}

/// Avoid system fades while preserving visible pointer/finger/Pencil presses.
struct ImmediateButtonStyle: ButtonStyle {
    var showsPressFeedback = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .modifier(ImmediatePressFeedback(pressed: configuration.isPressed && showsPressFeedback))
    }
}

struct ImmediateBorderedButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minHeight: CompactButtonSize.toolbar.rawValue)
            .contentShape(Rectangle())
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor : Color.white.opacity(0.08))
            .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .modifier(ImmediatePressFeedback(pressed: configuration.isPressed))
    }
}
