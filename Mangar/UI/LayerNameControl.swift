import SwiftUI
import UIKit

/// Inline naming and a window-level menu, so rows near the list edge are not clipped.
struct LayerNameControl: UIViewRepresentable {
    let name: String
    let primary: Bool
    let rename: (String) -> Void

    func makeUIView(context: Context) -> LayerNameView { LayerNameView() }
    func updateUIView(_ view: LayerNameView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.configure(name: name, primary: primary, rename: rename)
    }
    static func dismantleUIView(_ view: LayerNameView, coordinator: ()) { view.finish(commit: false) }
}

final class LayerNameView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private let title = UILabel()
    private let field = UITextField()
    private let presets = ["草稿", "线稿", "底色", "阴影", "高光", "网点", "背景", "文件夹"]
    private let rowHeight: CGFloat = 24
    private var name = ""
    private var onRename: ((String) -> Void)?
    private var editing = false
    private var scrubbing = false
    private var selectedIndex: Int?
    private var menu: UIView?
    private var buttons: [UIButton] = []
    private var outsideTap: UITapGestureRecognizer?
    private weak var menuWindow: UIWindow?
    private var keyboardFrame = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .white
        addSubview(title)
        field.isHidden = true
        field.delegate = self
        field.textColor = .white
        field.backgroundColor = UIColor(white: 0.12, alpha: 1)
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.systemBlue.cgColor
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        addSubview(field)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(startEditing))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated),
            name: UIApplication.willResignActiveNotification, object: nil)
        isAccessibilityElement = true
        accessibilityHint = "双击编辑名称，或上下拖动选择预设名称"
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = bounds
        field.frame = bounds
        positionMenu()
    }
    func configure(name: String, primary: Bool, rename: @escaping (String) -> Void) {
        self.name = name
        title.text = name
        let font = UIFont.systemFont(ofSize: 11, weight: primary ? .semibold : .regular)
        title.font = font; field.font = font
        onRename = rename
        accessibilityLabel = name
    }
    @objc private func startEditing() {
        guard !editing else { return }
        editing = true
        title.isHidden = true; field.isHidden = false
        field.text = name
        isAccessibilityElement = false
        showMenu()
        field.becomeFirstResponder()
        field.selectAll(nil)
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            scrubbing = true
            showMenu()
            updateChoice(gesture)
        case .changed: updateChoice(gesture)
        case .ended:
            updateChoice(gesture)
            let choice = selectedIndex.map { presets[$0] }
            finish(commit: false)
            if let choice { onRename?(choice) }
        case .cancelled, .failed: finish(commit: false)
        default: break
        }
    }
    private func updateChoice(_ gesture: UIPanGestureRecognizer) {
        guard let menu else { return }
        let y = gesture.location(in: menu).y
        selectedIndex = min(presets.count - 1, max(0, Int(floor(y / rowHeight))))
        highlight()
    }
    private func showMenu() {
        guard menu == nil, let window else { return }
        let popup = UIView()
        popup.backgroundColor = UIColor(red: 0.17, green: 0.18, blue: 0.19, alpha: 1)
        popup.layer.borderWidth = 1
        popup.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        popup.layer.shadowOpacity = 0.4
        popup.layer.shadowRadius = 5
        popup.layer.shadowOffset = CGSize(width: 0, height: 2)
        buttons = presets.enumerated().map { index, text in
            let button = UIButton(type: .custom)
            button.setTitle(text, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 11)
            button.contentHorizontalAlignment = .leading
            button.setTitle("  " + text, for: .normal)
            button.tag = index
            button.addTarget(self, action: #selector(chose(_:)), for: .touchUpInside)
            popup.addSubview(button)
            return button
        }
        selectedIndex = presets.firstIndex(of: name)
        menu = popup; menuWindow = window
        window.addSubview(popup)
        positionMenu(); highlight()
        let outside = UITapGestureRecognizer(target: self, action: #selector(clickedOutside))
        outside.cancelsTouchesInView = false
        outside.delegate = self
        window.addGestureRecognizer(outside)
        outsideTap = outside
    }
    private func positionMenu() {
        guard let menu, let window = menuWindow else { return }
        let anchor = convert(bounds, to: window)
        let width: CGFloat = max(112, bounds.width)
        let height = rowHeight * CGFloat(presets.count)
        let top = window.safeAreaInsets.top + 4
        var bottom = window.bounds.maxY - window.safeAreaInsets.bottom - 4
        if !keyboardFrame.isEmpty {
            let keyboard = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            if keyboard.intersects(CGRect(x: anchor.minX, y: 0, width: width, height: bottom)) {
                bottom = min(bottom, keyboard.minY - 4)
            }
        }
        let below = anchor.maxY + 3
        let y = below + height <= bottom ? below : max(top, min(bottom - height, anchor.minY - height - 3))
        menu.frame = CGRect(x: max(4, min(window.bounds.maxX - width - 4, anchor.minX)),
                            y: y, width: width, height: height)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 1, y: CGFloat(index) * rowHeight, width: width - 2, height: rowHeight)
        }
    }
    private func highlight() {
        for (index, button) in buttons.enumerated() {
            button.backgroundColor = index == selectedIndex ? UIColor.systemBlue.withAlphaComponent(0.45) : .clear
        }
    }
    @objc private func chose(_ button: UIButton) {
        let choice = presets[button.tag]
        finish(commit: false)
        onRename?(choice)
    }
    @objc private func clickedOutside() { finish(commit: true) }
    @objc private func deactivated() { finish(commit: true) }
    @objc private func keyboardChanged(_ notification: Notification) {
        keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        positionMenu()
    }
    func finish(commit: Bool) {
        let draft = editing ? field.text : nil
        editing = false; scrubbing = false; selectedIndex = nil
        menu?.removeFromSuperview(); menu = nil; buttons = []
        if let outsideTap { menuWindow?.removeGestureRecognizer(outsideTap) }
        outsideTap = nil; menuWindow = nil
        field.resignFirstResponder()
        field.isHidden = true; title.isHidden = false
        isAccessibilityElement = true
        if commit, let draft { onRename?(draft) }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { finish(commit: true); return true }
    func textFieldDidEndEditing(_ textField: UITextField) { if editing { finish(commit: true) } }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "取消重命名", action: #selector(cancelEditing), input: UIKeyCommand.inputEscape)]
    }
    @objc private func cancelEditing() { finish(commit: false) }
    override func accessibilityActivate() -> Bool { startEditing(); return true }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard !editing else { return false }
        let v = pan.velocity(in: self)
        return abs(v.y) >= abs(v.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === outsideTap {
            guard let target = touch.view else { return true }
            return !target.isDescendant(of: self) && !(menu.map { target.isDescendant(of: $0) } ?? false)
        }
        return !editing
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
}
