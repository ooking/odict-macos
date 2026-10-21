import SwiftUI

struct AISettingsView: View {
    @ObservedObject var model: AISettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group {
                Text("服务连接").font(AppTypography.section)
                field("API 地址", hint: "https://服务地址/v1", text: setting(\.address))
                help("填写兼容 Chat Completions 的基础地址或完整接口地址。本机服务可使用 http://localhost。")
                field("模型名称", hint: "填写服务提供的模型名称", text: setting(\.model))
                Text("API 密钥").font(AppTypography.secondary)
                SecureField("仅保存在本机钥匙串；本机无鉴权服务可留空", text: Binding(get: { model.key }, set: model.updateKey))
                    .disabled(!model.loaded)
                if model.isLoading {
                    HStack { ProgressView().controlSize(.small); help("正在读取钥匙串，请留意系统授权提示…") }
                } else if !model.loaded {
                    Button("读取钥匙串", action: model.load)
                }
                help("与在线词典独立配置。验证连接会发送一小段示例文字，可能产生少量费用。")
                HStack {
                    Button(model.isVerifying ? "正在验证…" : "验证连接", action: model.verify)
                        .disabled(!model.loaded || model.isSaving || model.isVerifying)
                    if model.isVerifying { Button("取消") { model.cancelVerification() }; ProgressView().controlSize(.small) }
                }
                verificationFeedback
            }
            group {
                Text("模型行为").font(AppTypography.section)
                Toggle("启用思考", isOn: setting(\.thinking))
                Picker("思考接口", selection: setting(\.thinkingFormat)) {
                    ForEach(AIThinkingFormat.allCases) { Text($0.title).tag($0) }
                }
                help("自动识别支持 DeepSeek、阿里云百炼，以及本机 11434 端口的 Ollama。其他服务请按其文档选择接口；未识别且关闭思考时不发送思考参数，模型使用服务默认行为。")
                help("启用思考可能更慢、费用更高。只显示最终答案，不展示思考过程。")
            }
            group {
                Text("输出偏好").font(AppTypography.section)
                Picker("翻译方向", selection: setting(\.target)) {
                    ForEach(AITargetLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker("解释语言", selection: setting(\.explanationLanguage)) {
                    ForEach(AITargetLanguage.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
                }
                help("自动互译：中文译成英文，其他语言译成简体中文。目标语言统一在此设置，查询窗口不再单独选择。")
            }
            group {
                Text("提示语").font(AppTypography.section)
                help("调整解释和翻译的内容偏好，直接返回 Markdown 结果，无需约定字段。每份最多 6000 字。")
                prompt("单词 / 短语解释", text: setting(\.wordPrompt), defaultValue: AIConfiguration.defaultWordPrompt)
                Divider()
                prompt("句子翻译", text: setting(\.translationPrompt), defaultValue: AIConfiguration.defaultTranslationPrompt)
            }
            if let message = model.message {
                Label(message, systemImage: model.succeeded ? "checkmark.circle" : "info.circle")
                    .font(AppTypography.secondary).foregroundColor(model.succeeded ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                help("服务配置和提示语修改后需保存。")
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(model.isSaving ? "正在保存…" : "保存 AI 设置", action: model.save)
                    .keyboardShortcut(.defaultAction).disabled(!model.loaded || model.isSaving)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(model.isSaving || model.isLoading)
        .onAppear { model.load() }
        .onDisappear { model.cancelVerification() }
    }
    @ViewBuilder private var verificationFeedback: some View {
        switch model.verificationState {
        case .idle: EmptyView()
        case .checking:
            Text(model.configuration.thinking ? "正在请求模型，思考模式可能需要更长时间…" : "正在验证服务与模型…")
                .font(AppTypography.secondary).foregroundColor(.secondary)
        case .success:
            VStack(alignment: .leading, spacing: 6) {
                Label("连接成功，模型已返回有效结果。", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                help("当前修改仍需点击「保存 AI 设置」后生效。")
            }.font(AppTypography.secondary)
        case .failure(let reason):
            Label("验证失败：" + reason, systemImage: "exclamationmark.circle.fill")
                .font(AppTypography.secondary).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Label("已取消验证。", systemImage: "info.circle")
                .font(AppTypography.secondary).foregroundColor(.secondary)
        }
    }
    private func setting<Value: Equatable>(_ path: WritableKeyPath<AIConfiguration, Value>) -> Binding<Value> {
        Binding(get: { model.configuration[keyPath: path] }, set: { model.update(path, value: $0) })
    }
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func help(_ text: String) -> some View {
        Text(text).font(AppTypography.secondary).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(AppTypography.secondary)
            TextField(hint, text: text).disabled(!model.loaded)
        }
    }
    private func prompt(_ title: String, text: Binding<String>, defaultValue: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(AppTypography.navigation)
                Spacer()
                Button("恢复默认") { text.wrappedValue = defaultValue }
                    .controlSize(.small).disabled(text.wrappedValue == defaultValue)
            }
            TextEditor(text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(AIConfiguration.maximumPrompt)) }))
                .font(AppTypography.body).frame(height: 110).padding(6)
                .background(Color(nsColor: .textBackgroundColor)).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel(title + "提示语")
        }
    }
}
