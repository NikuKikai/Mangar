import SwiftUI

struct ApplicationSettingsView: View {
    let close: () -> Void
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: close) {
                    MangarLogoMark().frame(width: 22, height: 22).frame(width: 25, height: 24)
                }.accessibilityLabel(L10n.text("settings.close"))
                Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 3)
                Text(L10n.text("settings.title"))
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 24) }
                    .accessibilityLabel(L10n.text("settings.close"))
            }
            .font(.system(size: 13)).padding(.horizontal, 4).frame(height: 34)
            .background(Color(red: 0.18, green: 0.19, blue: 0.20))
            Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("settings.language")).font(.system(size: 12, weight: .semibold))
                    VStack(spacing: 1) {
                        ForEach(AppLanguage.allCases, id: \.self) { choice in
                            Button { language = choice.rawValue } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: language == choice.rawValue ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(language == choice.rawValue ? Color.accentColor : .secondary)
                                        .frame(width: 16)
                                    Text(choice.name).font(.system(size: 12))
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 7).frame(height: 30)
                                    .background(language == choice.rawValue ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.04))
                                    .contentShape(Rectangle())
                            }.accessibilityAddTraits(language == choice.rawValue ? [.isSelected] : [])
                        }
                    }.overlay(Rectangle().stroke(.white.opacity(0.15), lineWidth: 1))
                    Text(L10n.text("settings.language.note"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: 420, alignment: .leading).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .buttonStyle(ImmediateButtonStyle()).preferredColorScheme(.dark)
        .immediateUI()
    }
}
