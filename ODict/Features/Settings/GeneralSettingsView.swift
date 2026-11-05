import SwiftUI

struct GeneralSettingsView: View {
    @State private var options = LookupSourceSettings().load()
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 12) {
                Text("查询顺序").font(AppTypography.section)
                Text("按从上到下的顺序使用已启用的来源，命中后停止。AI 在确认查询后才会请求；输入和候选预览不会自动发送给 AI。独立 AI 模式仍可手动使用。")
                    .font(AppTypography.secondary).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    HStack {
                        Toggle(option.source.title, isOn: Binding(get: { option.enabled }, set: { enabled in
                            options[index].enabled = enabled
                            LookupSourceSettings().save(options)
                        }))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("提高优先级").accessibilityLabel("提高优先级")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == options.count - 1).help("降低优先级").accessibilityLabel("降低优先级")
                    }
                    .padding(10).background(Color.primary.opacity(0.035)).cornerRadius(8)
                }
                Text("设置自动保存，下次查询生效。系统词典的启用状态与「本地词典」页面同步；各本 MDX 的内部顺序仍在「本地词典」中调整。若将 AI 排在前面，确认查询时会优先使用 AI；请先在 AI 设置中完成配置。")
                    .font(AppTypography.secondary).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalDictionaryStore.changed)) { _ in
            options = LookupSourceSettings().load()
        }
    }
    private func move(_ index: Int, by delta: Int) {
        guard options.indices.contains(index + delta) else { return }
        options.swapAt(index, index + delta)
        LookupSourceSettings().save(options)
    }
}
