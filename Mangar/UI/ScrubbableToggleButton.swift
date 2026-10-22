import SwiftUI
import UIKit

enum ScrubbableValueStyle {
    case percentage
    case integer(ClosedRange<Double>, pointsPerUnit:Double, prefix:String)
    var range:ClosedRange<Double> { if case .integer(let range,_,_) = self { return range };return 0...1 }
    var pointsPerUnit:Double { if case .integer(_,let points,_) = self { return points };return 200 }
    var accessibilityStep:Double { if case .integer = self { return 1 };return 0.05 }
    func clamped(_ value:Double)->Double {
        let limited=min(range.upperBound,max(range.lowerBound,value))
        if case .integer = self { return limited.rounded() };return limited
    }
    func text(_ value:Double)->String {
        if case .integer(_,_,let prefix) = self { return LayerParallax.label(Int(value.rounded()),prefix:prefix) }
        return "\(Int((value*100).rounded()))%"
    }
}

/// Tap toggles; a vertical drag scrubs a typed value and commits one transaction.
struct ScrubbableToggleButton: UIViewRepresentable {
    let icon: String
    let label: String
    let isOn: Bool
    let value: Double
    var valueStyle:ScrubbableValueStyle = .percentage
    var begin:(() -> Void)? = nil
    var end:((Bool) -> Void)? = nil
    let change: (Bool, Double) -> Void

    func makeUIView(context: Context) -> ScrubbableToggleView { ScrubbableToggleView() }
    func updateUIView(_ view: ScrubbableToggleView,context: Context) {
        view.configure(icon: icon,label: label,isOn: isOn,value: value,
                       enabled: context.environment.isEnabled,valueStyle:valueStyle,begin:begin,end:end,change: change)
    }
    static func dismantleUIView(_ view: ScrubbableToggleView,coordinator: ()) { view.cancelTracking(with: nil) }
}

final class ScrubbableToggleView: UIControl {
    private let image = UIImageView()
    private let feedback = ImmediatePressFeedbackLayer()
    private let valueLevel = ControlValueLevel()
    private var change: ((Bool,Double) -> Void)?
    private var valueStyle:ScrubbableValueStyle = .percentage
    private var onBegin:(() -> Void)?
    private var onEnd:((Bool) -> Void)?
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
                   valueStyle:ScrubbableValueStyle,begin:(() -> Void)?,end:((Bool) -> Void)?,
                   change: @escaping (Bool,Double) -> Void) {
        if !enabled && interactionActive { cancelTracking(with: nil) }
        self.change = change; self.value = value
        self.valueStyle=valueStyle;onBegin=begin;onEnd=end
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
        if abs(delta) >= 3 && !scrubbing { scrubbing = true;onBegin?() }
        if scrubbing {
            apply(on: true,value: initialValue-Double(delta)/valueStyle.pointsPerUnit)
            showIndicator()
        } else { isHighlighted = bounds.contains(touch.location(in: self)); refreshAppearance() }
        return true
    }
    override func endTracking(_ touch: UITouch?,with event: UIEvent?) {
        guard interactionActive else { return }
        if scrubbing, let touch {
            apply(on: true,value: initialValue-Double(touch.location(in: self).y-initialPoint.y)/valueStyle.pointsPerUnit)
        } else if let touch, bounds.contains(touch.location(in: self)) {
            apply(on: !initialIsOn,value: initialValue)
        }
        finish(commit:true)
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        if interactionActive && scrubbing { apply(on: initialIsOn,value: initialValue) }
        finish(commit:false)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTracking(with: nil) }
    }
    private func apply(on: Bool,value: Double) {
        let value = valueStyle.clamped(value)
        isSelected = on; self.value = value
        change?(on,value); refreshAppearance()
    }
    private func finish(commit:Bool) {
        let wasScrubbing=scrubbing
        interactionActive = false; scrubbing = false; isHighlighted = false
        indicator?.removeFromSuperview(); indicator = nil
        if wasScrubbing { onEnd?(commit) }
        refreshAppearance()
    }
    private func refreshAppearance() {
        alpha = isEnabled ? 1 : 0.35
        backgroundColor = isSelected ? UIColor.systemBlue.withAlphaComponent(0.08) : .clear
        valueLevel.update(in: self,fraction: ControlValueLevel.fraction(value,in:valueStyle.range),enabled: isEnabled,emphasized: isSelected)
        image.tintColor = isSelected ? .systemBlue : .white
        accessibilityValue = valueStyle.text(value)
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
        label.text = valueStyle.text(value)
        let anchor = convert(bounds,to: window), safe = window.bounds.inset(by: window.safeAreaInsets)
        label.frame = CGRect(x: min(safe.maxX-44,max(safe.minX,anchor.midX-22)),
                             y: max(safe.minY,anchor.minY-25),width: 44,height: 22)
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        apply(on: !isSelected,value: value); return true
    }
    private func accessibilityScrub(_ direction:Double) {
        guard isEnabled else { return }
        onBegin?();apply(on:true,value:value+direction*valueStyle.accessibilityStep);onEnd?(true)
    }
    override func accessibilityIncrement() { accessibilityScrub(1) }
    override func accessibilityDecrement() { accessibilityScrub(-1) }
}
