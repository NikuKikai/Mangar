import SwiftUI
import UIKit

/// A thumbnail is a click action, including physical keyboard modifiers.
struct LayerThumbnailTapCapture: UIViewRepresentable {
    let label: String
    let onTap: (UIKeyModifierFlags) -> Void
    func makeUIView(context: Context) -> ModifierThumbnailButton {
        let button = ModifierThumbnailButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped(_:)), for: .touchUpInside)
        return button
    }
    func updateUIView(_ view: ModifierThumbnailButton, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.accessibilityLabel = label
        context.coordinator.onTap = onTap
    }
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    final class Coordinator: NSObject {
        var onTap: (UIKeyModifierFlags) -> Void
        init(onTap: @escaping (UIKeyModifierFlags) -> Void) { self.onTap = onTap }
        @objc func tapped(_ button: ModifierThumbnailButton) { onTap(button.modifiers) }
    }
}

final class ModifierThumbnailButton: ImmediateFeedbackButton {
    var modifiers: UIKeyModifierFlags = []
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        modifiers = event?.modifierFlags ?? []
        return super.beginTracking(touch, with: event)
    }
}
