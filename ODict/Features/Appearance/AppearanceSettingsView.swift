import AppKit
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var store = ReadingAppearanceStore.shared
    @State private var editing: FontLanguage?

    private enum FontLanguage: String, Identifiable {
        case english = "英文字体", chinese = "中文字体"
        var id: Self { self }
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 18) {
                group("自定义字体") {
                    fontRow(.english, name: store.value.english)
                    Divider()
                    fontRow(.chinese, name: store.value.chinese)
                }
                group("翻译结果排版") {
                    HStack(spacing: 14) {
                        Text("字号").frame(width: 40, alignment: .leading)
                        Slider(value: binding(\.size), in: ReadingAppearance.sizeRange, step: 1)
                            .accessibilityLabel("阅读字号")
                        Text("\(Int(store.value.size)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    HStack(spacing: 14) {
                        Text("行高").frame(width: 40, alignment: .leading)
                        Slider(value: binding(\.lineHeight), in: ReadingAppearance.lineHeightRange, step: 0.1)
                            .accessibilityLabel("阅读行高倍数")
                        Text("\(store.value.lineHeight, specifier: "%.1f") 倍").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    note("字号和行高用于在线释义及 AI 翻译结果，输入框、历史记录保持固定大小。本地词典的字体和字号由下方开关控制。")
                }
                group("本地词典") {
                    Toggle("使用外观中的字体和字号", isOn: Binding(
                        get: { store.value.useForLocalDictionaries },
                        set: { enabled in store.update { $0.useForLocalDictionaries = enabled } }
                    )).toggleStyle(.switch)
                    note("对所有本地词典生效，仅替换全局字体和字号，保留词典为特定内容单独设置的字体、字号。与各词典的「覆盖样式」开关相互独立。")
                }
            }
        } actions: {
            HStack {
                note("更改自动保存并生效。")
                Spacer()
                Button("恢复默认") { store.update { $0 = .defaults } }
                    .disabled(store.value == .defaults)
            }
        }
        .sheet(item: $editing) { language in
            InstalledFontPicker(title: language.rawValue,
                                selection: language == .english ? store.value.english : store.value.chinese,
                                chinese: language == .chinese) { name in
                store.update {
                    if language == .english { $0.english = name } else { $0.chinese = name }
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ReadingAppearance, Double>) -> Binding<Double> {
        Binding(get: { store.value[keyPath: keyPath] }, set: { value in store.update { $0[keyPath: keyPath] = value } })
    }

    private func fontRow(_ language: FontLanguage, name: String) -> some View {
        HStack {
            Text(language.rawValue)
            Spacer()
            Button { editing = language } label: {
                HStack(spacing: 8) {
                    Text(ReadingAppearance.title(for: name, chinese: language == .chinese)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }.frame(maxWidth: 290, alignment: .trailing)
            }
            .accessibilityLabel("选择\(language.rawValue)")
            .accessibilityValue(ReadingAppearance.title(for: name, chinese: language == .chinese))
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(AppTypography.section)
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(AppTypography.secondary).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Font metadata lives only for the lifetime of this sheet. No font panel
/// delegates, global event listeners, or retained font catalog are required.
private struct InstalledFontPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let selection: String
    let chinese: Bool
    let choose: (String) -> Void
    @State private var search = ""
    @State private var families: [String] = []

    private var matching: [String] {
        search.isEmpty ? families : families.filter { $0.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(AppTypography.section)
            TextField("搜索已安装的字体", text: $search).textFieldStyle(.roundedBorder)
            List {
                row("", title: chinese ? "系统中文字体" : "系统字体（SF Pro）")
                if !chinese { row("system-serif", title: "系统衬线字体（New York）") }
                ForEach(matching, id: \.self) { row($0, title: $0) }
                if matching.isEmpty { Text("没有匹配的已安装字体").foregroundColor(.secondary) }
            }
            Text("缺失的字符会自动使用系统字体。字体列表仅包含本机已安装的字体。")
                .font(AppTypography.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 440, height: 460)
            .onAppear {
                families = NSFontManager.shared.availableFontFamilies.filter {
                    !$0.hasPrefix(".") && (!chinese || ReadingAppearance.supportsChinese($0))
                }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
    }

    private func row(_ name: String, title: String) -> some View {
        Button { choose(name); dismiss() } label: {
            HStack {
                Text(title)
                Spacer()
                if selection == name || (!selection.isEmpty && name != "" && ReadingAppearance.installedFont(selection, size: 14)?.familyName == name) {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }.contentShape(Rectangle()).padding(.vertical, 4)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
