import SwiftUI

struct PageSurfaceControls: View {
    @Binding var kind: PageSurfaceKind
    @Binding var radius: String
    @Binding var outsideFill: SphereOutsideFill
    var commitRadius: () -> Void = {}
    @FocusState private var radiusFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("page.surface.type")).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                HStack(spacing: 0) {
                    ForEach(PageSurfaceKind.allCases, id: \.self) { value in
                        Button { kind = value } label: {
                            Text(value.title).frame(width: 72, height: 26)
                                .background(kind == value ? Color.accentColor.opacity(0.3) : .white.opacity(0.05))
                        }
                        .accessibilityAddTraits(kind == value ? [.isSelected] : [])
                        if value != PageSurfaceKind.allCases.last { Rectangle().fill(.white.opacity(0.16)).frame(width: 1,height: 26) }
                    }
                }.overlay(Rectangle().stroke(.white.opacity(0.2),lineWidth: 1))
            }
            if kind == .sphere {
                HStack(spacing: 8) {
                    Text(L10n.text("page.surface.radius")).foregroundStyle(.secondary).frame(width: 72,alignment: .leading)
                    TextField("",text: $radius).keyboardType(.decimalPad).textFieldStyle(.plain)
                        .focused($radiusFocused).onSubmit(commitRadius)
                        .onChange(of: radiusFocused) { _, focused in if !focused { commitRadius() } }
                        .padding(.horizontal,6).frame(width: 145,height: 26).background(.white.opacity(0.06))
                        .overlay(Rectangle().stroke(.white.opacity(0.18),lineWidth: 1))
                    Text(verbatim: "px").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(L10n.text("page.surface.outsideFill")).foregroundStyle(.secondary).frame(width: 72,alignment: .leading)
                    HStack(spacing: 0) {
                        ForEach(SphereOutsideFill.allCases,id: \.self) { value in
                            Button { outsideFill=value } label: {
                                Text(value.title).frame(width: 48,height: 26)
                                    .background(outsideFill == value ? Color.accentColor.opacity(0.3) : .white.opacity(0.05))
                            }.accessibilityAddTraits(outsideFill == value ? [.isSelected] : [])
                            if value != SphereOutsideFill.allCases.last { Rectangle().fill(.white.opacity(0.16)).frame(width: 1,height: 26) }
                        }
                    }.overlay(Rectangle().stroke(.white.opacity(0.2),lineWidth: 1))
                }
            }
        }.font(.system(size: 12)).buttonStyle(ImmediateButtonStyle())
    }
}

/// A compact, live parameter panel. Valid radius edits commit on focus loss,
/// submit, mode changes, and outside dismissal, rather than on each keystroke.
struct PageSurfacePanel: View {
    @ObservedObject var session: EditorSession
    @State private var radius: String
    private let pageID: UUID
    init(session: EditorSession) {
        self.session=session; pageID=session.page.id
        _radius=State(initialValue: String(format: "%g",session.page.pageSurface.validRadius))
    }
    private func commitRadius() {
        guard session.page.id == pageID else { return }
        guard let value=Double(radius),value.isFinite,(1...1_000_000_000).contains(value) else {
            radius=String(format: "%g",session.page.pageSurface.validRadius); return
        }
        var surface=session.page.pageSurface
        surface.radius=value; session.setPageSurface(surface)
    }
    var body: some View {
        PageSurfaceControls(kind: Binding(get: { session.page.pageSurface.kind },set: { value in
            commitRadius()
            var surface=session.page.pageSurface; surface.kind=value; session.setPageSurface(surface)
        }), radius: $radius, outsideFill: Binding(get: { session.page.pageSurface.outsideFill },set: { value in
            commitRadius()
            var surface=session.page.pageSurface; surface.outsideFill=value; session.setPageSurface(surface)
        }),commitRadius: commitRadius)
            .padding(8).frame(width: 286,alignment: .leading)
            .background(Color(red: 0.16,green: 0.17,blue: 0.18))
            .overlay(Rectangle().stroke(.black,lineWidth: 1))
            .shadow(color: .black.opacity(0.4),radius: 6,y: 3)
            .onDisappear(perform: commitRadius)
    }
}
