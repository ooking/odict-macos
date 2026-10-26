import SwiftUI
import AppKit

extension PronunciationSource {
    var iconColor: Color {
        let rgb = UInt32(colorHex, radix: 16) ?? 0x3478F6
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct PronunciationSettingsView: View {
    @ObservedObject private var store = PronunciationSettingsStore.shared
    @State private var draft: PronunciationSource?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.sources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(source.iconColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.name).font(AppTypography.section)
                        Text(source.template).font(AppTypography.caption).foregroundColor(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("启用 \(source.name)", isOn: Binding(get: { source.enabled }, set: { enabled in
                        var updated = source; updated.enabled = enabled
                        save(updated)
                    })).labelsHidden().toggleStyle(.switch)
                    Button("编辑") { draft = source }
                    Button { do { try store.remove(source) } catch { message = error.localizedDescription } } label: {
                        Image(systemName: "trash")
                    }.help("删除 \(source.name)").accessibilityLabel("删除 \(source.name)")
                }
                Divider()
            }
            if store.sources.isEmpty { Text("尚未添加发音来源。添加并启用后，可从窗口底部播放。").foregroundColor(.secondary) }
            Button("添加来源") {
                draft = PronunciationSource(name: "", template: "https://", colorHex: "3478F6")
            }.disabled(store.sources.count >= PronunciationSettingsStore.maximumSources)
            Text("{text} 会替换为输入框的原始完整内容，并自动进行 URL 编码。点击发音时，这些文字将发送到所选来源。支持 HTTPS 音频地址。")
                .font(AppTypography.secondary).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = message { Text(message).foregroundColor(.red) }
        }
        .sheet(item: $draft) { source in
            PronunciationSourceEditor(source: source) { updated in save(updated) }
        }
    }

    private func save(_ source: PronunciationSource) {
        do { try store.save(source); message = nil }
        catch { message = error.localizedDescription }
    }
}

private struct PronunciationSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: PronunciationSource
    let save: (PronunciationSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发音来源").font(AppTypography.pageTitle)
            TextField("名称", text: $source.name)
            Text("URL 模板").font(AppTypography.secondary)
            TextField("https://example.com/audio?text={text}", text: $source.template)
            Text("使用 {text} 表示单词、短语或句子的完整输入。")
                .font(AppTypography.caption).foregroundColor(.secondary)
            ColorPicker("图标颜色", selection: Binding(get: { source.iconColor }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                source.colorHex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                    Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            }), supportsOpacity: false)
            Toggle("启用此来源", isOn: $source.enabled)
            if let message = source.validationMessage {
                Text(message).font(AppTypography.caption).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(source); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(source.validationMessage != nil)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
    }
}
