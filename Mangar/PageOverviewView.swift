import SwiftUI

struct PageOverviewView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.system.rawValue
    @ObservedObject var session: EditorSession
    let openPage: (UUID) -> Void
    @State private var dragging: UUID?
    @State private var target: PageDropTarget?
    @State private var menuPage: UUID?
    @State private var pendingDelete: UUID?
    @State private var pendingMerge: UUID?
    @State private var frames: [Int: CGRect] = [:]
    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 350), spacing: 24)]

    var body: some View {
        let _ = interfaceLanguage
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                if session.manifest.pageStructure == .cards {
                    ForEach(Array(session.manifest.pageIDs.enumerated()), id: \.element) { index, id in
                        pageThumbnail(id, number: index+1, spread: false)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: PageFramesKey.self, value: [index: geometry.frame(in: .named("pages"))])
                            })
                    }
                    addPageControl(at: session.manifest.pageIDs.count, spread: false, dashed: true)
                } else {
                ForEach(PageContainer.arrange(session.manifest)) { container in
                    containerView(container)
                        .environment(\.layoutDirection, .leftToRight)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PageFramesKey.self,
                                value: [container.id: geometry.frame(in: .named("pages"))])
                        })
                }
                }
            }
            .environment(\.layoutDirection, session.manifest.pageStructure == .cards ? .leftToRight : .rightToLeft)
            .padding(24)
            .overlay {
                ZStack(alignment: .topLeading) {
                    if let target {
                        Rectangle().fill(Color.accentColor).frame(width: 3, height: target.frame.height)
                            .offset(x: target.frame.minX - 1.5, y: target.frame.minY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(\.layoutDirection, .leftToRight)
                .allowsHitTesting(false)
            }
            .coordinateSpace(name: "pages")
            .onPreferenceChange(PageFramesKey.self) { frames = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .buttonStyle(ImmediateButtonStyle())
        .scrollDisabled(dragging != nil)
        .overlay {
            if let id = menuPage { pageMenu(id) }
        }
        .alert(L10n.text("删除页面？"), isPresented: Binding(get: { pendingDelete != nil },
               set: { if !$0 { pendingDelete = nil } })) {
            Button(L10n.text("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.text("删除"), role: .destructive) {
                if let id = pendingDelete { session.deletePage(id) }
                pendingDelete = nil
            }
        } message: { Text(L10n.text("页面及其绘画数据将被删除。删除最后一页时会生成一个空白页。")) }
        .alert(L10n.text("合并为对开页？"), isPresented: Binding(get: { pendingMerge != nil },
               set: { if !$0 { pendingMerge = nil } })) {
            Button(L10n.text("取消"), role: .cancel) { pendingMerge = nil }
            Button(L10n.text("合并")) {
                if let id = pendingMerge { session.mergePages(id) }
                pendingMerge = nil
            }
        } message: { Text(L10n.text("保留左右页的图层，去掉中间两侧的画布余量。")) }
    }

    @ViewBuilder
    private func containerView(_ container: PageContainer) -> some View {
        Group {
            if let id = container.spreadID, let number = container.firstPageNumber {
                pageThumbnail(id, number: number, spread: true)
            } else if let index = container.appendIndex {
                HStack(spacing: 6) {
                    addPageControl(at: index, spread: true, dashed: false)
                    addPageControl(at: index, spread: false, dashed: true)
                }
            } else {
                HStack(spacing: 6) {
                    pageSlot(container.left)
                    pageSlot(container.right)
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.14, green: 0.15, blue: 0.16))
        .overlay(Rectangle().stroke(.white.opacity(0.24), lineWidth: 1))
    }

    @ViewBuilder
    private func pageSlot(_ slot: PageContainerSlot) -> some View {
        switch slot {
        case .page(let id, let number):
            pageThumbnail(id, number: number, spread: false)
        case .gap(let insertionIndex):
            addPageControl(at: insertionIndex, spread: false, dashed: true)
        case .beforeStart:
            Color.clear.frame(maxWidth: .infinity).frame(height: 236)
                .accessibilityHidden(true)
        }
    }

    private func addPageControl(at index: Int, spread: Bool, dashed: Bool) -> some View {
        Button { session.addPage(at: index, isSpread: spread) } label: {
            VStack(spacing: 0) {
                ZStack {
                    if dashed {
                        Rectangle().strokeBorder(.white.opacity(0.3),
                                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                    Image(systemName: "plus").font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 210)
                Text(spread ? L10n.text("添加对开页") : L10n.text("添加单页"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(spread ? L10n.text("添加对开页") : L10n.text("在此添加单页"))
    }

    private func pageThumbnail(_ id: UUID, number: Int, spread: Bool) -> some View {
        let current = id == session.page.id
        let title = spread ? "\(number)–\(number + 1)" : "\(number)"
        return VStack(spacing: 0) {
                ZStack {
                    Color(red: 0.19, green: 0.20, blue: 0.21)
                    if let image = session.pageThumbnails[id] {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(5)
                    } else {
                        Text(L10n.text("处理中…")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if spread {
                        Rectangle().fill(Color.gray.opacity(0.45))
                            .frame(width: 1).padding(.vertical, 5)
                    }
                }
                .frame(height: 210)
                .overlay {
                    ProjectCardInteraction(name: L10n.format("第 %@ 页", "\(title)"), open: { openPage(id) },
                                           menu: { menuPage = id })
                }
                ZStack {
                    Text(title).monospacedDigit()
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("pages"))
                                .onChanged { value in
                                    menuPage = nil
                                    dragging = id
                                    target = dropTarget(at: value.location, spread: spread)
                                }
                                .onEnded { _ in
                                    if let target { session.movePage(id, to: target.index) }
                                    target = nil
                                    dragging = nil
                                })
                            .accessibilityLabel(L10n.format("拖动第 %@ 页", "\(title)"))
                        Spacer(minLength: 0)
                        if current { Text(L10n.text("当前")).font(.system(size: 10)).foregroundStyle(Color.accentColor) }
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 3)
                .frame(height: 26)
            }
            .opacity(dragging == id ? 0.45 : 1)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.16, green: 0.17, blue: 0.18))
            .overlay(Rectangle().stroke(current ? Color.accentColor : .white.opacity(0.18),
                                         lineWidth: current ? 2 : 1))
        .task(id: id) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            session.loadPageThumbnail(id)
        }
    }

    private func pageMenu(_ id: UUID) -> some View {
        ZStack {
            Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { menuPage = nil }
            VStack(spacing: 0) {
                if session.manifest.pageStructure == .bookSpreads {
                if session.manifest.spreadPageIDs.contains(id) {
                    menuButton(L10n.text("拆分为两个单页"), icon: "rectangle.split.2x1") {
                        menuPage = nil
                        session.splitPage(id)
                    }
                } else {
                    menuButton(L10n.text("合并为对开页"), icon: "rectangle") {
                        menuPage = nil
                        pendingMerge = id
                    }
                    .disabled(session.mergePartner(for: id) == nil)
                    .opacity(session.mergePartner(for: id) == nil ? 0.4 : 1)
                }
                Divider()
                }
                menuButton(L10n.text("删除"), icon: "trash", destructive: true) {
                    menuPage = nil
                    pendingDelete = id
                }
            }
            .frame(width: 200)
            .background(Color(red: 0.17, green: 0.18, blue: 0.19))
            .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        }
    }

    private func menuButton(_ title: String, icon: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 12)).foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }
    }

    private func dropTarget(at point: CGPoint, spread: Bool) -> PageDropTarget? {
        if session.manifest.pageStructure == .cards {
            guard let item = frames.min(by: { distance(point, $0.value) < distance(point, $1.value) }) else { return nil }
            let before = point.x < item.value.midX
            return PageDropTarget(index: item.key + (before ? 0 : 1),
                frame: CGRect(x: before ? item.value.minX : item.value.maxX, y: item.value.minY, width: 3, height: item.value.height))
        }
        let containers = PageContainer.arrange(session.manifest)
        guard let container = containers.min(by: {
            distance(point, frames[$0.id] ?? .zero) < distance(point, frames[$1.id] ?? .zero)
        }), let frame = frames[container.id] else { return nil }
        func index(_ slot: PageContainerSlot) -> Int {
            switch slot {
            case .page(let id, _): return session.manifest.pageIDs.firstIndex(of: id) ?? 0
            case .gap(let insertionIndex): return insertionIndex
            case .beforeStart: return 0
            }
        }
        let start = container.spreadID.flatMap { session.manifest.pageIDs.firstIndex(of: $0) }
            ?? container.appendIndex ?? index(container.right)
        let end: Int = container.spreadID != nil ? start + 1 : {
            if case .page = container.left { return index(container.left) + 1 }
            return index(container.left)
        }()
        let candidates: [(CGFloat, Int)]
        if spread {
            candidates = [(frame.maxX + 12, start), (frame.minX - 12, end)]
        } else if container.spreadID != nil {
            candidates = [(frame.maxX - 7, start), (frame.minX + 7, end)]
        } else {
            candidates = [(frame.maxX - 7, start), (frame.midX, index(container.left)),
                          (frame.minX + 7, end)]
        }
        guard let nearest = candidates.min(by: { abs($0.0 - point.x) < abs($1.0 - point.x) }) else { return nil }
        return PageDropTarget(index: nearest.1,
            frame: CGRect(x: nearest.0, y: frame.minY + (spread ? 0 : 7),
                          width: 3, height: frame.height - (spread ? 0 : 14)))
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private struct PageDropTarget {
    let index: Int
    let frame: CGRect
}

private struct PageFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
