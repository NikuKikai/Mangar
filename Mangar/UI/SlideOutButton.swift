import SwiftUI
import UIKit

/// Click performs the action; release below the button reveals its auxiliary controls.
struct SlideOutButton: UIViewRepresentable {
    let icon: String
    let label: String
    let isOn: Bool
    let isExpanded: Bool
    let action: () -> Void
    let expand: () -> Void

    func makeUIView(context: Context) -> SlideOutButtonView { SlideOutButtonView() }
    func updateUIView(_ view: SlideOutButtonView, context: Context) {
        view.configure(icon: icon, label: label, isOn: isOn, isExpanded: isExpanded,
                       enabled: context.environment.isEnabled, action: action, expand: expand)
    }
    static func dismantleUIView(_ view: SlideOutButtonView, coordinator: ()) {
        view.cancelTracking(with: nil)
    }
}

final class SlideOutButtonView: UIControl {
    private let image = UIImageView()
    private let indicator = UIView()
    private var expanded = false
    private var pendingExpansion = false
    private var action: (() -> Void)?
    private var expand: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = false
        indicator.isUserInteractionEnabled = false
        addSubview(image)
        addSubview(indicator)
        isAccessibilityElement = true
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "展开参数", target: self,
            selector: #selector(accessibilityExpand))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(icon: String, label: String, isOn: Bool, isExpanded: Bool,
                   enabled: Bool, action: @escaping () -> Void, expand: @escaping () -> Void) {
        image.image = UIImage(systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        accessibilityLabel = label
        accessibilityHint = "单击开关；按住向下移出按钮并松开展开参数"
        accessibilityValue = "\(isOn ? "已启用" : "未启用")，\(isExpanded ? "参数已展开" : "参数已收起")"
        accessibilityTraits = isOn ? [.button, .selected] : [.button]
        isSelected = isOn
        expanded = isExpanded
        isEnabled = enabled
        self.action = action
        self.expand = expand
        updateAppearance()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        image.frame = CGRect(x: (bounds.width - 14) / 2, y: (bounds.height - 17) / 2,
                             width: 14, height: 14)
        indicator.frame = CGRect(x: (bounds.width - 7) / 2, y: bounds.height - 3,
                                 width: 7, height: 1)
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        isHighlighted = true
        pendingExpansion = false
        updateAppearance()
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        pendingExpansion = point.y > bounds.maxY
        isHighlighted = bounds.contains(point)
        updateAppearance()
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let point = touch?.location(in: self)
        let shouldExpand = point.map { $0.y > bounds.maxY } ?? false
        let shouldAct = point.map { bounds.contains($0) } ?? false
        isHighlighted = false
        pendingExpansion = false
        updateAppearance()
        guard isEnabled else { return }
        if shouldExpand { expand?() }
        else if shouldAct { action?() }
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        isHighlighted = false
        pendingExpansion = false
        updateAppearance()
    }
    private func updateAppearance() {
        image.tintColor = .white
        alpha = isEnabled ? 1 : 0.35
        backgroundColor = isHighlighted ? UIColor.white.withAlphaComponent(0.16) :
            isSelected ? UIColor.systemBlue.withAlphaComponent(0.25) : .clear
        indicator.backgroundColor = expanded || pendingExpansion ? .systemBlue : UIColor.white.withAlphaComponent(0.45)
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
    @objc private func accessibilityExpand() -> Bool {
        guard isEnabled else { return false }
        expand?()
        return true
    }
}
