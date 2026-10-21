import SwiftUI
import UIKit

struct MangarLogoMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            var solid = Path()
            solid.move(to: CGPoint(x: 8, y: 92))
            solid.addLine(to: CGPoint(x: 8, y: 43))
            solid.addCurve(to: CGPoint(x: 70, y: 43),
                           control1: CGPoint(x: 8, y: -5), control2: CGPoint(x: 70, y: -5))
            solid.addLine(to: CGPoint(x: 70, y: 92))
            solid.addLine(to: CGPoint(x: 58, y: 92))
            solid.addLine(to: CGPoint(x: 58, y: 43))
            solid.addCurve(to: CGPoint(x: 20, y: 43),
                           control1: CGPoint(x: 58, y: 12), control2: CGPoint(x: 20, y: 12))
            solid.addLine(to: CGPoint(x: 20, y: 92))
            solid.closeSubpath()
            context.fill(solid.applying(CGAffineTransform(scaleX: scale, y: scale)), with: .color(.white))

            var outline = Path()
            outline.move(to: CGPoint(x: 39, y: 92))
            outline.addLine(to: CGPoint(x: 39, y: 44))
            outline.addCurve(to: CGPoint(x: 94, y: 44),
                             control1: CGPoint(x: 39, y: 2), control2: CGPoint(x: 94, y: 2))
            outline.addLine(to: CGPoint(x: 94, y: 92))
            outline.addLine(to: CGPoint(x: 82, y: 92))
            outline.addLine(to: CGPoint(x: 82, y: 44))
            outline.addCurve(to: CGPoint(x: 51, y: 44),
                             control1: CGPoint(x: 82, y: 19), control2: CGPoint(x: 51, y: 19))
            outline.addLine(to: CGPoint(x: 51, y: 92))
            outline.closeSubpath()
            context.stroke(outline.applying(CGAffineTransform(scaleX: scale, y: scale)),
                           with: .color(.white), lineWidth: max(0.7, scale * 2.5))
        }
        .accessibilityHidden(true)
    }
}

private struct ExportSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    @ObservedObject var session: EditorSession
    let close: () -> Void
    @State private var cropToContent = true
    @State private var preview: UIImage?

    private var outputSize: CGSize {
        session.renderer.outputBounds(cropToContent:cropToContent).size
    }

    private var shownPreview: UIImage? {
        guard session.page.comicLayout != nil, let preview, cropToContent, let source = preview.cgImage else { return preview }
        let rect = session.page.contentRect
        let sx = CGFloat(source.width) / CGFloat(session.page.width)
        let sy = CGFloat(source.height) / CGFloat(session.page.height)
        let crop = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                          width: rect.width * sx, height: rect.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let image = source.cropping(to: crop) else { return preview }
        return UIImage(cgImage: image)
    }

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("导出 PNG"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 30, height: 30)
                }
                .help(L10n.text("关闭导出画面"))
                .accessibilityLabel(L10n.text("关闭导出画面"))
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
            HStack(spacing: 22) {
                ZStack {
                    Color(red: 0.21, green: 0.22, blue: 0.23)
                    if let image = shownPreview {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(18)
                    } else {
                        Text(L10n.text("处理中…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 1))
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("当前页 · PNG"))
                        .font(.system(size: 14, weight: .semibold))
                    if session.page.comicLayout != nil {
                    Button { cropToContent.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: cropToContent ? "checkmark.square.fill" : "square")
                                .foregroundStyle(cropToContent ? Color.accentColor : .secondary)
                            Text(L10n.text("裁切至内容框"))
                        }
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    }
                    }
                    Text(L10n.format("输出：%@ × %@ px", "\(Int(outputSize.width))", "\(Int(outputSize.height))"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let layout = session.page.comicLayout {
                        Text(L10n.format("内容尺寸：%@ × %@ mm · %@ dpi", "\(layout.totalContentWidthMM.formatted())", "\(layout.contentHeightMM.formatted())", "\(layout.dpi)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.text("辅助框线不会出现在导出的图片中。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        session.exportPNG(cropToContent: cropToContent)
                        close()
                    } label: {
                        Text(L10n.text("导出 PNG"))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(Color.accentColor)
                    }
                }
                .frame(width: 255, alignment: .leading)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .buttonStyle(ImmediateButtonStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            preview = (try? session.renderer.projectThumbnailPNG()).flatMap(UIImage.init(data:))
        }
    }
}

struct ContentView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    @State private var session: EditorSession?
    @State private var currentProjectURL: URL?
    @State private var projects: [ProjectSummary] = []
    @State private var projectError: String?
    @State private var showingProjectManager = true
    @State private var currentPreview: Data?
    @State private var showingApplicationSettings = false
    @State private var viewportWasVisibleBeforeSettings = false

    var body: some View {
        let _ = interfaceLanguage
        ZStack {
            if let session {
                EditorWorkspace(session: session, openSettings: showApplicationSettings) {
                    currentPreview = try? session.renderer.projectThumbnailPNG()
                    refreshProjects()
                    showingProjectManager = true
                }
                .id(ObjectIdentifier(session))
            }
            if showingProjectManager || session == nil {
                ProjectManagerView(projects: projects, currentProject: currentProject,
                                   close: session == nil ? nil : { showingProjectManager = false },
                                   open: openProject, create: createProject,
                                   importProject: importProject, delete: deleteProject,
                                   applicationSettings: showApplicationSettings)
            }
        }
        .overlay {
            if showingApplicationSettings { ApplicationSettingsView(close: closeApplicationSettings) }
        }
        .environment(\.locale, (AppLanguage(rawValue: interfaceLanguage) ?? .system).locale)
        .onAppear { refreshProjects() }
        .alert(L10n.text("项目操作失败"), isPresented: Binding(
            get: { projectError != nil },
            set: { if !$0 { projectError = nil } })) {
                Button(L10n.text("确定"), role: .cancel) { projectError = nil }
            } message: {
                Text(projectError ?? "")
            }
    }

    private func showApplicationSettings() {
        viewportWasVisibleBeforeSettings = session?.renderer.isViewportVisible ?? false
        session?.endStroke()
        session?.endLayerPropertyEdit()
        session?.cancelSelection()
        session?.releaseModifiers()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        showingApplicationSettings = true
        session?.renderer.setViewportVisible(false)
    }

    private func closeApplicationSettings() {
        showingApplicationSettings = false
        session?.renderer.setViewportVisible(viewportWasVisibleBeforeSettings)
    }

    private func refreshProjects() {
        do { projects = try ProjectLibrary().projects() }
        catch { projectError = error.localizedDescription }
    }

    private var currentProject: ProjectSummary? {
        guard let session, let url = currentProjectURL else { return nil }
        let saved = projects.first { $0.id == ProjectSummary.identity(for: url) }
        return ProjectSummary(url: url, name: session.manifest.name, purpose:session.manifest.purpose,
                              pageCount: session.manifest.logicalPageCount,
                              modifiedAt: saved?.modifiedAt ?? .now,
                              thumbnail: currentPreview ?? saved?.thumbnail)
    }

    private func openProject(_ url: URL) {
        if let currentProjectURL,
           ProjectSummary.identity(for: url) == ProjectSummary.identity(for: currentProjectURL),
           session != nil {
            showingProjectManager = false
            return
        }
        guard session?.saveNow() ?? true else { return }
        do {
            session = try EditorSession(projectURL: url)
            currentProjectURL = url
            currentPreview = nil
            showingProjectManager = false
        } catch {
            projectError = error.localizedDescription
        }
    }

    private func createProject(_ request: ProjectCreation) {
        guard session?.saveNow() ?? true else { return }
        do {
            let url = try ProjectLibrary().create(request)
            refreshProjects()
            openProject(url)
        } catch {
            projectError = error.localizedDescription
        }
    }

    private func importProject(_ source: URL) {
        guard session?.saveNow() ?? true else { return }
        do {
            let url = try ProjectLibrary().importProject(from: source)
            refreshProjects()
            openProject(url)
        } catch {
            projectError = error.localizedDescription
        }
    }

    private func deleteProject(_ url: URL) {
        do {
            try ProjectLibrary().deleteProject(at: url)
            if let currentURL = currentProjectURL,
               ProjectSummary.identity(for: currentURL) == ProjectSummary.identity(for: url) {
                session = nil
                currentProjectURL = nil
                currentPreview = nil
                showingProjectManager = true
            }
            refreshProjects()
        } catch {
            projectError = L10n.format("删除失败：%@", "\(error.localizedDescription)")
        }
    }
}

private struct EditorWorkspace: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    private enum WorkspaceView: CaseIterable {
        case canvas, pages
        var title: String { self == .canvas ? L10n.text("画布") : L10n.text("页面一览") }
        var icon: String { self == .canvas ? "rectangle" : "rectangle.split.2x2" }
    }
    @ObservedObject var session: EditorSession
    let openSettings: () -> Void
    let showProjects: () -> Void
    private enum LayerEffectPanel { case tone, curves }
    @State private var effectPanel: LayerEffectPanel?
    @State private var selectionTool: DrawingTool = .selection
    @State private var showPressureCurve = false
    @State private var showBrushSettings = false
    @State private var dynamicsParameter: BrushParameter?
    @State private var brushSettingsAnchor: CGRect = .zero
    @State private var showColorEditor = false
    @State private var collapsedFolders: Set<UUID> = []
    @State private var layerRowFrames: [UUID: CGRect] = [:]
    @State private var layerListViewportHeight: CGFloat = 0
    @State private var draggingLayerID: UUID?
    @State private var layerDropTarget: LayerDragTarget?
    @State private var showAppMenu = false
    @State private var showExport = false
    @State private var workspaceView: WorkspaceView = .canvas
    @State private var bookPreview: BookPreviewController?

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1)
            HStack(spacing: 0) {
                toolRail
                    .padding(.bottom, workspaceView == .canvas ? ModifierPanelMetrics.size : 0)
                    .disabled(workspaceView == .pages)
                    .frame(width: 40)
                    .background(Color(red: 0.15, green: 0.16, blue: 0.17))
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
                ZStack {
                    CanvasSurfaceRepresentable(session: session)
                        .allowsHitTesting(workspaceView == .canvas)
                        .accessibilityHidden(workspaceView != .canvas)
                    if workspaceView == .canvas, session.showsRulers {
                        CanvasRulerOverlay(session:session).allowsHitTesting(false)
                    }
                    if workspaceView == .pages {
                        PageOverviewView(session: session) { id in
                            if session.selectPage(id) { workspaceView = .canvas }
                        }
                    }
                }
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
                VStack(spacing:0) {
                    CanvasNavigationPanel(session:session)
                    Rectangle().fill(Color.black.opacity(0.45)).frame(height:1)
                    sidebar
                }
                    .disabled(workspaceView == .pages)
                    .frame(width: 224)
                    .background(Color(red: 0.15, green: 0.16, blue: 0.17))
            }
            .overlay(alignment: .bottomLeading) {
                if workspaceView == .canvas {
                    ModifierKeysPanel(active: session.activeModifiers) { modifier, pressed in
                        session.setModifier(modifier, pressed: pressed)
                    }
                    .frame(width: ModifierPanelMetrics.size, height: ModifierPanelMetrics.size)
                    .overlay(alignment: .topTrailing) {
                        if !session.activeModifiers.isEmpty {
                            ModifierKeysIndicator(active: session.activeModifiers)
                                .offset(y: -ModifierPanelMetrics.indicatorHeight - ModifierPanelMetrics.indicatorGap)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .coordinateSpace(name: "editorWorkspace")
        .onPreferenceChange(BrushSettingsAnchorKey.self) { frame in
            if !frame.isEmpty { brushSettingsAnchor = frame }
        }
        .overlay {
            FloatingPanelOverlay(session: session, brush: $session.brush,
                                 pressureCurve: $session.pressureCurve,
                                 showsPressure: showPressureCurve,
                                 closePressure: { showPressureCurve = false },
                                 showsColor: showColorEditor && workspaceView == .canvas,
                                 showsBrush: showBrushSettings && workspaceView == .canvas,
                                 brushAnchor: brushSettingsAnchor,
                                 closeColor: { showColorEditor = false },
                                 closeBrush: { showBrushSettings = false },
                                 dynamicsParameter: workspaceView == .canvas ? dynamicsParameter : nil,
                                 editDynamics: { dynamicsParameter = $0 },
                                 closeDynamics: { dynamicsParameter = nil })
        }
        .overlay {
            if showAppMenu {
                ZStack(alignment: .topLeading) {
                    // Menus dismiss on an outside click; persistent panels keep
                    // their separate pass-through interaction above the canvas.
                    Button { showAppMenu = false } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(ImmediateButtonStyle(showsPressFeedback: false))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("关闭应用菜单"))
                    appMenu
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .offset(x: 33, y: 35)
                }
            }
        }
        .overlay {
            if showExport {
                ExportSettingsView(session: session, close: { showExport = false })
            }
        }
        .preferredColorScheme(.dark)
        .overlay {
            if let bookPreview {
                BookPreviewView(controller: bookPreview) { self.bookPreview = nil }
            }
        }
        .controlSize(.mini)
        .onChange(of: workspaceView) { _, view in
            session.renderer.setViewportVisible(view == .canvas)
        }
        .alert("Mangar", isPresented: Binding(
            get: { session.message != nil },
            set: { if !$0 { session.message = nil } })) {
                Button(L10n.text("确定"), role: .cancel) { session.message = nil }
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
            session.flushBrushResource()
            session.saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            showAppMenu = false
            session.flushBrushResource()
            session.endStroke()
            session.releaseModifiers()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                showAppMenu = false
                showProjects()
            } label: {
                MangarLogoMark()
                    .frame(width: 22, height: 22)
                    .frame(width: 25, height: 24)
            }
            .help(L10n.text("项目管理"))
            .accessibilityLabel(L10n.text("项目管理"))
            Button {
                showAppMenu.toggle()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 22, height: 24)
            }
            .help(L10n.text("应用菜单"))
            .accessibilityLabel(L10n.text("应用菜单"))
            HStack(spacing: 1) {
                ForEach(WorkspaceView.allCases, id: \.self) { view in
                    Button {
                        guard view != workspaceView else { return }
                        session.endStroke()
                        session.releaseModifiers()
                        showAppMenu = false
                        if view == .pages { session.refreshCurrentPageThumbnail() }
                        workspaceView = view
                    } label: {
                        Image(systemName: view.icon)
                            .frame(width: 27, height: 25)
                            .background(workspaceView == view ? Color.white.opacity(0.14) : .clear)
                            .contentShape(Rectangle())
                    }
                    .help(view.title)
                    .accessibilityLabel(view.title)
                    .accessibilityAddTraits(workspaceView == view ? [.isSelected] : [])
                }
            }
            .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
            Rectangle().fill(.white.opacity(0.18))
                .frame(width: 1, height: 18).padding(.horizontal, 3)
            Button { session.saveNow() } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 22, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if session.needsSave {
                            Circle().fill(Color.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .help(session.needsSave ? L10n.text("保存项目（有未保存更改）") : L10n.text("保存项目"))
            .accessibilityLabel(L10n.text("保存项目"))
            Button {
                session.undo()
                if workspaceView == .pages { session.refreshCurrentPageThumbnail() }
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 24)
            }
            .disabled(!session.canUndo)
            .help(L10n.text("撤销"))
            Button {
                session.redo()
                if workspaceView == .pages { session.refreshCurrentPageThumbnail() }
            } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 22, height: 24)
            }
            .disabled(!session.canRedo)
            .help(L10n.text("重做"))
            if workspaceView == .canvas {
                Button { session.clearSelectedTarget() } label: {
                    ClearCanvasIcon().frame(width: 22, height: 24)
                }
                .disabled(!session.canClearSelectedTarget)
                .help(session.selectedEditTarget == .mask ? L10n.text("清空蒙版（有选区时仅作用于选区）") : L10n.text("清空图层（有选区时仅作用于选区）"))
                .accessibilityLabel(L10n.text("清空当前编辑目标"))
            }
            Spacer(minLength: 8)
            if workspaceView == .canvas, session.hasSelection {
                HStack(spacing: 1) {
                    Button { session.showsSelectionTint.toggle() } label: {
                        Image(systemName: "rectangle.dashed.badge.record")
                            .frame(width: 24, height: 24)
                            .foregroundStyle(session.showsSelectionTint ? Color.blue : Color.primary)
                            .background(session.showsSelectionTint ? Color.blue.opacity(0.25) : .clear)
                    }.help(L10n.text("显示选区覆盖率（蓝色）")).accessibilityLabel(L10n.text("显示选区连续覆盖率"))
                        .accessibilityAddTraits(session.showsSelectionTint ? [.isSelected] : [])
                    Button { session.changeSelection(.invert) } label: {
                        Image(systemName: "circle.lefthalf.filled").frame(width: 24, height: 24)
                    }.help(L10n.text("反转选区")).accessibilityLabel(L10n.text("反转选区"))
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    Button { session.changeSelection(.clear) } label: {
                        Image(systemName: "selection.pin.in.out").frame(width: 24, height: 24)
                    }.help(L10n.text("清除选区")).accessibilityLabel(L10n.text("清除选区"))
                        .keyboardShortcut("d", modifiers: [.command])
                }
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 3)
            }
            if workspaceView == .pages {
                if DocumentPreviewForm.resolve(session.manifest) != nil {
                    Button {
                        do { bookPreview = try BookPreviewController(source: session.makeBookPreviewSource()) }
                        catch { session.message = error.localizedDescription }
                    } label: {
                        Text(verbatim: "3D").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                    }.help(L10n.text("3D预览"))
                }
                Text(L10n.format("%@ 页", "\(session.manifest.logicalPageCount)"))
                    .foregroundStyle(.secondary)
                if session.manifest.pageStructure == .bookSpreads {
                HStack(spacing: 1) {
                    ForEach(PageStartSide.allCases, id: \.self) { side in
                        Button { session.setStartingSide(side) } label: {
                            Text(side.title)
                                .font(.system(size: 11))
                                .padding(.horizontal, 6).frame(height: 25)
                                .background(session.manifest.startingSide == side
                                            ? Color.white.opacity(0.14) : .clear)
                                .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(session.manifest.startingSide == side ? [.isSelected] : [])
                    }
                }
                .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
                }
            } else if session.selectedTool.isSelectionTool {
                Image(systemName: session.selectedTool == .lassoSelection ? "lasso" : "rectangle.dashed")
                Text(session.selectedTool == .lassoSelection ? L10n.text("套索选区") : L10n.text("矩形选区"))
                Text(L10n.text("⇧追加  ⌥减去  ⇧⌥相交"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(L10n.text("全选")) { session.changeSelection(.selectAll) }
                    .keyboardShortcut("a", modifiers: [.command])
            } else if session.selectedTool == .bucket {
                BucketToolIcon().frame(width: 17, height: 17)
                Text(session.isFilling ? L10n.text("计算填充…") : L10n.text("油漆桶"))
                Text(L10n.text("容差")).font(.system(size: 10)).foregroundStyle(.secondary)
                FlatSlider(value: $session.bucketSettings.tolerance, range: 0...1).frame(width: 65)
                Text("\(Int(session.bucketSettings.tolerance * 100))%").font(.system(size: 10)).monospacedDigit().frame(width: 28)
                Text(L10n.text("闭合")).font(.system(size: 10)).foregroundStyle(.secondary)
                FlatSlider(value: Binding(get: { Double(session.bucketSettings.closeGap) },
                    set: { session.bucketSettings.closeGap = Int($0.rounded()) }), range: 0...32).frame(width: 65)
                Text("\(session.bucketSettings.closeGap) px").font(.system(size: 10)).monospacedDigit().frame(width: 32)
            } else if session.selectedTool == .lassoFill {
                Image(systemName: "lasso")
                Text(L10n.text("套索填充"))
                Text(L10n.format("当前颜色 · 不透明度 %@%%", "\(Int((session.brush.opacity * 100).rounded()))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Image(systemName: session.selectedTool == .eraser ? "eraser.fill" : session.brush.preset.icon)
                Text(session.selectedTool == .eraser ? L10n.text("橡皮擦") : session.brush.preset.name)
                if session.selectedEditTarget == .mask {
                    Text(L10n.text("蒙版")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                FlatSlider(value: $session.brush.size, range: 1...2000, logarithmic: true)
                    .frame(width: 105)
                Text("\(Int(session.brush.size)) px")
                    .monospacedDigit()
                    .frame(width: 48)
                Button {
                    showBrushSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 22, height: 24)
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: BrushSettingsAnchorKey.self,
                        value: geometry.frame(in: .named("editorWorkspace")))
                })
            }
        }
        .font(.system(size: 13))
        .buttonStyle(ImmediateButtonStyle())
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(Color(red: 0.18, green: 0.19, blue: 0.20))
    }

    private var appMenu: some View {
        VStack(spacing: 0) {
            Button {
                showAppMenu = false
                showProjects()
            } label: {
                Label(L10n.text("项目管理"), systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                .padding(.vertical, 3)
            Button {
                showAppMenu = false
                openSettings()
            } label: {
                Label(L10n.text("settings.title"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            }
            Button {
                showAppMenu = false
                showPressureCurve = true
            } label: {
                Label(L10n.text("全局压感曲线"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            }
            Button {
                showAppMenu = false
                showExport = true
            } label: {
                Label(L10n.text("导出当前页 PNG"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            }
        }
        .font(.system(size: 12))
        .buttonStyle(ImmediateButtonStyle())
        .padding(5)
        .frame(width: 174)
        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
        .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }

    private var toolRail: some View {
        VStack(spacing: 2) {
            Button { session.selectBrush(.pencil) } label: {
                Image(systemName: BrushPresetID.pencil.icon)
                    .font(.system(size: 17)).frame(width: 34, height: 34)
                    .background(session.selectedTool == .brush && session.brush.resourceID == nil && session.brush.preset == .pencil
                                ? Color.gray.opacity(0.4) : Color.clear)
            }
            .buttonStyle(ImmediateButtonStyle())
            .keyboardShortcut("p", modifiers: [])
            .help(L10n.text("铅笔"))
            .accessibilityLabel(L10n.text("铅笔"))
            .accessibilityAddTraits(session.selectedTool == .brush && session.brush.resourceID == nil && session.brush.preset == .pencil ? .isSelected : [])
            SlideSelectToolControl(items: BrushPresetID.inkPresets.map {
                SlideSelectToolItem(id: $0.rawValue, name: $0.name, icon: $0.icon)
            } + session.brushResources.map {
                SlideSelectToolItem(id: $0.id.uuidString, name: $0.name, icon: "paintbrush.pointed")
            }, currentID: session.inkBrushID,
                selected: session.selectedTool == .brush && (session.brush.resourceID != nil || BrushPresetID.inkPresets.contains(session.brush.preset)),
                activate: { session.activateInkBrush() }, choose: { id in
                    if let preset = BrushPresetID(rawValue: id) { session.selectBrush(preset) }
                    else if let resource = session.brushResources.first(where: { $0.id.uuidString == id }) {
                        session.selectBrushResource(resource)
                    }
                })
                .frame(width: 34, height: 34)
                .background {
                    Button(L10n.text("选择墨水笔")) { session.activateInkBrush() }
                        .keyboardShortcut("b", modifiers: []).hidden().accessibilityHidden(true)
                }
                .help(L10n.format("%@ · 向右滑动选择笔刷", "\(session.inkPreset.name)"))
            SlideSelectToolControl(items: BrushPresetID.oilPresets.map {
                SlideSelectToolItem(id: $0.rawValue, name: $0.name, icon: $0.icon)
            }, currentID: BrushPresetID.oilFlat.rawValue,
                selected: session.selectedTool == .brush && session.brush.resourceID == nil && session.brush.preset == .oilFlat,
                activate: { session.selectBrush(.oilFlat) }, choose: { id in
                    if let preset = BrushPresetID(rawValue: id) { session.selectBrush(preset) }
                })
                .frame(width: 34, height: 34)
                .help(L10n.text("油画笔 · 向右滑动选择笔刷"))
            SlideSelectToolControl(items: BrushPresetID.watercolorPresets.map {
                SlideSelectToolItem(id: $0.rawValue, name: $0.name, icon: $0.icon)
            }, currentID: BrushPresetID.watercolorWash.rawValue,
                selected: session.selectedTool == .brush && session.brush.resourceID == nil && session.brush.preset == .watercolorWash,
                activate: { session.selectBrush(.watercolorWash) }, choose: { id in
                    if let preset = BrushPresetID(rawValue: id) { session.selectBrush(preset) }
                })
                .frame(width: 34, height: 34)
                .help(L10n.text("水彩笔 · 向右滑动选择笔刷"))
            toolButton(.eraser, icon: "eraser.fill", name: L10n.text("橡皮擦"))
                .keyboardShortcut("e", modifiers: [])
            SlideSelectToolControl(items: [
                SlideSelectToolItem(id: DrawingTool.selection.rawValue, name: L10n.text("矩形选区"), icon: "rectangle.dashed"),
                SlideSelectToolItem(id: DrawingTool.lassoSelection.rawValue, name: L10n.text("套索选区"), icon: "lasso")
            ], currentID: selectionTool.rawValue, selected: session.selectedTool.isSelectionTool,
                activate: { activateSelectionTool(selectionTool) },
                choose: { id in
                    if let tool = DrawingTool(rawValue: id), tool.isSelectionTool { activateSelectionTool(tool) }
                })
                .frame(width: 34, height: 34)
                .background {
                    Group {
                        Button(L10n.text("矩形选区")) { activateSelectionTool(.selection) }
                            .keyboardShortcut("m", modifiers: [])
                        Button(L10n.text("套索选区")) { activateSelectionTool(.lassoSelection) }
                            .keyboardShortcut("l", modifiers: [])
                    }.hidden().accessibilityHidden(true)
                }
                .help(L10n.text("选区 · 向右滑动选择矩形或套索"))
            toolButton(.lassoFill, icon: "lasso", name: L10n.text("套索填充"))
            toolButton(.bucket, icon: "paintbrush.fill", name: L10n.text("油漆桶"))
                .disabled(session.manifest.purpose == .unrestricted)
                .keyboardShortcut("g", modifiers: [])
            Spacer(minLength: 12)
            ColorPresetControl(color: AppColor(session.brush), selected: !session.usesTransparentColor,
                presets: session.colorPresets, tap: {
                    if session.usesTransparentColor { session.usesTransparentColor = false }
                    else { showColorEditor.toggle() }
                }, choose: { session.useColorPreset($0) }, store: { session.storeColorPreset($0) })
                .frame(width: 34, height: 29)
            Button {
                session.endStroke()
                session.usesTransparentColor = true
            } label: {
                ThumbnailChecker()
                    .frame(width: 25, height: 12.5)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                    .overlay {
                        if session.usesTransparentColor {
                            Rectangle().inset(by: -1).stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .frame(width: 34, height: 16.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ImmediateButtonStyle())
            .help(L10n.text("透明色"))
            .accessibilityLabel(L10n.text("透明色"))
            .accessibilityAddTraits(session.usesTransparentColor ? .isSelected : [])
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func activateSelectionTool(_ tool: DrawingTool) {
        session.cancelSelection()
        session.cancelStroke()
        selectionTool = tool
        session.selectedTool = tool
    }

    private func toolButton(_ tool: DrawingTool, icon: String, name: String) -> some View {
        Button {
            session.cancelSelection()
            session.cancelStroke()
            session.selectedTool = tool
        } label: {
            Group {
                if tool == .bucket { BucketToolIcon().frame(width: 19, height: 19) }
                else { Image(systemName: icon).font(.system(size: 17)) }
            }
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    if tool == .lassoFill {
                        Image(systemName: "drop.fill").font(.system(size: 9))
                            .padding(3).allowsHitTesting(false)
                    }
                }
                .background(session.selectedTool == tool
                            ? Color.gray.opacity(0.4) : Color.clear)
        }
        .buttonStyle(ImmediateButtonStyle())
        .help(name)
        .accessibilityLabel(name)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            layerControls
            if effectPanel == .tone { toneParameters }
            if effectPanel == .curves { LayerCurveParameters(session: session, close: { effectPanel = nil }) }
            layerList
        }
        .buttonStyle(ImmediateButtonStyle())
    }

    private var layerControls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("图层"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.leading, 2)
            .frame(height: 22)
            HStack(spacing: 0) {
                Button { session.addLayer() } label: {
                    layerActionIcon("plus.square")
                }
                    .help(L10n.text("新建绘画图层"))
                    .accessibilityLabel(L10n.text("新建绘画图层"))
                Button { session.addFolder() } label: {
                    layerActionIcon("folder.badge.plus")
                }
                    .help(L10n.text("新建图层文件夹"))
                    .accessibilityLabel(L10n.text("新建图层文件夹"))
                Button { session.addLayerMask() } label: {
                    layerActionIcon("rectangle.badge.plus")
                }
                .disabled(!session.canAddLayerMask)
                .help(L10n.text("添加图层蒙版"))
                .accessibilityLabel(L10n.text("添加图层蒙版"))
                Button { session.toggleSelectedLock() } label: {
                    layerActionIcon(session.selectedLockActionWillLock ? "lock.fill" : "lock.open")
                }
                .disabled(session.selectedLayerID == nil)
                .help(session.selectedLockActionWillLock ? L10n.text("锁定所选图层") : L10n.text("解锁所选图层"))
                .accessibilityLabel(session.selectedLockActionWillLock ? L10n.text("锁定所选图层") : L10n.text("解锁所选图层"))
                Spacer(minLength: 0)
                Button(role: .destructive) { session.deleteSelectedLayer() } label: {
                    layerActionIcon("trash")
                }
                .disabled(!session.canDeleteSelection)
                .help(session.selectedEditTarget == .mask ? L10n.text("删除蒙版") : L10n.text("删除所选图层或文件夹"))
                .accessibilityLabel(session.selectedEditTarget == .mask ? L10n.text("删除蒙版") : L10n.text("删除所选图层或文件夹"))
            }
            .font(.system(size: 13))
            .buttonStyle(ImmediateButtonStyle())
            .frame(height: 24)
            HStack(spacing: 0) {
                SlideOutButton(icon: "circle.grid.3x3.fill", label: L10n.text("网点效果"),
                    isOn: !session.selectedLayerIDs.isEmpty && !session.selectedToneWillEnable,
                    isExpanded: effectPanel == .tone,
                    action: { session.toggleSelectedTone() },
                    expand: { session.endLayerPropertyEdit(); effectPanel = .tone })
                    .frame(width: 23, height: 23)
                    .disabled(session.selectedLayerID == nil)
                SlideOutButton(icon: "chart.xyaxis.line", label: L10n.text("曲线调整"),
                    isOn: !session.selectedLayerIDs.isEmpty && !session.selectedCurvesWillEnable,
                    isExpanded: effectPanel == .curves,
                    action: { session.toggleSelectedCurves() },
                    expand: { session.endLayerPropertyEdit(); effectPanel = .curves })
                    .frame(width: 23, height: 23).disabled(session.selectedLayerID == nil)
                Button { session.showsTargetTint.toggle() } label: {
                    layerActionIcon("drop.halffull")
                        .foregroundStyle(session.showsTargetTint ? Color.blue : Color.primary)
                        .background(session.showsTargetTint ? Color.blue.opacity(0.25) : .clear)
                }
                .disabled(session.selectedLayerID == nil)
                .help(L10n.text("蓝色预览所选缩略图"))
                .accessibilityLabel(L10n.text("蓝色预览所选缩略图"))
                .accessibilityValue(session.showsTargetTint ? L10n.text("已启用") : L10n.text("未启用"))
                .accessibilityAddTraits(session.showsTargetTint ? .isSelected : [])
                Spacer(minLength: 0)
            }
            .buttonStyle(ImmediateButtonStyle())
            .frame(height: 24)
        }
    }

    private func layerActionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.monochrome)
            .frame(width: 14, height: 14)
            .frame(width: 23, height: 23)
            .contentShape(Rectangle())
    }

    private var toneParameters: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(L10n.text("网点参数")).font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Button { session.endLayerPropertyEdit(); effectPanel = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .accessibilityLabel(L10n.text("关闭网点参数区"))
            }
            if let layer = session.selectedLayer {
                let tone = layer.tone ?? LayerToneEffect(isEnabled: false)
                toneParameter(L10n.text("线数"), text: "\(Int(tone.frequency.rounded()))",
                    value: .number(tone.frequency, 10...120, pointsPerUnit: 1), unit: L10n.text("线/英寸"), layer: layer) {
                        session.previewLayerTone(frequency: $0)
                    }
                toneParameter(L10n.text("角度"), text: "\(Int(tone.angle.rounded()))",
                    value: .number(tone.angle, 0...180, pointsPerUnit: 1), unit: "°", layer: layer) {
                        session.previewLayerTone(angle: $0)
                    }
                toneParameter(L10n.text("浓度"), text: "\(Int((tone.density * 100).rounded()))%",
                    value: .number(tone.density, 0...1, pointsPerUnit: 200), unit: "", layer: layer) {
                        session.previewLayerTone(density: $0)
                    }
            } else {
                Text(L10n.text("未选择图层")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .background(Color(red: 0.18, green: 0.19, blue: 0.20))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
    }

    private func toneParameter(_ title: String, text: String, value: VerticalDragProperty.Value,
                               unit: String, layer: LayerRecord, change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            VerticalDragProperty(text: text, label: L10n.format("property.description", L10n.text("网点"), title), value: value,
                begin: { session.beginLayerPropertyEdit(layer.id) }, change: change,
                end: { session.endLayerPropertyEdit(commit: $0) }, emphasized: true)
                .frame(width: 40, height: 16)
                .disabled(layer.tone?.isEnabled != true)
            Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
    }

    private var visibleLayerEntries: [LayerDisplayEntry] {
        session.page.layerDisplayEntries.filter { entry in
            !collapsedFolders.contains { session.page.isDescendant(entry.id, of: $0) }
        }
    }

    private var layerList: some View {
        GeometryReader { geometry in
            let highlighted = visibleContentLayerIDs
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleLayerEntries) { entry in
                        layerRow(entry, highlighted:highlighted)
                    }
                    Rectangle()
                        .fill(.clear)
                        .frame(height: max(48, geometry.size.height - CGFloat(visibleLayerEntries.count * 35) - 2))
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if let target = layerDropTarget, target.lineRowID == nil {
                                layerDropLine(depth: target.depth)
                            }
                        }
                }
                .padding(1)
            }
            .coordinateSpace(name: "layerList")
            .onPreferenceChange(LayerRowFrameKey.self) { layerRowFrames = $0 }
            .onAppear { layerListViewportHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in layerListViewportHeight = height }
            .background(Color(red: 0.105, green: 0.11, blue: 0.12))
            .overlay(Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 3)
    }

    private var visibleContentLayerIDs: Set<UUID> { session.renderer.visibleContentLayerIDs }

    private func layerRow(_ entry: LayerDisplayEntry, highlighted: Set<UUID>) -> some View {
        let layer = entry.layer
        return HStack(spacing: 0) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { session.toggleVisibility(layer.id) }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .contentTransition(.identity)
                    .foregroundStyle(session.page.isEffectivelyVisible(layer.id)
                                     ? (highlighted.contains(layer.id) ? Color.accentColor : Color.primary) : Color.gray.opacity(0.55))
                    .frame(width: 25, height: 35)
            }
            .buttonStyle(ImmediateButtonStyle())
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .accessibilityLabel(layer.isVisible ? L10n.text("隐藏图层") : L10n.text("显示图层"))
            GeometryReader { geometry in
                let inset = CGFloat(1 + entry.depth * 10)
                let trailingWidth: CGFloat = layer.isLocked ? 42 : 21
                let contentWidth = max(0, geometry.size.width - inset - 1 - trailingWidth)
                let textWidth = max(0, contentWidth - 26 - (layer.hasMask ? 26 : 0))
                HStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Group {
                            if layer.kind == .folder {
                                Button {
                                    var transaction = Transaction(animation: nil)
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        if !collapsedFolders.insert(layer.id).inserted {
                                            collapsedFolders.remove(layer.id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 1) {
                                        Image(systemName: collapsedFolders.contains(layer.id) ? "chevron.right" : "chevron.down")
                                            .contentTransition(.identity)
                                            .font(.system(size: 8))
                                            .frame(width: 8)
                                            .foregroundStyle(layerDropTarget?.parentID == layer.id ? Color.accentColor : Color.primary)
                                            .background(layerDropTarget?.parentID == layer.id
                                                        ? Color.accentColor.opacity(0.22) : .clear)
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(.gray)
                                            .frame(width: 15, alignment: .leading)
                                    }
                                    .frame(width: 24, height: 35)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(ImmediateButtonStyle())
                                .transaction { transaction in
                                    transaction.animation = nil
                                    transaction.disablesAnimations = true
                                }
                                .background { LayerRowActionBoundary() }
                                .accessibilityLabel(collapsedFolders.contains(layer.id) ? L10n.text("展开文件夹") : L10n.text("折叠文件夹"))
                            } else {
                                layerThumbnail(layer)
                                    .overlay(Rectangle().stroke(
                                        layer.id == session.selectedLayerID && session.selectedEditTarget == .content
                                        ? Color.accentColor : .clear, lineWidth: 2))
                                    .overlay { layerTargetCapture(layer.id, target: .content) }
                            }
                        }
                        .frame(height: 28)
                        if layer.hasMask {
                            Group {
                                if let image = session.renderer.maskThumbnail(for: layer.id) {
                                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                                } else { Color.white }
                            }
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.25))
                            .overlay(Rectangle().stroke(
                                layer.id == session.selectedLayerID && session.selectedEditTarget == .mask
                                ? Color.accentColor : Color.white.opacity(0.25), lineWidth:
                                    layer.id == session.selectedLayerID && session.selectedEditTarget == .mask ? 2 : 1))
                            .overlay { layerTargetCapture(layer.id, target: .mask) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            LayerNameControl(name: layer.name, primary: layer.id == session.selectedLayerID,
                                rename: { session.renameLayer(layer.id, to: $0) })
                                .frame(width: textWidth, height: 13, alignment: .leading)
                                .clipped()
                            HStack(spacing: 2) {
                                VerticalDragProperty(text: layer.blendMode.shortTitle, label: L10n.text("混合模式"),
                                    value: .choice(Int(layer.blendMode.shaderIndex), LayerBlendMode.allCases.map(\.title)),
                                    begin: { session.beginLayerPropertyEdit(layer.id) },
                                    change: { index in
                                        session.previewLayerBlendMode(LayerBlendMode.allCases[Int(index)])
                                    }, end: { session.endLayerPropertyEdit(commit: $0) })
                                .frame(width: 22)
                                VerticalDragProperty(text: "\(Int((layer.opacity * 100).rounded()))%", label: L10n.text("图层不透明度"),
                                    value: .number(layer.opacity, 0...1, pointsPerUnit: 200),
                                    begin: { session.beginLayerPropertyEdit(layer.id) },
                                    change: { session.previewLayerOpacity($0) },
                                    end: { session.endLayerPropertyEdit(commit: $0) })
                                .frame(width: 28)
                                if layer.curves?.isEnabled == true {
                                    Image(systemName: "chart.xyaxis.line").font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.65)).frame(width: 12, height: 14)
                                        .accessibilityLabel(L10n.text("已开启曲线调整")).allowsHitTesting(false)
                                }
                                if layer.tone?.isEnabled == true {
                                    Image(systemName: "circle.grid.3x3.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .frame(width: 12, height: 14)
                                        .accessibilityLabel(L10n.text("已开启网点效果"))
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(width: textWidth, height: 14, alignment: .leading)
                            .contentShape(Rectangle())
                            .clipped()
                        }
                        .frame(width: textWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .clipped()
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .clipped()
                    if layer.isLocked {
                        Button { session.toggleLock(layer.id) } label: {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 19, height: 35)
                        }
                        .buttonStyle(ImmediateButtonStyle())
                        .background { LayerRowActionBoundary() }
                        .accessibilityLabel(L10n.text("解锁图层"))
                    }
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(session.page.isEffectivelyLocked(layer.id) ? 0.35 : 1)
                        .frame(width: 19, height: 35)
                        .contentShape(Rectangle())
                        .highPriorityGesture(layerHandleDrag(layer.id))
                        .accessibilityLabel(L10n.text("拖动图层"))
                }
                .padding(.leading, inset)
                .padding(.trailing, 1)
                .frame(width: geometry.size.width, height: 35, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .contentShape(Rectangle())
            .background { layerSelectionCapture(layer.id) }
        }
        .font(.system(size: 11))
        .frame(height: 35)
        .frame(maxWidth: .infinity)
        .background(layer.id == session.selectedLayerID ? Color.accentColor.opacity(0.33) :
                    session.selectedLayerIDs.contains(layer.id) ? Color.gray.opacity(0.30) : .clear)
        .overlay(alignment: .leading) {
            layerTreeGuides(entry)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if layer.id == session.selectedLayerID {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            if let target = layerDropTarget,
               target.lineRowID == layer.id, target.lineAtTop {
                layerDropLine(depth: target.depth)
            }
        }
        .overlay(alignment: .bottom) {
            if let target = layerDropTarget,
               target.lineRowID == layer.id, !target.lineAtTop {
                layerDropLine(depth: target.depth)
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

    private func layerTargetCapture(_ id: UUID, target: LayerEditTarget) -> some View {
        LayerThumbnailTapCapture(label: target == .mask ? L10n.text("编辑图层蒙版") : L10n.text("编辑图层内容")) { modifiers in
            session.selectLayerTarget(id, target: target,
                shift: session.activeModifiers.contains(.shift) || modifiers.contains(.shift),
                command: session.activeModifiers.contains(.command) || modifiers.contains(.command))
        }
    }

    private func layerSelectionCapture(_ id: UUID) -> some View {
        LayerRowTapCapture { modifiers in
            session.selectLayer(id,
                shift: session.activeModifiers.contains(.shift) || modifiers.contains(.shift),
                command: session.activeModifiers.contains(.command) || modifiers.contains(.command))
        }
    }

    private func layerDropLine(depth: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(27 + depth * 10))
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private func hasFollowingSibling(_ id: UUID) -> Bool {
        guard let index = session.page.layers.firstIndex(where: { $0.id == id }) else { return false }
        let parentID = session.page.layers[index].parentID
        return session.page.layers.prefix(index).contains { $0.parentID == parentID }
    }

    private func layerTreeGuides(_ entry: LayerDisplayEntry) -> some View {
        var ancestors: [UUID] = []
        var parentID = entry.layer.parentID
        while let id = parentID,
              let parent = session.page.layers.first(where: { $0.id == id }) {
            ancestors.insert(id, at: 0)
            parentID = parent.parentID
        }
        let continuingDepths = ancestors.enumerated().compactMap { depth, id in
            hasFollowingSibling(id) ? depth + 1 : nil
        }
        let hasVisibleChildren = entry.layer.kind == .folder &&
            !collapsedFolders.contains(entry.id) &&
            session.page.layers.contains(where: { $0.parentID == entry.id })
        let hasNext = hasFollowingSibling(entry.id)
        let highlightedParent = layerDropTarget?.parentID
        // Arrow center: eye 25 + body inset 1 + half arrow 4 = 30.
        // A child's guide runs through its parent's arrow (one 10pt indent back).
        return Canvas { context, size in
            let middle = size.height / 2
            var lines = Path()
            var highlightedLines = Path()
            for depth in continuingDepths {
                let x = CGFloat(20 + depth * 10)
                let path = ancestors[depth - 1] == highlightedParent ? highlightedLines : lines
                var segment = path
                segment.move(to: CGPoint(x: x, y: 0))
                segment.addLine(to: CGPoint(x: x, y: size.height))
                if ancestors[depth - 1] == highlightedParent { highlightedLines = segment } else { lines = segment }
            }
            if entry.depth > 0 {
                let x = CGFloat(20 + entry.depth * 10)
                let isHighlighted = entry.layer.parentID == highlightedParent
                var segment = isHighlighted ? highlightedLines : lines
                segment.move(to: CGPoint(x: x, y: 0))
                segment.addLine(to: CGPoint(x: x, y: hasNext ? size.height : middle))
                segment.move(to: CGPoint(x: x, y: middle))
                segment.addLine(to: CGPoint(x: x + 5, y: middle))
                if isHighlighted { highlightedLines = segment } else { lines = segment }
            }
            if hasVisibleChildren {
                let x = CGFloat(20 + (entry.depth + 1) * 10)
                let isHighlighted = entry.id == highlightedParent
                var segment = isHighlighted ? highlightedLines : lines
                segment.move(to: CGPoint(x: x, y: middle))
                segment.addLine(to: CGPoint(x: x, y: size.height))
                if isHighlighted { highlightedLines = segment } else { lines = segment }
            }
            context.stroke(lines, with: .color(.white.opacity(0.25)), lineWidth: 1)
            context.stroke(highlightedLines, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(width: CGFloat(37 + entry.depth * 10), height: 35)
    }

    private func layerThumbnail(_ layer: LayerRecord) -> some View {
        ZStack {
            ThumbnailChecker()
            if layer.kind == .solidColor, let color = layer.solidColor {
                Rectangle().fill(Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
            } else if layer.kind == .shape, let shape = layer.shape, !shape.bounds.isEmpty {
                Rectangle().fill(Color(red: shape.fill.red, green: shape.fill.green, blue: shape.fill.blue, opacity: shape.fill.alpha))
            } else if let image = session.renderer.thumbnail(for: layer.id) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }
        }
        .frame(width: 24, height: 24)
        .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if layer.kind == .shape || layer.kind == .solidColor {
                Image(systemName: layer.kind == .solidColor ? "square.fill" : "square.on.circle.fill")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 12, height: 12)
                    .background(Color(red: 0.17, green: 0.18, blue: 0.19))
                    .help(layer.kind == .solidColor ? L10n.text("纯色图层") : L10n.text("图形图层"))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(layer.kind == .solidColor ? L10n.text("纯色图层缩略图") : (layer.kind == .shape ? L10n.text("图形图层缩略图") : L10n.text("绘画图层缩略图")))
    }

    private func layerHandleDrag(_ sourceID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("layerList"))
            .onChanged { gesture in
                guard !session.page.isEffectivelyLocked(sourceID) else { return }
                draggingLayerID = sourceID
                layerDropTarget = dropTarget(at: gesture.location,
                                             horizontalOffset: gesture.translation.width,
                                             moving: sourceID)
            }
            .onEnded { gesture in
                let target = session.page.isEffectivelyLocked(sourceID)
                    ? nil : dropTarget(at: gesture.location,
                                       horizontalOffset: gesture.translation.width,
                                       moving: sourceID)
                draggingLayerID = nil
                layerDropTarget = nil
                if let target {
                    session.moveLayer(sourceID, relativeTo: target.id, placement: target.placement)
                }
            }
    }

    private func dropTarget(at point: CGPoint, horizontalOffset: CGFloat,
                            moving sourceID: UUID) -> LayerDragTarget? {
        let moving = session.selectedLayerIDs.contains(sourceID) ? session.selectedLayerIDs : [sourceID]
        if let last = visibleLayerEntries.last,
           let lastFrame = layerRowFrames[last.id],
           point.y >= lastFrame.maxY,
            point.y <= max(layerListViewportHeight, lastFrame.maxY + 64),
            point.x >= lastFrame.minX - 120, point.x <= lastFrame.maxX + 120 {
            return dropTarget(after: visibleLayerEntries.count - 1, baseDepth: 0,
                              pointX: point.x, rowFrame: lastFrame,
                              horizontalOffset: horizontalOffset, moving: moving,
                              lineRowID: nil)
        }
        guard let match = layerRowFrames.first(where: {
            $0.value.minY <= point.y && point.y <= $0.value.maxY &&
            point.x >= $0.value.minX - 120 && point.x <= $0.value.maxX + 120
        }), let index = visibleLayerEntries.firstIndex(where: { $0.id == match.key }) else { return nil }
        let target = visibleLayerEntries[index]
        let fraction = (point.y - match.value.minY) / match.value.height
        let boundary: Int
        let baseDepth: Int
        if target.layer.kind == .folder && fraction >= 0.25 && fraction <= 0.75 {
            boundary = index
            baseDepth = target.depth + 1
        } else if fraction < 0.5 {
            boundary = index - 1
            baseDepth = target.depth
        } else {
            boundary = target.layer.kind == .folder
                ? (visibleLayerEntries.firstIndex(where: { $0.id == lastVisibleDescendant(of: target.id) }) ?? index)
                : index
            baseDepth = target.depth
        }
        return dropTarget(after: boundary, baseDepth: baseDepth,
                          pointX: point.x, rowFrame: match.value,
                          horizontalOffset: horizontalOffset, moving: moving,
                          lineRowID: boundary < 0 ? target.id : visibleLayerEntries[boundary].id)
    }

    private func dropTarget(after boundary: Int, baseDepth: Int, pointX: CGFloat,
                            rowFrame: CGRect, horizontalOffset: CGFloat,
                            moving: [UUID], lineRowID: UUID?) -> LayerDragTarget? {
        let entries = visibleLayerEntries
        guard !entries.isEmpty else { return nil }
        if boundary < 0 {
            let first = entries[0]
            guard !moving.contains(first.id) else { return nil }
            return LayerDragTarget(id: first.id, placement: .above, parentID: nil,
                                   depth: 0, lineRowID: first.id, lineAtTop: true)
        }
        let previous = entries[boundary]
        let nextDepth = boundary + 1 < entries.count ? entries[boundary + 1].depth : 0
        let maximumDepth = previous.depth + (previous.layer.kind == .folder ? 1 : 0)
        guard nextDepth <= maximumDepth else { return nil }
        var candidates: [LayerDragTarget] = []
        for depth in nextDepth...maximumDepth {
            let anchor: LayerDisplayEntry
            let placement: LayerDropPlacement
            let parentID: UUID?
            if depth == previous.depth + 1 {
                anchor = previous
                placement = .inside
                parentID = previous.id
            } else {
                let ancestors = entries.prefix(boundary + 1).filter {
                    $0.depth == depth && ($0.id == previous.id || session.page.isDescendant(previous.id, of: $0.id))
                }
                guard let matchingAncestor = ancestors.last else { continue }
                anchor = matchingAncestor
                placement = .below
                parentID = anchor.layer.parentID
            }
            guard !moving.contains(where: { $0 == anchor.id || session.page.isDescendant(anchor.id, of: $0) }),
                  parentID.map({ !session.page.isEffectivelyLocked($0) }) ?? true else { continue }
            candidates.append(LayerDragTarget(id: anchor.id, placement: placement, parentID: parentID,
                                              depth: depth, lineRowID: lineRowID, lineAtTop: false))
        }
        guard !candidates.isEmpty else { return nil }
        if abs(horizontalOffset) < 12 {
            return candidates.min { abs($0.depth - baseDepth) < abs($1.depth - baseDepth) }
        }
        let bodyMinX = rowFrame.minX + 25
        let bodyWidth = max(1, rowFrame.maxX - bodyMinX)
        let fraction = min(max((pointX - bodyMinX) / bodyWidth, 0), 0.999_999)
        return candidates[Int(fraction * CGFloat(candidates.count))]
    }

    private func lastVisibleDescendant(of id: UUID) -> UUID? {
        guard let index = visibleLayerEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let depth = visibleLayerEntries[index].depth
        var last = id
        for entry in visibleLayerEntries.dropFirst(index + 1) {
            if entry.depth <= depth { break }
            last = entry.id
        }
        return last
    }
}

private struct LayerDragTarget: Equatable {
    let id: UUID
    let placement: LayerDropPlacement
    let parentID: UUID?
    let depth: Int
    let lineRowID: UUID?
    let lineAtTop: Bool
}

private struct LayerRowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
private struct BrushSettingsAnchorKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private final class FloatingPanelContainer: UIView {
    var colorHost: UIHostingController<AnyView>?
    var brushHost: UIHostingController<AnyView>?
    var pressureHost: UIHostingController<AnyView>?
    var dynamicsHost: UIHostingController<AnyView>?
    var brushAnchor: CGRect = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if let brushHost {
            let size = brushHost.sizeThatFits(in: bounds.size)
            let anchor = brushAnchor.isEmpty
                ? CGRect(x: bounds.width - 198, y: 0, width: 0, height: 34) : brushAnchor
            let x = min(max(6, anchor.maxX - size.width), max(6, bounds.width - size.width - 6))
            let below = anchor.maxY + 6
            let y = below + size.height <= bounds.height - 6 ? below :
                max(6, anchor.minY - size.height - 6)
            brushHost.view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        if let dynamicsHost {
            let size = dynamicsHost.sizeThatFits(in: bounds.size)
            let anchor = brushHost?.view.frame ?? CGRect(x: bounds.width - 270, y: 40, width: 264, height: 0)
            let left = anchor.minX - size.width - 5
            let right = anchor.maxX + 5
            let x = left >= 4 ? left : right + size.width <= bounds.width - 4 ? right :
                max(4, min(anchor.minX, bounds.width - size.width - 4))
            let y = left < 4 && right + size.width > bounds.width - 4 ? anchor.maxY + 5 : anchor.minY
            dynamicsHost.view.frame = CGRect(x: x, y: max(4, min(y, bounds.height - size.height - 4)),
                                             width: size.width, height: size.height)
        }
        if let pressureHost {
            let size = pressureHost.sizeThatFits(in: bounds.size)
            pressureHost.view.frame = CGRect(origin: CGPoint(
                x: min(33, max(4, bounds.width - size.width - 4)),
                y: min(41, max(4, bounds.height - size.height - 4))), size: size)
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
        for panel in subviews.reversed() where panelViews.contains(where: { $0 === panel }) && panel.frame.contains(point) {
            return panel.hitTest(convert(point, to: panel), with: event) ?? panel
        }
        return nil
    }

    private var panelViews: [UIView] {
        [colorHost?.view, brushHost?.view, pressureHost?.view, dynamicsHost?.view].compactMap { $0 }
    }
}

private struct FloatingPanelOverlay: UIViewRepresentable {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    @ObservedObject var session: EditorSession
    @Binding var brush: BrushConfiguration
    @Binding var pressureCurve: PressureCurve
    let showsPressure: Bool
    let closePressure: () -> Void
    let showsColor: Bool
    let showsBrush: Bool
    let brushAnchor: CGRect
    let closeColor: () -> Void
    let closeBrush: () -> Void
    let dynamicsParameter: BrushParameter?
    let editDynamics: (BrushParameter) -> Void
    let closeDynamics: () -> Void

    func makeUIView(context: Context) -> FloatingPanelContainer {
        let view = FloatingPanelContainer()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: FloatingPanelContainer, context: Context) {
        let _ = interfaceLanguage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        view.brushAnchor = brushAnchor
        if showsPressure {
            let panel = AnyView(PressureCurvePanel(curve: $pressureCurve, close: closePressure).immediateUI())
            if let host = view.pressureHost {
                host.rootView = panel
            } else {
                let host = UIHostingController(rootView: panel)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                view.pressureHost = host
            }
        } else {
            view.pressureHost?.view.removeFromSuperview()
            view.pressureHost = nil
        }
        if showsColor {
            let panel = AnyView(ColorEditorPanel(brush: $brush, close: closeColor).immediateUI())
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
            let panel = AnyView(BrushParametersPanel(brush: $brush, brushName: session.brushName, importTips: { session.importBrushTips($0, channel: $1) },
                reportError: { session.message = $0 }, editDynamics: editDynamics, close: closeBrush,
                maximumContentHeight: view.bounds.height > 0 ? min(540, max(240, view.bounds.height - 80)) : 540).immediateUI())
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
        if let dynamicsParameter {
            let panel = AnyView(BrushDynamicsPanel(brush: $brush, brushName: session.brushName, parameter: dynamicsParameter,
                close: closeDynamics).id(dynamicsParameter).immediateUI())
            if let host = view.dynamicsHost { host.rootView = panel }
            else {
                let host = UIHostingController(rootView: panel)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                view.dynamicsHost = host
            }
        } else {
            view.dynamicsHost?.view.removeFromSuperview()
            view.dynamicsHost = nil
        }
        view.setNeedsLayout()
    }
}

private struct ColorEditorPanel: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    @Binding var brush: BrushConfiguration
    let close: () -> Void
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(brush: Binding<BrushConfiguration>, close: @escaping () -> Void) {
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
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text("颜色")).font(.system(size: 12, weight: .semibold))
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
                .buttonStyle(ImmediateButtonStyle())
                .accessibilityLabel(L10n.text("关闭颜色面板"))
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
            Text(L10n.text("色相")).font(.system(size: 10)).foregroundStyle(.secondary)
            ramp(value: hue,
                 gradient: LinearGradient(colors: (0...6).map {
                    Color(hue: Double($0) / 6, saturation: 1, brightness: 1)
                 }, startPoint: .leading, endPoint: .trailing)) { value in
                hue = value
                applyColor()
            }
            HStack {
                Text(L10n.text("不透明度")).font(.system(size: 10)).foregroundStyle(.secondary)
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
        .frame(height: 9)
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


private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The conventional clear symbol: evenly spaced short radial strokes.
private struct ClearCanvasIcon: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            for index in 0..<12 {
                let angle = Double(index) * .pi / 6
                path.move(to: CGPoint(x: center.x + cos(angle) * 4.5,
                                      y: center.y + sin(angle) * 4.5))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * 7,
                                         y: center.y + sin(angle) * 7))
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
    }
}
