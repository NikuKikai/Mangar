import SwiftUI
import UIKit

/// Observe taps without placing a hit-testing overlay over the row's controls.
/// Child pans win recognition; simple taps on chips and handles select the row.
struct LayerRowTapCapture: UIViewRepresentable {
    let onTap: (UIKeyModifierFlags) -> Void
    func makeUIView(context: Context) -> LayerBodyTapView { LayerBodyTapView() }
    func updateUIView(_ view: LayerBodyTapView, context: Context) { view.onTap = onTap }
    static func dismantleUIView(_ view: LayerBodyTapView, coordinator: ()) { view.detach() }
}

/// Click actions such as collapse and unlock consume their tap immediately.
struct LayerRowActionBoundary: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerActionArea { LayerActionArea() }
    func updateUIView(_ view: LayerActionArea, context: Context) {}
}

final class LayerActionArea: UIView {
    static let areas = NSHashTable<LayerActionArea>.weakObjects()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        Self.areas.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class LayerBodyTapRecognizer: UITapGestureRecognizer {
    var modifiers: UIKeyModifierFlags = []
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        modifiers = event.modifierFlags
        super.touchesBegan(touches, with: event)
    }
}

final class LayerBodyTapView: UIView, UIGestureRecognizerDelegate {
    var onTap: ((UIKeyModifierFlags) -> Void)?
    private weak var attachedWindow: UIWindow?
    private lazy var tap: LayerBodyTapRecognizer = {
        let tap = LayerBodyTapRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        attachedWindow = window
        window.addGestureRecognizer(tap)
    }
    func detach() {
        attachedWindow?.removeGestureRecognizer(tap)
        attachedWindow = nil
    }
    @objc private func tapped(_ gesture: LayerBodyTapRecognizer) { onTap?(gesture.modifiers) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = attachedWindow, let target = touch.view,
              !isHidden, alpha > 0, bounds.contains(touch.location(in: self)) else { return false }
        // A floating menu or panel covering the row belongs to a different surface.
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView, target.isDescendant(of: scroll),
              scroll.bounds.contains(touch.location(in: scroll)) else { return false }
        // Text entry owns caret/selection interaction while editing a layer name.
        var hit: UIView? = target
        while let view = hit, view !== scroll {
            if view is UIControl { return false }
            hit = view.superview
        }
        for area in LayerActionArea.areas.allObjects where area.window === window && !area.isHidden {
            if area.bounds.contains(touch.location(in: area)) { return false }
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // First tap can select promptly while a second tap begins inline naming.
        guard let other = otherGestureRecognizer as? UITapGestureRecognizer else { return false }
        return other.numberOfTapsRequired > 1 && other.view is LayerNameView
    }
}
