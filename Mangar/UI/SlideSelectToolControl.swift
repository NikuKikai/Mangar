import SwiftUI
import UIKit

struct SlideSelectToolItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
}

/// Tap activates the remembered tool; drag right to reveal tools and release to choose.
struct SlideSelectToolControl: UIViewRepresentable {
    let items: [SlideSelectToolItem]
    let currentID: String
    let selected: Bool
    let activate: () -> Void
    let choose: (String) -> Void

    func makeUIView(context: Context) -> SlideSelectToolView { SlideSelectToolView() }
    func updateUIView(_ view: SlideSelectToolView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.configure(items: items, currentID: currentID, selected: selected,
                       enabled: context.environment.isEnabled, activate: activate, choose: choose)
    }
    static func dismantleUIView(_ view: SlideSelectToolView, coordinator: ()) { view.close() }
}

final class SlideSelectToolView: UIControl, UIGestureRecognizerDelegate {
    private let icon = UIImageView()
    private let indicator = UIView()
    private var items: [SlideSelectToolItem] = []
    private var currentID = ""
    private var activate: (() -> Void)?
    private var choose: ((String) -> Void)?
    private var panel: UIView?
    private var rows: [UIButton] = []
    private var hoveredID: String?
    private var sliding = false
    private weak var popupWindow: UIWindow?
    private var outsideTap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        icon.isUserInteractionEnabled = false
        indicator.isUserInteractionEnabled = false
        addSubview(icon); addSubview(indicator)
        isAccessibilityElement = true
        accessibilityHint = "点按使用当前工具；向右滑动展开，移动到工具上松开选择"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "展开工具", target: self,
            selector: #selector(accessibilityOpen))]
        NotificationCenter.default.addObserver(self, selector: #selector(close),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [SlideSelectToolItem], currentID: String, selected: Bool, enabled: Bool,
                   activate: @escaping () -> Void, choose: @escaping (String) -> Void) {
        if !enabled || (panel != nil && self.items != items) { close() }
        self.items = items; self.currentID = currentID
        self.activate = activate; self.choose = choose
        isSelected = selected; isEnabled = enabled
        let current = items.first { $0.id == currentID }
        icon.image = UIImage(systemName: current?.icon ?? "pencil.tip",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)) ?? UIImage(systemName: "pencil.tip")
        accessibilityLabel = current?.name ?? "画笔"
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        refreshAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        indicator.frame = CGRect(x: bounds.maxX - 3, y: (bounds.height - 7) / 2, width: 1, height: 7)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { close() }
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        sliding = false
        isHighlighted = true
        refreshAppearance()
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if touch.location(in: self).x > bounds.maxX + 4, !sliding {
            sliding = true
            open()
        }
        updateHover(touch)
        isHighlighted = bounds.contains(touch.location(in: self))
        refreshAppearance()
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { updateHover(touch) }
        let chosen = sliding ? hoveredID : nil
        let tapped = !sliding && touch.map { bounds.contains($0.location(in: self)) } == true
        close()
        guard isEnabled else { return }
        if let chosen { choose?(chosen) }
        else if tapped { activate?() }
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        close()
    }

    private func open() {
        guard panel == nil, let window, !items.isEmpty else { return }
        let popup = UIView()
        popup.backgroundColor = UIColor(white: 0.12, alpha: 1)
        popup.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        popup.layer.borderWidth = 1
        let anchor = convert(bounds, to: window)
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 4, dy: 4)
        let width: CGFloat = min(142, safe.width)
        let height = CGFloat(items.count) * 30 + 6
        let current = CGFloat(items.firstIndex { $0.id == currentID } ?? 0)
        popup.frame = CGRect(x: max(safe.minX, min(anchor.maxX + 4, safe.maxX - width)),
            y: max(safe.minY, min(anchor.midY - 18 - current * 30, safe.maxY - height)), width: width, height: height)
        rows = items.enumerated().map { index, item in
            let row = UIButton(type: .custom)
            row.tag = index
            row.frame = CGRect(x: 3, y: 3 + CGFloat(index) * 30, width: width - 6, height: 30)
            let image = UIImageView(image: UIImage(systemName: item.icon,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)) ?? UIImage(systemName: "pencil.tip"))
            image.tintColor = .white
            image.contentMode = .scaleAspectFit
            image.frame = CGRect(x: 6, y: 5, width: 20, height: 20)
            image.isUserInteractionEnabled = false
            row.addSubview(image)
            let label = UILabel(frame: CGRect(x: 34, y: 0, width: width - 43, height: 30))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .white
            label.text = item.name
            label.isUserInteractionEnabled = false
            row.addSubview(label)
            row.accessibilityLabel = item.name
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            popup.addSubview(row)
            return row
        }
        panel = popup; popupWindow = window
        window.addSubview(popup)
        let outside = UITapGestureRecognizer(target: self, action: #selector(close))
        outside.cancelsTouchesInView = false; outside.delegate = self
        window.addGestureRecognizer(outside)
        outsideTap = outside
        refreshAppearance()
    }
    private func updateHover(_ touch: UITouch) {
        guard let panel else { return }
        let point = touch.location(in: panel)
        hoveredID = rows.first { $0.frame.contains(point) }.map { items[$0.tag].id }
    }
    private func refreshAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        alpha = isEnabled ? 1 : 0.35
        backgroundColor = isHighlighted ? UIColor.white.withAlphaComponent(0.16) :
            isSelected ? UIColor.gray.withAlphaComponent(0.4) : .clear
        indicator.backgroundColor = panel != nil ? .systemBlue : UIColor.white.withAlphaComponent(0.45)
        for row in rows {
            let id = items[row.tag].id
            row.backgroundColor = hoveredID == id ? UIColor.systemBlue.withAlphaComponent(0.45) :
                currentID == id ? UIColor.white.withAlphaComponent(0.1) : .clear
            row.accessibilityTraits = currentID == id ? [.button, .selected] : [.button]
        }
    }
    @objc private func rowTapped(_ sender: UIButton) {
        guard items.indices.contains(sender.tag) else { return }
        let id = items[sender.tag].id
        close(); choose?(id)
    }
    @objc private func accessibilityOpen() -> Bool { open(); return true }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        activate?(); return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let panel else { return false }
        return !panel.bounds.contains(touch.location(in: panel)) && !bounds.contains(touch.location(in: self))
    }
    @objc func close() {
        if let outsideTap { popupWindow?.removeGestureRecognizer(outsideTap) }
        outsideTap = nil; popupWindow = nil
        panel?.removeFromSuperview(); panel = nil
        rows = []; hoveredID = nil; sliding = false; isHighlighted = false
        refreshAppearance()
    }
}
