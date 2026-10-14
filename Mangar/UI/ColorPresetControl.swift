import SwiftUI
import UIKit

/// Tap edits/selects the foreground; drag right opens a release-to-select palette.
struct ColorPresetControl: UIViewRepresentable {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    let color: AppColor
    let selected: Bool
    let presets: [AppColor]
    let tap: () -> Void
    let choose: (Int) -> Void
    let store: (Int) -> Void

    func makeUIView(context: Context) -> ColorPresetView { ColorPresetView() }
    func updateUIView(_ view: ColorPresetView, context: Context) {
        let _ = interfaceLanguage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.configure(color: color, selected: selected, presets: presets, tap: tap, choose: choose, store: store)
    }
    static func dismantleUIView(_ view: ColorPresetView, coordinator: ()) { view.close() }
}

final class ColorPresetView: UIControl, UIGestureRecognizerDelegate {
    private let swatch = UIView()
    private let selectionOutline = UIView()
    private var presets: [AppColor] = []
    private var tapAction: (() -> Void)?
    private var chooseAction: ((Int) -> Void)?
    private var storeAction: ((Int) -> Void)?
    private var panel: UIView?
    private var cells: [UIButton] = []
    private weak var saveButton: UIButton?
    private var outsideTap: UITapGestureRecognizer?
    private weak var popupWindow: UIWindow?
    private var dragged = false
    private var storing = false
    private var hovered: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        swatch.isUserInteractionEnabled = false
        addSubview(swatch)
        selectionOutline.isUserInteractionEnabled = false
        selectionOutline.layer.borderWidth = 2
        selectionOutline.layer.borderColor = UIColor.systemBlue.cgColor
        addSubview(selectionOutline)
        isAccessibilityElement = true
        accessibilityLabel = L10n.text("当前颜色")
        accessibilityHint = L10n.text("点按打开颜色面板；向右滑动选择预设颜色")
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("打开预设颜色"), target: self, selector: #selector(accessibilityOpen))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        super.layoutSubviews()
        swatch.frame = CGRect(x: (bounds.width - 25) / 2, y: (bounds.height - 25) / 2, width: 25, height: 25)
        selectionOutline.frame = swatch.frame.insetBy(dx: -2, dy: -2)
    }
    func configure(color: AppColor, selected: Bool, presets: [AppColor], tap: @escaping () -> Void,
                   choose: @escaping (Int) -> Void, store: @escaping (Int) -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        swatch.backgroundColor = color.uiColor
        swatch.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        swatch.layer.borderWidth = 1
        selectionOutline.isHidden = !selected
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        accessibilityLabel = L10n.text("当前颜色")
        accessibilityHint = L10n.text("点按打开颜色面板；向右滑动选择预设颜色")
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("打开预设颜色"), target: self, selector: #selector(accessibilityOpen))]
        self.presets = presets
        tapAction = tap; chooseAction = choose; storeAction = store
        refreshCells()
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragged = false
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if touch.location(in: self).x > bounds.maxX + 4 && !dragged {
            dragged = true
            open()
        }
        updateHover(touch)
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if dragged {
            if let touch { updateHover(touch) }
            if let hovered { activate(hovered) }
            else { close() }
        } else { close(); tapAction?() }
        dragged = false
    }
    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        close()
        dragged = false
    }
    private func open() {
        guard panel == nil, let window else { return }
        storing = false
        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        panel.layer.borderWidth = 1
        let anchor = convert(bounds, to: window)
        let width: CGFloat = 136, height: CGFloat = 162
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 4, dy: 4)
        panel.frame = CGRect(x: min(anchor.maxX + 3, safe.maxX - width),
            y: max(safe.minY, min(anchor.minY, safe.maxY - height)), width: width, height: height)
        let save = UIButton(type: .custom)
        save.setImage(UIImage(systemName: "square.and.arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)), for: .normal)
        save.tintColor = .white
        save.frame = CGRect(x: 4, y: 2, width: 28, height: 26)
        save.accessibilityLabel = L10n.text("存入当前颜色")
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        panel.addSubview(save)
        saveButton = save
        let divider = UIView(frame: CGRect(x: 4, y: 29, width: 128, height: 1))
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        panel.addSubview(divider)
        cells = (0..<16).map { index in
            let cell = UIButton(type: .custom)
            cell.tag = index
            cell.frame = CGRect(x: 4 + (index % 4) * 32, y: 33 + (index / 4) * 32, width: 28, height: 28)
            cell.accessibilityLabel = L10n.format("预设颜色 %@", "\(index + 1)")
            cell.addTarget(self, action: #selector(cellTapped(_:)), for: .touchUpInside)
            panel.addSubview(cell)
            return cell
        }
        self.panel = panel
        window.addSubview(panel)
        popupWindow = window
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTapped))
        outside.cancelsTouchesInView = false
        outside.delegate = self
        window.addGestureRecognizer(outside)
        outsideTap = outside
        refreshCells()
    }
    private func updateHover(_ touch: UITouch) {
        guard let panel else { return }
        let point = touch.location(in: panel)
        hovered = saveButton?.frame.contains(point) == true ? -1 : cells.first(where: { $0.frame.contains(point) })?.tag
        refreshCells()
    }
    private func refreshCells() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for cell in cells {
            if presets.indices.contains(cell.tag) { cell.backgroundColor = presets[cell.tag].uiColor }
            cell.layer.borderWidth = hovered == cell.tag ? 2 : 1
            cell.layer.borderColor = (hovered == cell.tag ? UIColor.systemBlue : UIColor.white.withAlphaComponent(0.35)).cgColor
            cell.accessibilityHint = storing ? L10n.text("点击将当前颜色存入此格") : L10n.text("点击使用此颜色")
        }
        saveButton?.backgroundColor = storing || hovered == -1 ? UIColor.systemBlue.withAlphaComponent(0.35) : .clear
        saveButton?.accessibilityValue = storing ? L10n.text("选择色格存入") : L10n.text("未启用")
    }
    private func activate(_ index: Int) {
        if index == -1 {
            storing = true
            hovered = nil
            refreshCells()
        } else if storing {
            storeAction?(index)
            storing = false
            hovered = nil
            refreshCells()
        } else {
            chooseAction?(index)
            close()
        }
    }
    @objc private func saveTapped() { activate(-1) }
    @objc private func cellTapped(_ sender: UIButton) { activate(sender.tag) }
    @objc private func outsideTapped() { close() }
    @objc private func accessibilityOpen() -> Bool { open(); return true }
    override func accessibilityActivate() -> Bool { tapAction?(); return true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let panel else { return false }
        return !panel.bounds.contains(touch.location(in: panel)) && !bounds.contains(touch.location(in: self))
    }
    func close() {
        if let outsideTap { popupWindow?.removeGestureRecognizer(outsideTap) }
        outsideTap = nil; popupWindow = nil
        panel?.removeFromSuperview(); panel = nil
        cells = []; saveButton = nil
        hovered = nil; storing = false
    }
}

extension AppColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}
