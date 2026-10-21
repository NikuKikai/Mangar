import SwiftUI
import UIKit

enum ModifierPanelMetrics {
    static let buttonSize: CGFloat = 52
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    static let indicatorHeight: CGFloat = 36
    static let indicatorGap: CGFloat = 8
    static var size: CGFloat { buttonSize * 2 + spacing + padding * 2 }
}

private enum ModifierPanelStyle {
    static let background = UIColor(red: 0.15, green: 0.16, blue: 0.17, alpha: 1)
    static let buttonBackground = UIColor(red: 0.18, green: 0.19, blue: 0.20, alpha: 1)
    static let border = UIColor.black.withAlphaComponent(0.45)
    static let borderWidth: CGFloat = 1
}

/// A non-interactive indicator above the panel remains visible past the fingers.
struct ModifierKeysIndicator: View {
    let active: Set<EditorModifier>
    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorModifier.allCases.filter { active.contains($0) }, id: \.self) { modifier in
                Text(verbatim: modifier.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 28)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: ModifierPanelMetrics.indicatorHeight)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.6))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .immediateUI()
    }
}

/// Native controls allow holding two modifiers while Pencil input continues on
/// the canvas. The panel itself receives touches in the gaps between buttons.
struct ModifierKeysPanel: UIViewRepresentable {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    let active: Set<EditorModifier>
    let setPressed: (EditorModifier, Bool) -> Void

    func makeUIView(context: Context) -> ModifierKeysPanelView { ModifierKeysPanelView() }
    func updateUIView(_ view: ModifierKeysPanelView, context: Context) {
        let _ = language
        view.configure(active: active, enabled: context.environment.isEnabled, setPressed: setPressed)
    }
    static func dismantleUIView(_ view: ModifierKeysPanelView, coordinator: ()) { view.releaseHeldKeys() }
}

final class ModifierKeysPanelView: UIView {
    private var keys: [ModifierHoldButton] = []
    private var holds = ModifierKeyHoldState()
    private var setPressed: ((EditorModifier, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ModifierPanelStyle.background
        layer.cornerRadius = ModifierPanelMetrics.cornerRadius
        layer.maskedCorners = [.layerMaxXMinYCorner]
        layer.masksToBounds = true
        layer.borderColor = ModifierPanelStyle.border.cgColor
        layer.borderWidth = ModifierPanelStyle.borderWidth
        isMultipleTouchEnabled = true
        keys = ModifierPanelKey.allCases.map { key in
            let button = ModifierHoldButton(key)
            button.isExclusiveTouch = false
            button.addTarget(self, action: #selector(press(_:)), for: [.touchDown, .touchDragEnter])
            button.addTarget(self, action: #selector(release(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            addSubview(button)
            return button
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, button) in keys.enumerated() {
            let step = ModifierPanelMetrics.buttonSize + ModifierPanelMetrics.spacing
            button.frame = CGRect(x: ModifierPanelMetrics.padding + CGFloat(index % 2) * step,
                                  y: ModifierPanelMetrics.padding + CGFloat(index / 2) * step,
                                  width: ModifierPanelMetrics.buttonSize, height: ModifierPanelMetrics.buttonSize)
            button.layer.cornerRadius = ModifierPanelMetrics.buttonSize / 2
        }
    }
    func configure(active: Set<EditorModifier>, enabled: Bool, setPressed: @escaping (EditorModifier, Bool) -> Void) {
        self.setPressed = setPressed
        if !enabled { releaseHeldKeys() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for button in keys {
            let pressed = button.key.modifiers.isSubset(of: active)
            button.isEnabled = enabled
            button.backgroundColor = pressed ? UIColor.systemBlue.withAlphaComponent(0.7) : ModifierPanelStyle.buttonBackground
            button.accessibilityLabel = button.key.name
            button.accessibilityHint = L10n.format("按住 %@，松开即释放", button.key.name)
            button.accessibilityTraits = pressed ? [.button, .selected] : [.button]
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { releaseHeldKeys() }
    }
    func releaseHeldKeys() {
        for modifier in holds.releaseAll() { setPressed?(modifier, false) }
    }
    @objc private func press(_ button: ModifierHoldButton) { updateHold(button.key, pressed: true) }
    @objc private func release(_ button: ModifierHoldButton) { updateHold(button.key, pressed: false) }
    private func updateHold(_ key: ModifierPanelKey, pressed: Bool) {
        let changes = holds.set(key, pressed: pressed)
        for modifier in changes.pressed { setPressed?(modifier, true) }
        for modifier in changes.released { setPressed?(modifier, false) }
    }
}

private final class ModifierHoldButton: ImmediateFeedbackButton {
    let key: ModifierPanelKey
    init(_ key: ModifierPanelKey) {
        self.key = key
        super.init(frame: .zero)
        setTitle(key.symbol, for: .normal)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: key.components.count > 1 ? 19 : 23, weight: .medium)
        layer.borderWidth = ModifierPanelStyle.borderWidth
        layer.borderColor = ModifierPanelStyle.border.cgColor
        layer.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
