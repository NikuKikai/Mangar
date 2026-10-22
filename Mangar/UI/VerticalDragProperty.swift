import SwiftUI
import UIKit

/// A compact property chip shared by numeric scrubbing and drag-to-select menus.
struct VerticalDragProperty: UIViewRepresentable {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    enum Value {
        case number(Double, ClosedRange<Double>, pointsPerUnit: Double)
        case choice(Int, [String])

        var fraction: Double? {
            if case .number(let value,let range,_) = self { return ControlValueLevel.fraction(value,in: range) }
            return nil
        }
    }
    let text: String
    let label: String
    let value: Value
    let begin: () -> Void
    let change: (Double) -> Void
    let end: (Bool) -> Void
    var emphasized = false
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> VerticalPropertyView { VerticalPropertyView() }
    func updateUIView(_ view: VerticalPropertyView, context: Context) {
        let _ = interfaceLanguage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.configure(text: text, label: label, value: value, begin: begin, change: change, end: end,
                       enabled: isEnabled, emphasized: emphasized)
    }
    static func dismantleUIView(_ view: VerticalPropertyView, coordinator: ()) { view.finish(commit: false) }
}

final class VerticalPropertyView: UIView, UIGestureRecognizerDelegate {
    private let title = UILabel()
    private let valueLevel = ControlValueLevel()
    private var levelFraction: Double?
    private var levelEmphasized = false
    private var value: VerticalDragProperty.Value = .number(1, 0...1, pointsPerUnit: 200)
    private var onBegin: (() -> Void)?
    private var onChange: ((Double) -> Void)?
    private var onEnd: ((Bool) -> Void)?
    private var initialValue: Double = 0
    private var active = false
    private var popup: UIView?
    private var rows: [UILabel] = []
    private var selectedIndex = 0
    private let rowHeight: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        title.textColor = UIColor.white.withAlphaComponent(0.65)
        title.lineBreakMode = .byTruncatingTail
        title.textAlignment = .center
        title.isUserInteractionEnabled = false
        addSubview(title)
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        addGestureRecognizer(drag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = bounds.insetBy(dx: 2, dy: 0)
        refreshValueLevel()
    }
    private func refreshValueLevel() {
        valueLevel.update(in: self,fraction: levelFraction,enabled: isUserInteractionEnabled,
                          emphasized: active || levelEmphasized)
    }
    func configure(text: String, label: String, value: VerticalDragProperty.Value,
                   begin: @escaping () -> Void, change: @escaping (Double) -> Void,
                   end: @escaping (Bool) -> Void, enabled: Bool, emphasized: Bool) {
        if !enabled { finish(commit: false) }
        isUserInteractionEnabled = enabled
        title.textColor = UIColor.white.withAlphaComponent(enabled ? (emphasized ? 0.95 : 0.65) : 0.3)
        accessibilityTraits = enabled ? [.adjustable] : [.adjustable, .notEnabled]
        title.text = text
        accessibilityLabel = label
        if case .choice(let index, let options) = value, options.indices.contains(index) {
            accessibilityValue = options[index]
        } else { accessibilityValue = text }
        self.value = value
        levelFraction = value.fraction
        levelEmphasized = emphasized
        refreshValueLevel()
        onBegin = begin; onChange = change; onEnd = end
        accessibilityHint = L10n.text("按住并上下拖动以调整，松开确认")
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            active = true
            backgroundColor = UIColor.white.withAlphaComponent(0.24)
            switch value {
            case .number(let number, _, _): initialValue = number
            case .choice(let index, let options):
                initialValue = Double(index)
                selectedIndex = index
                showChoices(options)
            }
            onBegin?()
            update(gesture.translation(in: self).y)
        case .changed: update(gesture.translation(in: self).y)
        case .ended: update(gesture.translation(in: self).y); finish(commit: true)
        case .cancelled, .failed: finish(commit: false)
        default: break
        }
    }
    private func update(_ translation: CGFloat) {
        guard active else { return }
        switch value {
        case .number(_, let range, let pointsPerUnit):
            let next = min(range.upperBound, max(range.lowerBound, initialValue - Double(translation) / pointsPerUnit))
            levelFraction = ControlValueLevel.fraction(next,in: range)
            refreshValueLevel()
            onChange?(next)
        case .choice(_, let options):
            let next = min(options.count - 1, max(0, Int(initialValue) + Int((translation / rowHeight).rounded())))
            guard next >= 0 else { return }
            selectedIndex = next
            highlightChoice()
            onChange?(Double(next))
        }
    }
    func finish(commit: Bool) {
        popup?.removeFromSuperview(); popup = nil; rows = []
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        guard active else { refreshValueLevel(); return }
        active = false
        if !commit, case .number(_,let range,_) = value {
            levelFraction = ControlValueLevel.fraction(initialValue,in: range)
        }
        refreshValueLevel()
        onEnd?(commit)
    }
    private func showChoices(_ options: [String]) {
        guard let window else { return }
        let anchor = convert(bounds, to: window)
        let width: CGFloat = 128
        let height = CGFloat(options.count) * rowHeight
        let menu = UIView(frame: CGRect(
            x: max(4, min(window.bounds.maxX - width - 4, anchor.maxX - width)),
            y: max(window.safeAreaInsets.top + 4,
                   min(window.bounds.maxY - window.safeAreaInsets.bottom - height - 4,
                       anchor.midY - CGFloat(selectedIndex) * rowHeight - rowHeight / 2)),
            width: width, height: height))
        menu.backgroundColor = UIColor(red: 0.17, green: 0.18, blue: 0.19, alpha: 1)
        menu.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        menu.layer.borderWidth = 1
        menu.layer.shadowColor = UIColor.black.cgColor
        menu.layer.shadowOpacity = 0.4
        menu.layer.shadowRadius = 6
        menu.layer.shadowOffset = CGSize(width: 0, height: 3)
        menu.isUserInteractionEnabled = false
        rows = options.enumerated().map { index, text in
            let row = UILabel(frame: CGRect(x: 1, y: CGFloat(index) * rowHeight,
                                           width: width - 2, height: rowHeight))
            row.text = "  " + text
            row.font = .systemFont(ofSize: 11)
            row.textColor = .white
            menu.addSubview(row)
            return row
        }
        window.addSubview(menu)
        popup = menu
        highlightChoice()
    }
    private func highlightChoice() {
        for (index, row) in rows.enumerated() {
            row.backgroundColor = index == selectedIndex ? UIColor.systemBlue.withAlphaComponent(0.45) : .clear
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) >= abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view is UIScrollView
    }
    override func accessibilityIncrement() { adjustAccessibility(1) }
    override func accessibilityDecrement() { adjustAccessibility(-1) }
    private func adjustAccessibility(_ direction: Double) {
        guard isUserInteractionEnabled else { return }
        onBegin?()
        switch value {
        case .number(let number, let range, _):
            onChange?(min(range.upperBound, max(range.lowerBound, number + direction * (range.upperBound - range.lowerBound) / 100)))
        case .choice(let index, let options):
            onChange?(min(Double(options.count - 1), max(0, Double(index) + direction)))
        }
        onEnd?(true)
    }
}
