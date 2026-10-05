import SwiftUI
import UIKit

struct ContentView: View {
    @State private var session: EditorSession?
    @State private var launchError: String?

    var body: some View {
        Group {
            if let session {
                EditorWorkspace(session: session)
            } else {
                ContentUnavailableView("无法打开画布", systemImage: "exclamationmark.triangle",
                                       description: Text(launchError ?? "正在加载工程…"))
            }
        }
        .task {
            guard session == nil, launchError == nil else { return }
            do { session = try EditorSession() }
            catch { launchError = error.localizedDescription }
        }
    }
}

private struct EditorWorkspace: View {
    @ObservedObject var session: EditorSession
    @State private var showBrushSettings = false
    @State private var showColorEditor = false
    @State private var collapsedFolders: Set<UUID> = []
    @State private var layerRowFrames: [UUID: CGRect] = [:]
    @State private var draggingLayerID: UUID?
    @State private var layerDropTarget: LayerDragTarget?

    var body: some View {
        HStack(spacing: 0) {
            toolRail
                .frame(width: 40)
                .background(Color(red: 0.15, green: 0.16, blue: 0.17))
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                CanvasSurfaceRepresentable(session: session)
            }
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
            sidebar
                .frame(width: 192)
                .background(Color(red: 0.15, green: 0.16, blue: 0.17))
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            FloatingPanelOverlay(brush: $session.brush,
                                 showsColor: showColorEditor,
                                 showsBrush: showBrushSettings,
                                 closeColor: { showColorEditor = false },
                                 closeBrush: { showBrushSettings = false })
        }
        .preferredColorScheme(.dark)
        .controlSize(.mini)
        .alert("Mangar", isPresented: Binding(
            get: { session.message != nil },
            set: { if !$0 { session.message = nil } })) {
                Button("确定", role: .cancel) { session.message = nil }
            } message: {
                Text(session.message ?? "")
            }
        .sheet(isPresented: Binding(
            get: { session.exportURL != nil },
            set: { if !$0 { session.exportURL = nil } })) {
                if let url = session.exportURL {
                    ActivitySheet(items: [url])
                }
            }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            session.releaseModifiers()
            session.saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            session.releaseModifiers()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if session.selectedTool == .selection {
                Image(systemName: "rectangle.dashed")
                Text("矩形选区")
                Text("⇧追加  ⌥减去  ⇧⌥相交")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("全选") { session.changeSelection(.selectAll) }
                    .keyboardShortcut("a", modifiers: [.command])
                Button("反选") { session.changeSelection(.invert) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("取消") { session.changeSelection(.clear) }
                    .keyboardShortcut("d", modifiers: [.command])
            } else {
                Image(systemName: session.selectedTool == .eraser ? "eraser.fill" : "pencil.tip")
                Text(session.selectedTool == .eraser ? "橡皮擦" : "圆笔")
                FlatSlider(value: $session.brush.size, range: 1...100)
                    .frame(width: 105)
                Text("\(Int(session.brush.size)) px")
                    .monospacedDigit()
                    .frame(width: 48)
                Button {
                    showBrushSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 24)
                }
            }
            Spacer()
            Button { session.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 24)
            }
                .disabled(!session.canUndo)
            Button { session.redo() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 22, height: 24)
            }
                .disabled(!session.canRedo)
            Button { session.exportPNG() } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 22, height: 24)
            }
            .help("导出当前页 PNG")
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(Color(red: 0.18, green: 0.19, blue: 0.20))
    }

    private var toolRail: some View {
        VStack(spacing: 2) {
            toolButton(.brush, icon: "pencil.tip", name: "圆笔")
                .keyboardShortcut("b", modifiers: [])
            toolButton(.eraser, icon: "eraser.fill", name: "橡皮擦")
                .keyboardShortcut("e", modifiers: [])
            toolButton(.selection, icon: "rectangle.dashed", name: "矩形选区")
                .keyboardShortcut("m", modifiers: [])
            Spacer(minLength: 12)
            Button {
                showColorEditor.toggle()
            } label: {
                Rectangle()
                    .fill(Color(red: session.brush.red, green: session.brush.green,
                                blue: session.brush.blue))
                    .frame(width: 25, height: 25)
                    .overlay(Rectangle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("当前颜色；点按以更改")
            Rectangle().fill(Color.gray.opacity(0.5))
                .frame(width: 28, height: 1)
                .padding(.vertical, 3)
            ForEach(EditorModifier.allCases, id: \.self) { modifier in
                ModifierKeyButton(modifier: modifier,
                                  isPressed: session.activeModifiers.contains(modifier)) { pressed in
                    session.setModifier(modifier, pressed: pressed)
                }
                .frame(width: 34, height: 34)
                .help("按住 \(modifier.name)，松开即释放")
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func toolButton(_ tool: DrawingTool, icon: String, name: String) -> some View {
        Button {
            session.selectedTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .background(session.selectedTool == tool
                            ? Color.gray.opacity(0.4) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.manifest.name)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(height: 34, alignment: .leading)
            HStack {
                Text("页面")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { session.addPage() } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 27)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(session.manifest.pageIDs.enumerated()), id: \.element) { index, id in
                        Button("\(index + 1)") { session.selectPage(id) }
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 25, height: 22)
                            .background(id == session.page.id ? Color.gray.opacity(0.45) : .clear)
                    }
                }
                .padding(.horizontal, 3)
            }
            .frame(height: 25)
            Divider()
            layerControls
            layerList
        }
        .buttonStyle(.plain)
    }

    private var layerControls: some View {
        VStack(spacing: 0) {
            HStack {
                Text("图层")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.leading, 2)
            .frame(height: 22)
            HStack(spacing: 0) {
                Button { session.addLayer() } label: {
                    Image(systemName: "plus.square").frame(width: 23, height: 23)
                }
                    .help("新建绘画图层")
                    .accessibilityLabel("新建绘画图层")
                Button { session.addFolder() } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 23, height: 23)
                }
                    .help("新建图层文件夹")
                    .accessibilityLabel("新建图层文件夹")
                Button { session.toggleSelectedLock() } label: {
                    Image(systemName: session.selectedLockActionWillLock ? "lock.fill" : "lock.open")
                        .frame(width: 23, height: 23)
                }
                .disabled(session.selectedLayerID == nil)
                .help(session.selectedLockActionWillLock ? "锁定所选图层" : "解锁所选图层")
                .accessibilityLabel(session.selectedLockActionWillLock ? "锁定所选图层" : "解锁所选图层")
                Spacer(minLength: 0)
                Button(role: .destructive) { session.deleteSelectedLayer() } label: {
                    Image(systemName: "trash").frame(width: 23, height: 23)
                }
                .disabled(!session.canDeleteSelection)
                .help("删除所选图层或文件夹")
                .accessibilityLabel("删除所选图层或文件夹")
            }
            .font(.system(size: 13))
            .buttonStyle(.plain)
            .frame(height: 24)
        }
    }

    private var visibleLayerEntries: [LayerDisplayEntry] {
        session.page.layerDisplayEntries.filter { entry in
            !collapsedFolders.contains { session.page.isDescendant(entry.id, of: $0) }
        }
    }

    private var layerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleLayerEntries) { entry in
                    layerRow(entry)
                }
            }
            .padding(1)
        }
        .coordinateSpace(name: "layerList")
        .onPreferenceChange(LayerRowFrameKey.self) { layerRowFrames = $0 }
        .background(Color(red: 0.105, green: 0.11, blue: 0.12))
        .overlay(Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        .padding(.horizontal, 3)
        .padding(.bottom, 3)
    }

    private func layerRow(_ entry: LayerDisplayEntry) -> some View {
        let layer = entry.layer
        return HStack(spacing: 0) {
            Button { session.toggleVisibility(layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(session.page.isEffectivelyVisible(layer.id)
                                     ? Color.primary : Color.gray.opacity(0.55))
                    .frame(width: 25, height: 31)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isVisible ? "隐藏图层" : "显示图层")
            HStack(spacing: 4) {
                if layer.kind == .folder {
                    Button {
                        if !collapsedFolders.insert(layer.id).inserted {
                            collapsedFolders.remove(layer.id)
                        }
                    } label: {
                        Image(systemName: collapsedFolders.contains(layer.id) ? "chevron.right" : "chevron.down")
                            .frame(width: 10, height: 31)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsedFolders.contains(layer.id) ? "展开文件夹" : "折叠文件夹")
                }
                HStack(spacing: 4) {
                    if layer.kind == .folder {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.gray)
                            .frame(width: 24)
                    } else {
                        layerThumbnail(layer)
                    }
                    Text(layer.name)
                        .fontWeight(layer.id == session.selectedLayerID ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    LayerRowTapCapture { modifiers in
                        session.selectLayer(layer.id,
                                            shift: session.activeModifiers.contains(.shift) || modifiers.contains(.shift),
                                            command: session.activeModifiers.contains(.command) || modifiers.contains(.command))
                    }
                }
                if layer.isLocked {
                    Button { session.toggleLock(layer.id) } label: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 19, height: 31)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("解锁图层")
                }
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(session.page.isEffectivelyLocked(layer.id) ? 0.35 : 1)
                    .frame(width: 19, height: 31)
                    .contentShape(Rectangle())
                    .highPriorityGesture(layerHandleDrag(layer.id))
                    .accessibilityLabel("拖动图层")
            }
            .padding(.leading, CGFloat(2 + entry.depth * 10))
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 11))
        .frame(height: 31)
        .frame(maxWidth: .infinity)
        .background(layerDropTarget == LayerDragTarget(id: layer.id, placement: .inside)
                    ? Color.accentColor.opacity(0.3) :
                    layer.id == session.selectedLayerID ? Color.accentColor.opacity(0.33) :
                    session.selectedLayerIDs.contains(layer.id) ? Color.gray.opacity(0.30) : .clear)
        .overlay(alignment: .leading) {
            if layer.id == session.selectedLayerID {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            if layerDropTarget == LayerDragTarget(id: layer.id, placement: .above) {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if layerDropTarget == LayerDragTarget(id: layer.id, placement: .below) {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .opacity(draggingLayerID == layer.id ? 0.65 : 1)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: LayerRowFrameKey.self,
                                       value: [layer.id: proxy.frame(in: .named("layerList"))])
            }
        }
    }

    private func layerThumbnail(_ layer: LayerRecord) -> some View {
        ZStack {
            ThumbnailChecker()
            if layer.kind == .solidWhite {
                Rectangle().fill(.white)
            } else if let image = session.renderer.thumbnail(for: layer.id) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        }
        .frame(width: 24, height: 24)
        .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private func layerHandleDrag(_ sourceID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("layerList"))
            .onChanged { gesture in
                guard !session.page.isEffectivelyLocked(sourceID) else { return }
                draggingLayerID = sourceID
                layerDropTarget = dropTarget(at: gesture.location, moving: sourceID)
            }
            .onEnded { gesture in
                let target = session.page.isEffectivelyLocked(sourceID)
                    ? nil : dropTarget(at: gesture.location, moving: sourceID)
                draggingLayerID = nil
                layerDropTarget = nil
                if let target {
                    session.moveLayer(sourceID, relativeTo: target.id, placement: target.placement)
                }
            }
    }

    private func dropTarget(at point: CGPoint, moving sourceID: UUID) -> LayerDragTarget? {
        let moving = session.selectedLayerIDs.contains(sourceID) ? session.selectedLayerIDs : [sourceID]
        guard let match = layerRowFrames.first(where: { $0.key != sourceID && $0.value.contains(point) }),
              let target = session.page.layers.first(where: { $0.id == match.key }),
              !moving.contains(where: { $0 == target.id || session.page.isDescendant(target.id, of: $0) }) else { return nil }
        let fraction = (point.y - match.value.minY) / match.value.height
        let placement: LayerDropPlacement
        if target.kind == .folder && fraction >= 0.25 && fraction <= 0.75 {
            placement = .inside
        } else {
            placement = fraction < 0.5 ? .above : .below
        }
        let destinationParent = placement == .inside ? target.id : target.parentID
        if let destinationParent, session.page.isEffectivelyLocked(destinationParent) { return nil }
        return LayerDragTarget(id: match.key, placement: placement)
    }
}

private struct LayerDragTarget: Equatable {
    let id: UUID
    let placement: LayerDropPlacement
}

private struct LayerRowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class ModifierTapRecognizer: UITapGestureRecognizer {
    var capturedModifiers: UIKeyModifierFlags = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        capturedModifiers = event.modifierFlags
        super.touchesBegan(touches, with: event)
    }
}

private struct LayerRowTapCapture: UIViewRepresentable {
    let onTap: (UIKeyModifierFlags) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = ModifierTapRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.tapped(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (UIKeyModifierFlags) -> Void
        init(onTap: @escaping (UIKeyModifierFlags) -> Void) { self.onTap = onTap }
        @objc func tapped(_ recognizer: ModifierTapRecognizer) {
            onTap(recognizer.capturedModifiers)
        }
    }
}

private struct ThumbnailChecker: View {
    var body: some View {
        Canvas(opaque: true) { context, size in
            let cell: CGFloat = 4
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) {
                    let color = (row + column).isMultiple(of: 2)
                        ? Color(red: 0.78, green: 0.78, blue: 0.78)
                        : Color(red: 0.94, green: 0.94, blue: 0.94)
                    context.fill(Path(CGRect(x: CGFloat(column) * cell,
                                             y: CGFloat(row) * cell,
                                             width: cell, height: cell)), with: .color(color))
                }
            }
        }
    }
}

/// Only the visible panel frames participate in hit testing. The rest of this
/// full-size overlay returns nil so Pencil and finger touches reach the canvas.
private final class FloatingPanelContainer: UIView {
    var colorHost: UIHostingController<AnyView>?
    var brushHost: UIHostingController<AnyView>?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let brushHost {
            let size = brushHost.sizeThatFits(in: bounds.size)
            brushHost.view.frame = CGRect(origin: CGPoint(x: 146, y: 44), size: size)
        }
        if let colorHost {
            let size = colorHost.sizeThatFits(in: bounds.size)
            colorHost.view.frame = CGRect(origin: CGPoint(x: 54,
                y: bounds.height - 188 - size.height), size: size)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        panelViews.contains { $0.frame.contains(point) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for panel in panelViews.reversed() where panel.frame.contains(point) {
            return panel.hitTest(convert(point, to: panel), with: event) ?? panel
        }
        return nil
    }

    private var panelViews: [UIView] {
        [colorHost?.view, brushHost?.view].compactMap { $0 }
    }
}

private struct FloatingPanelOverlay: UIViewRepresentable {
    @Binding var brush: RoundBrush
    let showsColor: Bool
    let showsBrush: Bool
    let closeColor: () -> Void
    let closeBrush: () -> Void

    func makeUIView(context: Context) -> FloatingPanelContainer {
        let view = FloatingPanelContainer()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: FloatingPanelContainer, context: Context) {
        if showsColor {
            let panel = AnyView(ColorEditorPanel(brush: $brush, close: closeColor))
            if let host = view.colorHost {
                host.rootView = panel
            } else {
                let host = UIHostingController(rootView: panel)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                view.colorHost = host
            }
        } else {
            view.colorHost?.view.removeFromSuperview()
            view.colorHost = nil
        }

        if showsBrush {
            let panel = AnyView(BrushSettings(brush: $brush, close: closeBrush))
            if let host = view.brushHost {
                host.rootView = panel
            } else {
                let host = UIHostingController(rootView: panel)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                view.brushHost = host
            }
        } else {
            view.brushHost?.view.removeFromSuperview()
            view.brushHost = nil
        }
        view.setNeedsLayout()
    }
}

private struct ModifierKeyButton: UIViewRepresentable {
    let modifier: EditorModifier
    let isPressed: Bool
    let onPressChange: (Bool) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.setTitle(modifier.symbol, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 19, weight: .medium)
        button.layer.cornerRadius = 3
        button.accessibilityLabel = modifier.name
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressKey), for: [.touchDown, .touchDragEnter])
        button.addTarget(context.coordinator, action: #selector(Coordinator.releaseKey),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onPressChange = onPressChange
        button.backgroundColor = isPressed ? UIColor.systemBlue.withAlphaComponent(0.7) : .clear
        button.setTitleColor(.white, for: .normal)
        button.accessibilityTraits = isPressed ? [.button, .selected] : [.button]
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPressChange: onPressChange) }

    final class Coordinator: NSObject {
        var onPressChange: (Bool) -> Void
        init(onPressChange: @escaping (Bool) -> Void) { self.onPressChange = onPressChange }
        @objc func pressKey() { onPressChange(true) }
        @objc func releaseKey() { onPressChange(false) }
    }
}

private struct ColorEditorPanel: View {
    @Binding var brush: RoundBrush
    let close: () -> Void
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(brush: Binding<RoundBrush>, close: @escaping () -> Void) {
        self._brush = brush
        self.close = close
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(red: brush.wrappedValue.red, green: brush.wrappedValue.green,
                blue: brush.wrappedValue.blue, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        _hue = State(initialValue: Double(h))
        _saturation = State(initialValue: Double(s))
        _brightness = State(initialValue: Double(b))
    }

    private var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("颜色").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "#%02X%02X%02X",
                            Int((brush.red * 255).rounded()),
                            Int((brush.green * 255).rounded()),
                            Int((brush.blue * 255).rounded())))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭颜色面板")
            }
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(LinearGradient(colors: [.white, .clear],
                                            startPoint: .leading, endPoint: .trailing))
                    .overlay(LinearGradient(colors: [.clear, .black],
                                            startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .background(Circle().strokeBorder(.black, lineWidth: 1))
                            .frame(width: 14, height: 14)
                            .position(x: saturation * geometry.size.width,
                                      y: (1 - brightness) * geometry.size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        saturation = min(1, max(0, gesture.location.x / geometry.size.width))
                        brightness = 1 - min(1, max(0, gesture.location.y / geometry.size.height))
                        applyColor()
                    })
            }
            .frame(height: 144)
            Text("色相").font(.system(size: 10)).foregroundStyle(.secondary)
            ramp(value: hue,
                 gradient: LinearGradient(colors: (0...6).map {
                    Color(hue: Double($0) / 6, saturation: 1, brightness: 1)
                 }, startPoint: .leading, endPoint: .trailing)) { value in
                hue = value
                applyColor()
            }
            HStack {
                Text("不透明度").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((brush.opacity * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
            }
            ramp(value: brush.opacity,
                 gradient: LinearGradient(colors: [color.opacity(0), color],
                                          startPoint: .leading, endPoint: .trailing),
                 showsChecker: true) { value in
                brush.opacity = value
            }
        }
        .padding(12)
        .frame(width: 244)
        .controlSize(.mini)
        .background(Color(red: 0.17, green: 0.18, blue: 0.19))
        .overlay(Rectangle().stroke(Color.gray.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 8, x: 2, y: 4)
    }

    private func ramp(value: Double, gradient: LinearGradient,
                      showsChecker: Bool = false,
                      onChange: @escaping (Double) -> Void) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(showsChecker ? Color.gray : Color.clear)
                .overlay(gradient)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .shadow(color: .black, radius: 1)
                        .offset(x: min(geometry.size.width - 2, max(0, value * geometry.size.width)))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    onChange(min(1, max(0, gesture.location.x / geometry.size.width)))
                })
        }
        .frame(height: 17)
        .overlay(Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 1))
    }

    private func applyColor() {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        brush.red = Double(red)
        brush.green = Double(green)
        brush.blue = Double(blue)
    }
}

private struct BrushSettings: View {
    @Binding var brush: RoundBrush
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("圆笔参数").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭画笔参数")
            }
            .frame(height: 22)
            row("不透明度", value: $brush.opacity, range: 0...1)
            row("间距", value: $brush.spacing, range: 0.05...1)
            row("大小抖动", value: $brush.sizeJitter, range: 0...1)
            row("透明度抖动", value: $brush.opacityJitter, range: 0...1)
            row("位置抖动", value: $brush.positionJitter, range: 0...1)
            Button {
                brush.buildsOpacity.toggle()
            } label: {
                HStack {
                    Text("重叠加深")
                    Spacer()
                    Image(systemName: brush.buildsOpacity ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                }
                .font(.system(size: 10))
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("同一笔画中，重复经过同一区域时是否逐渐加深")
        }
        .padding(8)
        .frame(width: 236)
        .controlSize(.mini)
        .background(Color(red: 0.17, green: 0.18, blue: 0.19))
        .overlay(Rectangle().stroke(Color.gray.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 8, x: 2, y: 4)
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .frame(width: 68, alignment: .leading)
            FlatSlider(value: value, range: range)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

private struct FlatSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(red: 0.09, green: 0.10, blue: 0.11))
                    .frame(height: 8)
                Rectangle()
                    .fill(Color(red: 0.39, green: 0.58, blue: 0.77))
                    .frame(width: width * fraction, height: 8)
                Rectangle()
                    .fill(.white)
                    .frame(width: 3, height: 16)
                    .offset(x: min(width - 3, max(0, width * fraction - 1.5)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let fraction = min(1, max(0, gesture.location.x / width))
                value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
