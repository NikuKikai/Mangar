import UIKit

/// A value's normalized height, drawn beneath a control's text/icon. CALayers
/// add no hit targets and all geometry updates are immediate, including resize.
final class ControlValueLevel {
    private let container = CALayer()
    private let fill = CALayer()
    private let surface = CALayer()

    init() {
        container.masksToBounds = true
        container.addSublayer(fill)
        container.addSublayer(surface)
    }

    static func fraction(_ value: Double, in range: ClosedRange<Double> = 0...1) -> Double {
        let span = range.upperBound-range.lowerBound
        guard value.isFinite,span.isFinite,span > 0 else { return 0 }
        return min(1,max(0,(value-range.lowerBound)/span))
    }

    func update(in view: UIView, fraction: Double?, enabled: Bool, emphasized: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if container.superlayer !== view.layer { view.layer.insertSublayer(container,at: 0) }
        container.frame = view.bounds
        container.cornerRadius = view.layer.cornerRadius
        container.isHidden = fraction == nil
        guard let fraction else { return }
        let level = Self.fraction(fraction)
        let height = view.bounds.height*CGFloat(level)
        fill.frame = CGRect(x: 0,y: view.bounds.height-height,width: view.bounds.width,height: height)
        fill.backgroundColor = (enabled && emphasized
            ? UIColor.systemBlue.withAlphaComponent(0.26)
            : UIColor.white.withAlphaComponent(enabled ? 0.12 : 0.05)).cgColor
        // A single display-pixel waterline distinguishes partial values without
        // adding an outline at either endpoint.
        surface.frame = CGRect(x: 0,y: view.bounds.height-height,width: view.bounds.width,
                               height: 1/max(1,view.contentScaleFactor))
        surface.backgroundColor = UIColor.white.withAlphaComponent(enabled ? 0.3 : 0.1).cgColor
        surface.isHidden = level <= 0 || level >= 1
    }
}
