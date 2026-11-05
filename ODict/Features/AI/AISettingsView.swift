import SwiftUI

struct AISettingsView: View {
    @ObservedObject var model: AISettingsModel
    @State private var showsKey = false
    @State private var profileToDelete: AIServiceProfile?
    @State private var showsEditor = false
    @State private var isAddingProfile = false
    var body: some View {
        SettingsPage {
            settingsContent
        } actions: {
            settingsActions
        }
        .textFieldStyle(.roundedBorder)
        .disabled(model.isSaving || model.isLoading)
        .onAppear { model.load() }
        .onDisappear { showsKey = false; model.cancelVerification(); model.cancelModels() }
        .onChange(of: model.selectedID) { _ in showsKey = false }
        .sheet(isPresented: $showsEditor, onDismiss: model.cancelEditingProfile) {
            profileEditor
        }
        .alert("删除「\(profileToDelete?.name ?? "")」？", isPresented: Binding(
            get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }), presenting: profileToDelete) { profile in
            Button("取消", role: .cancel) { profileToDelete = nil }
            Button("删除", role: .destructive) {
                model.removeProfile(profile.id); profileToDelete = nil
            }
        } message: { profile in
            Text(profile.id == model.activeID
                 ? "保存后删除此接口及其密钥，并将首个剩余接口设为默认。公共设置会保留。"
                 : "保存后删除此接口及其密钥。公共设置会保留。")
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            serviceSettings
            sharedSettings
        }
    }

    private var serviceSettings: some View {
        group {
            HStack {
                Text("AI 接口").font(AppTypography.section)
                Spacer()
                Button("添加接口") {
                    isAddingProfile = true
                    model.beginAddingProfile(); showsEditor = true
                }
                .disabled(!model.loaded || model.profiles.count >= AISettingsStore.maximumProfiles)
            }
            help("查询使用默认接口。添加、编辑、删除或更换默认后，点击底部保存生效。")
            serviceTable
            if model.isLoading {
                HStack { ProgressView().controlSize(.small); help("正在读取钥匙串…") }
            } else if !model.loaded {
                Button("重新读取钥匙串", action: model.load)
            }
        }
    }

    private var serviceTable: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("接口").frame(maxWidth: .infinity, alignment: .leading)
                    Text("模型名称").frame(width: 100, alignment: .leading)
                    Text("思考").frame(width: 44, alignment: .leading)
                    Text("操作").frame(width: 172, alignment: .leading)
                }.font(AppTypography.secondary).foregroundColor(.secondary)
                Divider()
                ForEach(model.profiles) { profile in
                    profileRow(profile)
                    if profile.id != model.profiles.last?.id { Divider() }
                }
            }.frame(minWidth: 530, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileRow(_ profile: AIServiceProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "未命名接口" : profile.name)
                        .font(AppTypography.navigation).lineLimit(1)
                    if profile.id == model.activeID {
                        Text(model.activeID == model.savedActiveID ? "默认" : "默认 · 待保存")
                            .font(.caption).foregroundColor(.accentColor).fixedSize()
                    }
                }
                Text(profile.configuration.address.isEmpty ? "尚未配置地址" : profile.configuration.address)
                    .font(AppTypography.secondary).foregroundColor(.secondary)
                    .lineLimit(2).help(profile.configuration.address)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(profile.configuration.model.isEmpty ? "尚未选择" : profile.configuration.model)
                .font(AppTypography.secondary).lineLimit(2)
                .frame(width: 100, alignment: .leading).help(profile.configuration.model)
            Text(profile.configuration.thinking ? "启用" : "关闭")
                .font(AppTypography.secondary)
                .foregroundColor(profile.configuration.thinking ? .primary : .secondary)
                .frame(width: 44, alignment: .leading)
                .accessibilityLabel("思考" + (profile.configuration.thinking ? "已启用" : "已关闭"))
            HStack(spacing: 8) {
                Button("编辑") {
                    isAddingProfile = false
                    model.beginEditingProfile(profile.id); showsEditor = true
                }
                Button("删除") { profileToDelete = profile }
                    .disabled(model.profiles.count <= 1)
                Button("设为默认") { model.setDefaultProfile(profile.id) }
                    .disabled(profile.id == model.activeID)
            }.controlSize(.small).fixedSize().frame(width: 172, alignment: .leading)
        }.padding(.vertical, 4)
    }

    private var profileEditor: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 14) {
                Text(isAddingProfile ? "添加 AI 接口" : "编辑 AI 接口").font(AppTypography.section)
                help("此处仅设置这个接口。翻译方向、解释语言和提示语在列表下方的公共设置中调整。")
                field("接口名称", hint: "例如：本地模型", text: Binding(
                    get: { model.profiles.first(where: { $0.id == model.selectedID })?.name ?? "" }, set: model.rename))
                field("API 地址", hint: "https://服务地址/v1", text: setting(\.address))
                help("兼容 Chat Completions 的基础地址或完整接口地址。")
                keyField
                modelField
                if let message = model.modelsMessage { help(message) }
                HStack {
                    Button(model.isVerifying ? "正在验证…" : "验证连接", action: model.verify)
                        .disabled(!model.loaded || model.isVerifying)
                    if model.isVerifying {
                        ProgressView().controlSize(.small)
                        Button("取消") { model.cancelVerification() }
                    }
                }
                help("验证当前填写的配置，会发送示例文字，可能产生少量费用。")
                verificationFeedback
                Divider()
                DisclosureGroup("思考与连接说明") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用思考", isOn: setting(\.thinking))
                        Picker("思考接口", selection: setting(\.thinkingFormat)) {
                            ForEach(AIThinkingFormat.allCases) { Text($0.title).tag($0) }
                        }
                        help("思考设置仅影响此配置。自动识别支持 DeepSeek、百炼和本机 11434 端口的 Ollama；其他服务可手动选择接口。启用思考可能更慢、费用更高。")
                        help("本机和局域网可用 HTTP，例如 http://192.168.1.90:9000/v1。HTTP 不加密，请仅用于可信网络。密钥只保存在本机钥匙串，与在线词典独立。")
                    }.padding(.top, 10)
                }.font(AppTypography.secondary)
            }
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                if let message = model.message, !model.succeeded {
                    Text(message).font(AppTypography.secondary).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    help("完成编辑后，回到列表保存所有更改。")
                    Spacer()
                    Button("取消") { model.cancelEditingProfile(); showsEditor = false }
                        .keyboardShortcut(.cancelAction)
                    Button("完成") {
                        if model.finishEditingProfile() { showsEditor = false }
                    }
                    .keyboardShortcut(.defaultAction).disabled(!model.loaded || model.isLoading)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 580, height: 620)
        .onDisappear { showsKey = false; model.cancelModels(); model.cancelVerification() }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("API 密钥").font(AppTypography.secondary)
            HStack {
                Group {
                    if showsKey {
                        TextField("无鉴权服务可留空", text: Binding(get: { model.key }, set: model.updateKey))
                    } else {
                        SecureField("无鉴权服务可留空", text: Binding(get: { model.key }, set: model.updateKey))
                    }
                }.disabled(!model.loaded)
                Button { showsKey.toggle() } label: {
                    Image(systemName: showsKey ? "eye.slash" : "eye")
                }
                .accessibilityLabel(showsKey ? "隐藏密钥" : "显示密钥原文")
                .help(showsKey ? "隐藏密钥" : "显示密钥原文")
                .disabled(!model.loaded)
            }
            if model.isLoading {
                HStack { ProgressView().controlSize(.small); help("正在读取钥匙串…") }
            } else if !model.loaded {
                Button("读取钥匙串", action: model.load)
            }
        }
    }

    private var modelField: some View {
        HStack(spacing: 8) {
            Text("模型名称").font(AppTypography.secondary).fixedSize()
            TextField("填写或选择模型", text: setting(\.model))
                .accessibilityLabel("模型名称").disabled(!model.loaded)
            Button(model.isFetchingModels ? "取消获取" : "获取模型") {
                if model.isFetchingModels { model.cancelModels() } else { model.fetchModels() }
            }
            .disabled(!model.loaded || model.configuration.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .fixedSize()
            Menu("选择模型") {
                ForEach(model.availableModels, id: \.self) { name in
                    Button(name) { model.update(\.model, value: name) }
                }
            }
            .fixedSize()
            .disabled(model.availableModels.isEmpty || model.isFetchingModels)
        }
    }

    private var sharedSettings: some View {
        group {
            Text("公共设置").font(AppTypography.section)
            help("所有服务配置共用，切换服务时保持不变。")
            Picker("翻译方向", selection: sharedSetting(\.target)) {
                ForEach(AITargetLanguage.allCases) { Text($0.title).tag($0) }
            }
            Picker("解释语言", selection: sharedSetting(\.explanationLanguage)) {
                ForEach(AITargetLanguage.allCases.filter { $0 != .automatic }) { Text($0.title).tag($0) }
            }
            help("自动互译：中文译成英文，其他语言译成简体中文。")
            Divider()
            DisclosureGroup("提示语 · 所有配置共用") {
                VStack(alignment: .leading, spacing: 16) {
                    prompt("单词 / 短语解释", text: sharedSetting(\.wordPrompt), defaultValue: AIConfiguration.defaultWordPrompt)
                    prompt("句子翻译", text: sharedSetting(\.translationPrompt), defaultValue: AIConfiguration.defaultTranslationPrompt)
                    help("每份最多 6000 字，直接返回 Markdown 结果。")
                }.padding(.top, 12)
            }.font(AppTypography.secondary)
        }
    }

    private var settingsActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Label(message, systemImage: model.succeeded ? "checkmark.circle" : "info.circle")
                    .font(AppTypography.secondary).foregroundColor(model.succeeded ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                help(model.hasChanges ? "有未保存的更改 · 保存后统一生效" : "更改保存后统一生效")
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(model.isSaving ? "正在保存…" : "保存所有更改", action: model.save)
                    .keyboardShortcut(.defaultAction).disabled(!model.loaded || model.isSaving)
            }
        }
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
                help("验证不会保存配置，请点击「保存所有更改」使修改生效。")
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
    private func sharedSetting<Value: Equatable>(_ path: WritableKeyPath<AISharedPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.shared[keyPath: path] }, set: { model.updateShared(path, value: $0) })
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
