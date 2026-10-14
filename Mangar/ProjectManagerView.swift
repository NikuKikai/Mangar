import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ProjectManagerView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    let projects: [ProjectSummary]
    let currentProject: ProjectSummary?
    let close: (() -> Void)?
    let open: (URL) -> Void
    let create: (String, ComicPageLayout, Int, PageStartSide) -> Void
    let importProject: (URL) -> Void
    let delete: (URL) -> Void
    let applicationSettings: () -> Void

    @State private var showingAppMenu = false
    @State private var creating = false
    @State private var name = L10n.text("未命名项目")
    @State private var width = "182"
    @State private var height = "257"
    @State private var dpi = "350"
    @State private var horizontalMargin = "14"
    @State private var verticalMargin = "20"
    @State private var pageCount = "1"
    @State private var startingSide: PageStartSide = .right
    @State private var showingImporter = false
    @State private var showingPresets = false
    @State private var menuProjectID: String?
    @State private var pendingDelete: ProjectSummary?

    private let presets: [(name: String, width: Int, height: Int)] = [
        ("A4", 210, 297), ("B5", 182, 257), ("A5", 148, 210), ("B6", 128, 182)
    ]

    private var selectedPreset: String? {
        presets.first { width == String($0.width) && height == String($0.height) }?.name
    }

    private var draftLayout: ComicPageLayout? {
        guard let w = Double(width.replacingOccurrences(of: ",", with: ".")),
              let h = Double(height.replacingOccurrences(of: ",", with: ".")),
              let mx = Double(horizontalMargin.replacingOccurrences(of: ",", with: ".")),
              let my = Double(verticalMargin.replacingOccurrences(of: ",", with: ".")),
              let dpi = Int(dpi), w.isFinite, h.isFinite, mx.isFinite, my.isFinite,
              (1...500).contains(w), (1...500).contains(h),
              (0...100).contains(mx), (0...100).contains(my),
              (72...1200).contains(dpi) else { return nil }
        let layout = ComicPageLayout(contentWidthMM: w, contentHeightMM: h,
                                     dpi: dpi, marginMM: mx, verticalMarginMM: my)
        guard layout.canvasWidthPixels <= 16384, layout.canvasHeightPixels <= 16384 else { return nil }
        return layout
    }

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 250), spacing: 18,
                                    alignment: .top)]

    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { close?() } label: {
                    MangarLogoMark()
                        .frame(width: 22, height: 22)
                        .frame(width: 25, height: 24)
                }
                .disabled(close == nil)
                .help(close == nil ? "Mangar" : L10n.text("返回编辑界面"))
                .accessibilityLabel(close == nil ? L10n.text("Mangar，尚未打开项目") : L10n.text("返回编辑界面"))
                Rectangle().fill(.white.opacity(0.18))
                    .frame(width: 1, height: 18).padding(.horizontal, 3)
                Text(creating ? L10n.text("新建项目") : L10n.text("项目管理"))
                Spacer(minLength: 8)
                if creating {
                    Button { creating = false } label: {
                        Label(L10n.text("返回项目"), systemImage: "arrow.left")
                            .padding(.horizontal, 4).frame(height: 24)
                    }
                } else {
                    Button { showingImporter = true } label: {
                        Label(L10n.text("导入项目…"), systemImage: "square.and.arrow.down")
                            .padding(.horizontal, 4).frame(height: 24)
                    }
                }
                Button {
                    menuProjectID = nil
                    showingPresets = false
                    showingAppMenu.toggle()
                } label: { Image(systemName: "line.3.horizontal").frame(width: 22, height: 24) }
                    .help(L10n.text("应用菜单")).accessibilityLabel(L10n.text("应用菜单"))
            }
            .font(.system(size: 13))
            .buttonStyle(ImmediateButtonStyle())
            .controlSize(.mini)
            .padding(.horizontal, 4)
            .frame(height: 34)
            .background(Color(red: 0.18, green: 0.19, blue: 0.20))
            Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1)
            if creating {
                creationForm
            } else {
                projectGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if showingAppMenu {
                ZStack(alignment: .topTrailing) {
                    Button { showingAppMenu = false } label: { Color.clear.contentShape(Rectangle()) }
                        .accessibilityLabel(L10n.text("关闭应用菜单"))
                    VStack(spacing: 0) {
                        if let close {
                            Button { showingAppMenu = false; close() } label: {
                                Label(L10n.text("返回编辑界面"), systemImage: "arrow.left")
                                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                            }
                        }
                        Button { showingAppMenu = false; applicationSettings() } label: {
                            Label(L10n.text("settings.title"), systemImage: "gearshape")
                                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                        }
                    }.font(.system(size: 12)).padding(5).frame(width: 174)
                        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                        .offset(x: -4, y: 35)
                }.buttonStyle(ImmediateButtonStyle())
            }
        }
        .overlayPreferenceValue(ProjectCardBoundsKey.self) { anchors in
            if let id = menuProjectID, let anchor = anchors[id],
               let project = ([currentProject].compactMap { $0 } + projects).first(where: { $0.id == id }) {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { menuProjectID = nil }
                            .accessibilityLabel(L10n.text("关闭项目菜单"))
                            .accessibilityAddTraits(.isButton)
                        projectMenu(project)
                            .position(x: max(75, min(geometry.size.width - 75, bounds.maxX - 81)),
                                      y: max(16, min(geometry.size.height - 16, bounds.minY + 22)))
                    }
                }
            }
        }
        .overlay {
            if let project = pendingDelete {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.text("删除项目？")).font(.system(size: 16, weight: .semibold))
                        Text(L10n.format("“%@”及其所有页面将被删除，此操作无法撤销。", "\(project.name)"))
                            .font(.system(size: 13))
                        HStack(spacing: 8) {
                            Spacer()
                            Button(L10n.text("取消")) { pendingDelete = nil }
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Color.white.opacity(0.08))
                            Button(L10n.text("删除")) {
                                pendingDelete = nil
                                delete(project.url)
                            }
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Color(red: 0.65, green: 0.16, blue: 0.16))
                        }
                        .buttonStyle(ImmediateButtonStyle())
                    }
                    .padding(16)
                    .frame(width: 360)
                    .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                    .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
                }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.folder, .package,
                                            UTType(filenameExtension: "mangar") ?? .data]) { result in
            if case .success(let url) = result { importProject(url) }
        }
    }

    private var projectGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                Button { creating = true } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 38, weight: .ultraLight))
                        Text(L10n.text("新建项目"))
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 188)
                    .background(Color.white.opacity(0.055))
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
                .buttonStyle(ImmediateButtonStyle())
                if let current = currentProject {
                    projectCard(current, current: true)
                }
                ForEach(projects.filter { $0.id != currentProject?.id }) { project in
                    projectCard(project, current: false)
                }
            }
            .padding(28)
        }
    }

    private func projectCard(_ project: ProjectSummary, current: Bool) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color(red: 0.21, green: 0.22, blue: 0.23)
                    if let data = project.thumbnail,
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 38, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)
                .clipped()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(project.name).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if current {
                            Text(L10n.text("当前"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(L10n.format("%@ 页  ·  %@", "\(project.pageCount)", "\(L10n.date(project.modifiedAt))"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(9)
            }
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.18, green: 0.19, blue: 0.20))
            .overlay(Rectangle().stroke(current ? Color.accentColor : .white.opacity(0.1), lineWidth: 1))
        }
        .overlay {
            ProjectCardInteraction(name: project.name, open: {
                if menuProjectID != nil { menuProjectID = nil }
                else { open(project.url) }
            }, menu: { menuProjectID = project.id })
        }
        .anchorPreference(key: ProjectCardBoundsKey.self, value: .bounds) { [project.id: $0] }
    }

    private func projectMenu(_ project: ProjectSummary) -> some View {
                Button {
                    menuProjectID = nil
                    pendingDelete = project
                } label: {
                    Label(L10n.text("删除项目…"), systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.48))
                        .frame(width: 134, height: 32, alignment: .leading)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ImmediateButtonStyle())
                .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }

    private var creationForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.text("新建项目"))
                    .font(.system(size: 21, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        showingPresets.toggle()
                    } label: {
                        HStack {
                            Text(L10n.text("预设尺寸"))
                            Spacer()
                            Text(selectedPreset ?? L10n.text("自定义"))
                                .foregroundStyle(.secondary)
                            Image(systemName: showingPresets ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                        }
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.06))
                        .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                }
                .buttonStyle(ImmediateButtonStyle())
                .overlay(alignment: .topLeading) {
                    if showingPresets {
                        VStack(spacing: 0) {
                            ForEach(presets, id: \.name) { preset in
                                Button {
                                    width = String(preset.width)
                                    height = String(preset.height)
                                    showingPresets = false
                                } label: {
                                    Text("\(preset.name)  ·  \(preset.width) × \(preset.height) mm")
                                        .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                }
                                .background(selectedPreset == preset.name
                                            ? Color.white.opacity(0.08) : .clear)
                            }
                        }
                        .buttonStyle(ImmediateButtonStyle())
                        .background(Color(red: 0.16, green: 0.17, blue: 0.18))
                        .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                        .offset(y: 34)
                    }
                }
                .zIndex(1)
                field(L10n.text("项目名称"), value: $name)
                HStack(spacing: 14) {
                    field(L10n.text("内容宽度 / mm"), value: $width, numeric: true, decimal: true)
                    field(L10n.text("内容高度 / mm"), value: $height, numeric: true, decimal: true)
                }
                HStack(spacing: 14) {
                    field(L10n.text("分辨率 / dpi"), value: $dpi, numeric: true)
                    field(L10n.text("初始页数"), value: $pageCount, numeric: true)
                }
                HStack(spacing: 8) {
                    Text(L10n.text("起始页")).font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(PageStartSide.allCases, id: \.self) { side in
                        Button { startingSide = side } label: {
                            Text(side.title)
                                .font(.system(size: 12))
                                .padding(.horizontal, 9).frame(height: 28)
                                .background(startingSide == side ? Color.white.opacity(0.14) : .clear)
                                .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(ImmediateButtonStyle())
                    }
                }
                HStack(spacing: 14) {
                    field(L10n.text("左、右各留 / mm"), value: $horizontalMargin, numeric: true, decimal: true)
                    field(L10n.text("上、下各留 / mm"), value: $verticalMargin, numeric: true, decimal: true)
                }
                Text(L10n.text("默认 B5 内容置于 A4 稿纸：左右各 14 mm，上下各 20 mm。出血参考框距内容框 3 mm。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(draftLayout.map { L10n.format("画布预览：%@ × %@ px  ·  内容：%@ × %@ px", "\($0.canvasWidthPixels)", "\($0.canvasHeightPixels)", "\($0.contentWidthPixels)", "\($0.contentHeightPixels)") }
                     ?? L10n.text("请输入有效尺寸；画布最长边不超过 16384 px"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("取消")) { creating = false }
                    Spacer()
                    Button(L10n.text("创建并打开")) {
                        guard let layout = draftLayout, let count = Int(pageCount) else { return }
                        create(name.trimmingCharacters(in: .whitespacesAndNewlines), layout, count, startingSide)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              draftLayout == nil ||
                              Int(pageCount).map { !(1...100).contains($0) } ?? true)
                    .buttonStyle(ImmediateBorderedButtonStyle(prominent: true))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 580, alignment: .leading)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ImmediateBorderedButtonStyle())
    }

    private func field(_ title: String, value: Binding<String>, numeric: Bool = false,
                       decimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(title, text: value)
                .keyboardType(decimal ? .decimalPad : (numeric ? .numberPad : .default))
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .overlay(Rectangle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProjectCardBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ProjectCardInteraction: UIViewRepresentable {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    let name: String
    let open: () -> Void
    let menu: () -> Void

    func makeUIView(context: Context) -> ProjectCardHitView {
        let view = ProjectCardHitView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.longPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let secondaryClick = UITapGestureRecognizer(target: context.coordinator,
                                                    action: #selector(Coordinator.showMenu))
        secondaryClick.buttonMaskRequired = .secondary
        secondaryClick.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.openProject))
        tap.buttonMaskRequired = .primary
        tap.require(toFail: longPress)
        tap.require(toFail: secondaryClick)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(secondaryClick)
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.text("项目菜单"), target: context.coordinator,
                                        selector: #selector(Coordinator.accessibilityMenu))
        ]
        return view
    }

    func updateUIView(_ view: ProjectCardHitView, context: Context) {
        let _ = interfaceLanguage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        context.coordinator.open = open
        context.coordinator.menu = menu
        view.onOpen = open
        view.accessibilityLabel = name
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: open, menu: menu) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var open: () -> Void
        var menu: () -> Void
        init(open: @escaping () -> Void, menu: @escaping () -> Void) {
            self.open = open
            self.menu = menu
        }
        @objc func openProject() { open() }
        @objc func showMenu() { menu() }
        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { menu() }
        }
        @objc func accessibilityMenu() -> Bool { menu(); return true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive event: UIEvent) -> Bool {
            // UIKit ignores buttonMaskRequired for direct touches. Require an
            // actual secondary button event so a finger/Pencil tap stays a tap.
            event.buttonMask.contains(.secondary)
        }
    }
}

final class ProjectCardHitView: UIView {
    var onOpen: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        onOpen?()
        return true
    }
}
