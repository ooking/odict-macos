import SwiftUI

/// A lightweight empty state: no services, permission requests or connection
/// checks are started until the user chooses a setup destination.
struct LookupWelcomeView: View {
    let openSetup: (SettingsCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("第一次查词，从这里开始")
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                HStack(alignment: .top, spacing: 14) {
                    sourceIcon("network", color: .accentColor)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("连接在线词典").font(AppTypography.section)
                        Text("无需导入词典，联网即可查词。")
                            .font(AppTypography.secondary).foregroundColor(lookupSecondaryInk)
                        Text("也可用中文找英文单词")
                            .font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                        Button("连接在线词典") { openSetup(.service) }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                }

                Divider()
                Text("也可以选择")
                    .font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                sourceRow(icon: "book", color: .accentColor, title: "本地词典",
                          detail: "导入 MDX 2.0 词典，离线查词更方便", action: "添加本地词典", destination: .dictionaries)
                sourceRow(icon: "sparkles", color: .purple, title: "AI 翻译与解释",
                          detail: "结合语境讲解词义，让句子和用法更易懂", action: "配置 AI", destination: .ai)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("本地优先查询，未收录时使用在线词典。\n无需全部配置，选择适合你的方式。")
                        .font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { openSetup(.capture) } label: {
                        HStack(spacing: 5) {
                            Text("了解取词与快捷键")
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.link).font(AppTypography.caption)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 23, weight: .regular))
            .foregroundColor(color)
            .frame(width: 46, height: 46)
            .background(color.opacity(0.10))
            .cornerRadius(10)
            .accessibilityHidden(true)
    }

    private func sourceRow(icon: String, color: Color, title: String, detail: String,
                           action: String, destination: SettingsCategory) -> some View {
        HStack(alignment: .center, spacing: 14) {
            sourceIcon(icon, color: color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(AppTypography.navigation)
                Text(detail).font(AppTypography.secondary).foregroundColor(lookupSecondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action) { openSetup(destination) }
                .buttonStyle(.bordered)
        }
    }
}
