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
                        Text(source.kind == .system ? (source.systemVoiceIdentifier.isEmpty ? "自动选择本机语音" : "使用已配置的语音角色") : source.template).font(AppTypography.caption).foregroundColor(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("启用 \(source.name)", isOn: Binding(get: { source.enabled }, set: { enabled in
                        var updated = source; updated.enabled = enabled
                        save(updated)
                    })).labelsHidden().toggleStyle(.switch)
                    PronunciationTestButton(source: source)
                    Button("编辑") { draft = source }
                    Button { do { try store.remove(source) } catch { message = error.localizedDescription } } label: {
                        Image(systemName: "trash")
                    }.help("删除 \(source.name)").accessibilityLabel("删除 \(source.name)")
                }
                Divider()
            }
            if store.sources.isEmpty { Text("尚未添加发音来源。添加并启用后，可从窗口底部播放。").foregroundColor(.secondary) }
            Button("添加来源") {
                draft = store.newSource()
            }.disabled(store.sources.count >= PronunciationSettingsStore.maximumSources)
            Text("{text} 会替换为输入框的原始完整内容，并自动进行 URL 编码。点击发音时，这些文字将发送到所选来源。远程来源支持 HTTPS 音频地址，系统语音使用本机语音。")
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
            Picker("来源类型", selection: $source.kind) {
                ForEach(PronunciationSource.Kind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            if source.kind == .remote {
                Text("URL 模板").font(AppTypography.secondary)
                TextField("https://example.com/audio?text={text}", text: $source.template)
                Text("使用 {text} 表示单词、短语或句子的完整输入。")
                    .font(AppTypography.caption).foregroundColor(.secondary)
            } else {
                SystemSpeechOptions(source: $source)
            }
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
                PronunciationTestButton(source: source)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(source); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(source.validationMessage != nil)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
    }
}

/// A preview has its own ownership, but shares the app's playback service so a
/// preview always replaces the previous audio. Disabled sources can be auditioned.
private struct PronunciationTestButton: View {
    let source: PronunciationSource
    @ObservedObject private var playback = PronunciationService.shared
    @State private var owner = UUID()

    private var state: PronunciationService.State { playback.owner == owner ? playback.state : .idle }
    private var active: Bool { state == .loading || state == .playing }

    var body: some View {
        Button {
            if active { playback.stop(owner: owner) }
            else {
                var preview = source
                preview.enabled = true
                playback.play(source: preview, text: PronunciationService.previewText, owner: owner)
            }
        } label: {
            ZStack {
                if state == .loading { ProgressView().controlSize(.small).scaleEffect(0.65) }
                else {
                    Image(systemName: state == .playing ? "stop.fill" : state == .error ? "exclamationmark.circle" : "play.fill")
                        .font(.system(size: 13))
                }
            }.frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(state == .error ? Color.red : active ? Color.accentColor : Color.secondary)
        .disabled(source.validationMessage != nil)
        .help(state == .error ? (playback.errorMessage ?? "试听失败，点击重试") : active ? "停止试听" : "试听 hello")
        .accessibilityLabel(active ? "停止试听" : "试听 \(source.name)，朗读 hello")
        .accessibilityValue(state == .loading ? "加载中" : state == .playing ? "播放中" : state == .error ? "播放失败" : "未播放")
        .accessibilityHint(state == .error ? (playback.errorMessage ?? "点击重试") : "")
        .onChange(of: source) { _ in playback.stop(owner: owner) }
        .onDisappear { playback.stop(owner: owner) }
    }
}

/// Voice metadata exists only while editing a system source. Gender is reported
/// by macOS; voices without metadata remain available under “不限”.
private struct SystemSpeechOptions: View {
    @Binding var source: PronunciationSource
    @State private var voices: [SystemSpeechVoice] = []

    private var languages: [String] {
        Array(Set(voices.map(\.language))).sorted {
            SystemSpeechVoice.languageTitle($0).localizedStandardCompare(SystemSpeechVoice.languageTitle($1)) == .orderedAscending
        }
    }
    private var matchingVoices: [SystemSpeechVoice] { voices.filter { $0.matches(source) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("语言", selection: $source.systemLanguage) {
                Text("自动识别文字语言").tag("")
                ForEach(languages, id: \.self) { language in
                    Text(SystemSpeechVoice.languageTitle(language)).tag(language)
                }
                if !source.systemLanguage.isEmpty && !languages.contains(source.systemLanguage) {
                    Text("未安装：\(SystemSpeechVoice.languageTitle(source.systemLanguage))").tag(source.systemLanguage)
                }
            }
            HStack {
                Text("声音")
                Picker("声音", selection: $source.systemVoiceGender) {
                    ForEach(PronunciationSource.VoiceGender.allCases) { gender in Text(gender.title).tag(gender) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Picker("角色", selection: $source.systemVoiceIdentifier) {
                Text("自动选择").tag("")
                ForEach(matchingVoices) { voice in Text(voice.title).tag(voice.id) }
                if !source.systemVoiceIdentifier.isEmpty && !matchingVoices.contains(where: { $0.id == source.systemVoiceIdentifier }) {
                    Text("所选角色当前不可用").tag(source.systemVoiceIdentifier)
                }
            }
            HStack {
                Text("语速")
                Slider(value: $source.systemRate, in: 0.5...1.5, step: 0.05)
                    .accessibilityLabel("系统语音语速")
                Text("\(source.systemRate, specifier: "%.2f")×").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            if matchingVoices.isEmpty {
                Text("没有符合当前语言和声音选项的已安装语音，请调整选项或下载更多语音。")
                    .font(AppTypography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("角色来自本机已安装的语音；性别以系统提供的信息为准。可在系统设置的「辅助功能」中下载更多语音，然后刷新列表。试听固定朗读 hello。")
                .font(AppTypography.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("刷新语音列表") { voices = SystemSpeechVoice.installed() }
        }
        .onAppear { voices = SystemSpeechVoice.installed() }
        .onChange(of: source.systemLanguage) { _ in source.systemVoiceIdentifier = "" }
        .onChange(of: source.systemVoiceGender) { _ in source.systemVoiceIdentifier = "" }
    }
}
