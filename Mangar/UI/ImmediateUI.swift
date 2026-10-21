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
            .modifier(ImmediatePressFeedback(pressed: configuration.isPressed && showsPressFeedback))
    }
}

struct ImmediateBorderedButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor : Color.white.opacity(0.08))
            .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .modifier(ImmediatePressFeedback(pressed: configuration.isPressed))
    }
}
