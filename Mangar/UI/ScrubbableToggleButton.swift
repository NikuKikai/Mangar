import SwiftUI
import UIKit

/// Tap toggles; a vertical drag adjusts a normalized value without toggling on release.
struct ScrubbableToggleButton: UIViewRepresentable {
    let icon: String
    let label: String
    let isOn: Bool
    let value: Double
    let change: (Bool, Double) -> Void

    func makeUIView(context: Context) -> ScrubbableToggleView { ScrubbableToggleView() }
    func updateUIView(_ view: ScrubbableToggleView,context: Context) {
        view.configure(icon: icon,label: label,isOn: isOn,value: value,
                       enabled: context.environment.isEnabled,change: change)
    }
    static func dismantleUIView(_ view: ScrubbableToggleView,coordinator: ()) { view.cancelTracking(with: nil) }
}

final class ScrubbableToggleView: UIControl {
    private let image = UIImageView()
    private let feedback = ImmediatePressFeedbackLayer()
    private let valueLevel = ControlValueLevel()
    private var change: ((Bool,Double) -> Void)?
    private var value: Double = 1
    private var initialValue: Double = 1
    private var initialIsOn = false
    private var initialPoint = CGPoint.zero
    private var interactionActive = false
    private var scrubbing = false
    private var indicator: UILabel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .center; image.isUserInteractionEnabled = false
        addSubview(image)
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(icon: String,label: String,isOn: Bool,value: Double,enabled: Bool,
                   change: @escaping (Bool,Double) -> Void) {
        if !enabled && interactionActive { cancelTracking(with: nil) }
        self.change = change; self.value = value
        isEnabled = enabled; isSelected = isOn
        let artwork = ControlSymbolArtwork.metrics(for: icon)
        image.image = UIImage(systemName: icon,withConfiguration: UIImage.SymbolConfiguration(pointSize: artwork.pointSize,weight: .regular))
        accessibilityLabel = label
        accessibilityHint = L10n.text("按住并上下拖动以调整，松开确认")
        refreshAppearance()
    }
    override func layoutSubviews() {
        super.layoutSubviews(); image.frame = bounds; refreshAppearance()
    }
    override func beginTracking(_ touch: UITouch,with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        interactionActive = true; scrubbing = false
        initialPoint = touch.location(in: self)
        initialValue = value; initialIsOn = isSelected
        isHighlighted = true; refreshAppearance(); return true
    }
    override func continueTracking(_ touch: UITouch,with event: UIEvent?) -> Bool {
        let delta = touch.location(in: self).y - initialPoint.y
        if abs(delta) >= 3 { scrubbing = true }
        if scrubbing {
            apply(on: true,value: initialValue-Double(delta)/200)
            showIndicator()
        } else { isHighlighted = bounds.contains(touch.location(in: self)); refreshAppearance() }
        return true
    }
    override func endTracking(_ touch: UITouch?,with event: UIEvent?) {
        guard interactionActive else { return }
        if scrubbing, let touch {
            apply(on: true,value: initialValue-Double(touch.location(in: self).y-initialPoint.y)/200)
        } else if let touch, bounds.contains(touch.location(in: self)) {
            apply(on: !initialIsOn,value: initialValue)
        }
        finish()
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        if interactionActive && scrubbing { apply(on: initialIsOn,value: initialValue) }
        finish()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTracking(with: nil) }
    }
    private func apply(on: Bool,value: Double) {
        let value = min(1,max(0,value))
        isSelected = on; self.value = value
        change?(on,value); refreshAppearance()
    }
    private func finish() {
        interactionActive = false; scrubbing = false; isHighlighted = false
        indicator?.removeFromSuperview(); indicator = nil
        refreshAppearance()
    }
    private func refreshAppearance() {
        alpha = isEnabled ? 1 : 0.35
        backgroundColor = isSelected ? UIColor.systemBlue.withAlphaComponent(0.08) : .clear
        valueLevel.update(in: self,fraction: value,enabled: isEnabled,emphasized: isSelected)
        image.tintColor = isSelected ? .systemBlue : .white
        accessibilityValue = "\(Int((value*100).rounded()))%"
        accessibilityTraits = [.button,.adjustable]
        if isSelected { accessibilityTraits.insert(.selected) }
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        feedback.update(in: self,pressed: isHighlighted && isEnabled)
    }
    private func showIndicator() {
        guard let window else { return }
        let label: UILabel
        if let indicator { label = indicator }
        else {
            label = UILabel(); label.font = .monospacedSystemFont(ofSize: 11,weight: .regular)
            label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            label.textAlignment = .center; label.isUserInteractionEnabled = false
            window.addSubview(label); indicator = label
        }
        label.text = "\(Int((value*100).rounded()))%"
        let anchor = convert(bounds,to: window), safe = window.bounds.inset(by: window.safeAreaInsets)
        label.frame = CGRect(x: min(safe.maxX-44,max(safe.minX,anchor.midX-22)),
                             y: max(safe.minY,anchor.minY-25),width: 44,height: 22)
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        apply(on: !isSelected,value: value); return true
    }
    override func accessibilityIncrement() { if isEnabled { apply(on: true,value: value+0.05) } }
    override func accessibilityDecrement() { if isEnabled { apply(on: true,value: value-0.05) } }
}
