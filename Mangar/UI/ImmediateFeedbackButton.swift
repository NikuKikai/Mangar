import UIKit

/// Overlay feedback preserves the control's current/selected background and
/// changes immediately. It also works for UIKit controls hosted in SwiftUI.
@MainActor
final class ImmediatePressFeedbackLayer {
    private let overlay = CALayer()
    func update(in view: UIView, pressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlay.backgroundColor = UIColor.white.withAlphaComponent(0.18).cgColor
        overlay.frame = view.bounds
        overlay.isHidden = !pressed
        if overlay.superlayer !== view.layer { view.layer.addSublayer(overlay) }
    }
}

class ImmediateFeedbackButton: UIButton {
    private let feedback = ImmediatePressFeedbackLayer()
    override var isHighlighted: Bool {
        didSet { updateFeedback() }
    }
    override var isEnabled: Bool {
        didSet { updateFeedback() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFeedback()
    }
    private func updateFeedback() { feedback.update(in: self, pressed: isHighlighted && isEnabled) }
}
