import SwiftUI
import KeyboardShortcuts
import AppKit

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case capture = "取词方式"
    case dictionaries = "词典管理"
    case history = "查询历史"
    case service = "在线词典"
    case ai = "AI"
    case privacy = "权限与隐私"
    case about = "关于"

    var id: Self { self }
    var icon: String {
        switch self {
        case .capture: return "text.cursor"
        case .dictionaries: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .service: return "network"
        case .ai: return "sparkles"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .capture: return "选择一种方式，了解用法并按需开启。"
        case .dictionaries: return "管理本地词典、查询顺序和词典资源。"
        case .history: return "设置词典和 AI 的历史保留数量。"
        case .service: return "连接在线词典，补充本地未收录的内容。"
        case .ai: return "独立配置 AI，解释单词与短语，翻译句子。"
        case .privacy: return "管理取词所需的系统权限，了解数据如何使用。"
        case .about: return "了解 ODict、开发者与开源许可。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    // Retain the lightweight configuration across category switches, including
    // import status. The child cancels pending discovery when it disappears.
    @StateObject private var dictionaryModel = LocalDictionarySettingsModel()
    @AppStorage(CaptureMethod.selection.preferenceKey) private var selectionEnabled = false
    @AppStorage(CaptureMethod.screenshot.preferenceKey) private var screenshotEnabled = false
    @AppStorage(CaptureMethod.hover.preferenceKey) private var hoverEnabled = false
    @AppStorage(HoverTrigger.preferenceKey) private var hoverTrigger = HoverTrigger.control.rawValue
    @AppStorage(QueryMode.captureKey) private var captureMode = QueryMode.dictionary.rawValue
    @AppStorage(LookupCacheSettings.capacityKey) private var cacheCapacity = LookupCacheSettings.defaultCapacity
    @State private var cacheCapacityDraft = String(LookupCacheSettings.capacity(in: .standard))
    @State private var historyCapacityDraft = String(AIHistorySettings.capacity())
    @State private var historyCapacityMessage: String?
    @State private var category = SettingsCategory.capture
    @State private var selectedCaptureMethod = CaptureMethod.selection
    @State private var accessibilityAllowed = false
    @State private var screenAllowed = false
    @State private var screenAuthorizationRequested = false
    @State private var showCaptureAuthorization = false
    @State private var authorizationMethod: CaptureMethod?
    @State private var pendingAuthorization: Set<CaptureMethod> = []

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.rawValue).font(AppTypography.pageTitle)
                        Text(category.subtitle).font(AppTypography.secondary).foregroundColor(.secondary)
                    }
                    categoryContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(category)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .font(AppTypography.body)
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { refreshPermissions(); if model.showAI { category = .ai } }
        .onChange(of: model.showAI) { value in if value { category = .ai } }
        .alert("\(authorizationMethod?.title ?? "取词")需要\(authorizationMethod?.permissionTitle ?? "系统")权限",
               isPresented: $showCaptureAuthorization, presenting: authorizationMethod) { method in
            Button("前往授权") {
                pendingAuthorization.insert(method)
                authorizePermission(screenRecording: method.usesScreenPermission)
            }
            Button("取消", role: .cancel) { pendingAuthorization.remove(method) }
        } message: { method in
            Text("请在系统设置的「隐私与安全性 → \(method.permissionTitle)」中允许 ODict。授权后返回，将自动开启\(method.title)。" + (method.usesScreenPermission ? "若系统提示需要重新打开应用，请重开后再次开启。" : ""))
        }
        .onChange(of: hoverEnabled) { _ in notifyHoverPreferenceChanged() }
        .onChange(of: cacheCapacity) { _ in
            NotificationCenter.default.post(name: LookupCacheSettings.changed, object: nil)
        }
        .onChange(of: hoverTrigger) { _ in notifyHoverPreferenceChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置").font(AppTypography.section).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
            ForEach(SettingsCategory.allCases.filter { $0 != .about }) { item in
                categoryButton(item)
            }
            Spacer()
            categoryButton(.about)
        }
        .padding(12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func categoryButton(_ item: SettingsCategory) -> some View {
        Button { category = item } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon).font(.system(size: 17, weight: .medium)).frame(width: 22)
                Text(item.rawValue).font(AppTypography.navigation)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .foregroundColor(category == item ? .white : .primary)
            .background(category == item ? Color.accentColor : Color.clear)
            .cornerRadius(9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(category == item ? .isSelected : [])
    }

    @ViewBuilder private var categoryContent: some View {
        switch category {
        case .capture: captureSettings
        case .dictionaries:
            settingsGroup { LocalDictionarySettingsView(model: dictionaryModel) }
        case .history: historySettings
        case .service: serviceSettings.onAppear { model.load() }
        case .ai: AISettingsView(model: model.ai)
        case .privacy: privacySettings
        case .about: AboutSettingsView()
        }
    }

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("查看取词方式", selection: $selectedCaptureMethod) {
                ForEach(CaptureMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            captureMethodSettings(selectedCaptureMethod)
            settingsGroup {
                Text("通用设置").font(AppTypography.section)
                HStack {
                    Text("取词后使用")
                    Spacer()
                    Picker("取词后使用", selection: $captureMode) {
                        ForEach(QueryMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }
                helpText("三种取词方式共用此模式，不会自动切换兜底；手动查询窗口单独记住上次模式。")
                Divider()
                shortcutRow("唤出 / 收起词典", name: .toggleDictionary)
                helpText("设置自动保存。点击快捷键框后按组合键，按删除键清除。")
            }
        }
    }

    private var historySettings: some View {
        settingsGroup {
            HStack {
                Text("词典")
                Spacer()
                TextField("词典保留数量", text: Binding(get: { cacheCapacityDraft }, set: {
                    cacheCapacityDraft = $0; historyCapacityMessage = nil
                }))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit(saveHistoryCapacity)
                Text("条").foregroundColor(.secondary)
                Stepper("词典保留数量", value: Binding(get: {
                    Int(cacheCapacityDraft) ?? LookupCacheSettings.capacity(in: .standard)
                }, set: { cacheCapacityDraft = String($0); historyCapacityMessage = nil }),
                    in: LookupCacheSettings.capacityRange)
                    .labelsHidden().fixedSize()
            }
            helpText("默认 20 条，可设为 0–100 条；0 表示不保留。")
            Divider()
            HStack {
                Text("AI")
                Spacer()
                TextField("AI 保留数量", text: Binding(get: { historyCapacityDraft }, set: {
                    historyCapacityDraft = $0; historyCapacityMessage = nil
                }))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
                    .onSubmit(saveHistoryCapacity)
                Text("条").foregroundColor(.secondary)
                Stepper("AI 保留数量", value: Binding(get: {
                    Int(historyCapacityDraft) ?? AIHistorySettings.capacity()
                }, set: { historyCapacityDraft = String($0); historyCapacityMessage = nil }),
                    in: AIHistorySettings.capacityRange).labelsHidden().fixedSize()
            }
            helpText("默认 20 条，可设为 1–100 条。")
            Divider()
            helpText("超出数量时移除较早记录。AI 回答保存在本机，无需重新生成。")
            HStack {
                Button("保存", action: saveHistoryCapacity)
                if let message = historyCapacityMessage { helpText(message) }
            }
        }
    }

    private func saveHistoryCapacity() {
        guard let dictionaryCount = Int(cacheCapacityDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              LookupCacheSettings.capacityRange.contains(dictionaryCount) else {
            historyCapacityMessage = "词典数量请输入 0–100 之间的整数。"; return
        }
        guard let value = Int(historyCapacityDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              AIHistorySettings.capacityRange.contains(value) else {
            historyCapacityMessage = "AI 数量请输入 1–100 之间的整数。"; return
        }
        cacheCapacity = dictionaryCount
        cacheCapacityDraft = String(dictionaryCount)
        UserDefaults.standard.set(value, forKey: AIHistorySettings.capacityKey)
        historyCapacityDraft = String(value)
        historyCapacityMessage = "已保存。"
        NotificationCenter.default.post(name: AIHistorySettings.changed, object: nil)
    }

    private func captureInstruction(_ method: CaptureMethod) -> String {
        method.guideInstruction(hoverTrigger: HoverTrigger(rawValue: hoverTrigger) ?? .control)
    }

    private func captureMethodSettings(_ method: CaptureMethod) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            CaptureMethodGuide(method: method, instruction: captureInstruction(method))

            settingsGroup {
                HStack {
                    Text("启用\(method.title)").font(AppTypography.section)
                    Spacer()
                    Toggle("启用\(method.title)", isOn: captureEnabledBinding(method))
                        .labelsHidden().toggleStyle(.switch)
                }
                helpText("默认关闭。开启需要\(method.permissionTitle)权限。")
                if pendingAuthorization.contains(method) {
                    HStack {
                        helpText("等待授权，授权后返回此处将自动开启。")
                        Button("取消开启") { pendingAuthorization.remove(method) }
                    }
                }
                if isCaptureEnabled(method) || pendingAuthorization.contains(method) {
                    permissionRow(method.permissionTitle, allowed: permissionAllowed(method), screenRecording: method.usesScreenPermission) {
                        authorizePermission(screenRecording: method.usesScreenPermission)
                    }
                }
                if isCaptureEnabled(method) {
                    Divider()
                    if method == .selection {
                        shortcutRow("取词快捷键", name: .selectedTextLookup)
                            .accessibilityLabel("选中取词快捷键")
                    } else if method == .screenshot {
                        shortcutRow("取词快捷键", name: .screenshotLookup)
                            .accessibilityLabel("截图取词快捷键")
                        helpText("按快捷键框选文字，图片仅在本机识别。")
                    } else {
                        HStack {
                            Text("触发方式")
                            Spacer()
                            Picker("触发方式", selection: $hoverTrigger) {
                                ForEach(HoverTrigger.allCases) { trigger in Text(trigger.title).tag(trigger.rawValue) }
                            }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                        }
                        shortcutRow("开启 / 关闭悬停取词", name: .toggleHoverLookup)
                        Divider()
                        permissionRow("屏幕录制（可选）", allowed: screenAllowed, screenRecording: true) {
                            authorizePermission(screenRecording: true)
                        }
                        helpText("直接读取不到文字时，授权屏幕录制可截取鼠标附近区域，在本机识别。")
                    }
                }
            }
        }
    }

    private func isCaptureEnabled(_ method: CaptureMethod) -> Bool {
        switch method {
        case .selection: return selectionEnabled
        case .screenshot: return screenshotEnabled
        case .hover: return hoverEnabled
        }
    }

    private func setCaptureEnabled(_ method: CaptureMethod, _ enabled: Bool) {
        switch method {
        case .selection: selectionEnabled = enabled
        case .screenshot: screenshotEnabled = enabled
        case .hover: hoverEnabled = enabled
        }
    }

    private func permissionAllowed(_ method: CaptureMethod) -> Bool {
        method.usesScreenPermission ? screenAllowed : accessibilityAllowed
    }

    private func captureEnabledBinding(_ method: CaptureMethod) -> Binding<Bool> {
        Binding(get: { isCaptureEnabled(method) }, set: { enabled in
            pendingAuthorization.remove(method)
            guard enabled else { setCaptureEnabled(method, false); return }
            refreshPermissions()
            guard permissionAllowed(method) else {
                authorizationMethod = method
                showCaptureAuthorization = true
                return
            }
            setCaptureEnabled(method, true)
        })
    }

    private var serviceSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup {
                Text("词典服务").font(AppTypography.section)
                Text("HTTPS API 地址").font(AppTypography.secondary)
                TextField("https://…", text: $model.address)
                    .disabled(!model.keyLoaded || model.isSaving)
                Text("只读 API 密钥").font(AppTypography.secondary).padding(.top, 6)
                SecureField("输入只读产品密钥", text: $model.key)
                    .disabled(!model.keyLoaded || model.isSaving)
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        helpText("正在读取钥匙串，请留意系统授权提示…")
                    }
                } else if !model.keyLoaded {
                    Button("重试读取钥匙串") { model.load() }
                }
                helpText("密钥只保存在本机钥匙串中。请使用只读产品密钥，不要填写管理密钥。更换服务器时请同时更换对应密钥。")
                Link("获取 API 密钥", destination: URL(string: "https://odict.touchany.com/admin/api-clients")!)
            }.textFieldStyle(.roundedBorder)
            if let message = model.message {
                Text(message).font(AppTypography.secondary)
                    .foregroundColor(model.saved ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                helpText("修改后保存，下一次查词生效。")
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(model.isSaving ? "正在保存…" : "保存服务设置", action: model.save)
                    .keyboardShortcut(.defaultAction).disabled(!model.keyLoaded || model.isSaving)
            }
        }
    }

    private var privacySettings: some View {
        VStack(spacing: 18) {
            settingsGroup {
                Text("系统权限").font(AppTypography.section)
                permissionRow("辅助功能", allowed: accessibilityAllowed) {
                    CapturePermissions.openSettings(screenRecording: false)
                }
                Divider()
                permissionRow("屏幕录制", allowed: screenAllowed, screenRecording: true) {
                    authorizePermission(screenRecording: true)
                }
                helpText("授权后请重新触发取词；屏幕录制权限可能需要按系统提示重新打开应用。")
            }
            settingsGroup {
                Text("数据与隐私").font(AppTypography.section)
                helpText("选中取词读取当前应用选中的文字；悬停取词读取鼠标处文字，必要时仅截取附近区域。")
                helpText("所有图片均在本机识别，不上传图片。词典模式只将查询文字交给词典服务；AI 模式将文字发送至你配置的 AI 服务。")
                helpText("AI 原文与回答会按设置的数量保存在本机历史中，可在 AI 查询窗口查看或清空。密钥仍只保存在 Keychain。")
            }
        }
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(AppTypography.secondary).foregroundColor(.secondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name).accessibilityLabel(title)
        }.padding(.vertical, 4)
    }

    private func notifyHoverPreferenceChanged() {
        NotificationCenter.default.post(name: HoverLookupController.preferenceChanged, object: nil)
    }

    private func authorizePermission(screenRecording: Bool) {
        CapturePermissions.authorize(screenRecording: screenRecording)
        refreshPermissions()
    }

    private func permissionRow(_ title: String, allowed: Bool, screenRecording: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: allowed ? "checkmark.circle" : "lock.circle").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(allowed ? "已授权" : "未授权").font(AppTypography.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(allowed ? "查看权限" : (screenRecording && screenAuthorizationRequested ? "打开系统设置" : "授权…"), action: action)
        }.padding(.vertical, 4)
    }

    private func refreshPermissions() {
        accessibilityAllowed = CapturePermissions.accessibility
        screenAllowed = CapturePermissions.screenRecording
        screenAuthorizationRequested = CapturePermissions.hasRequestedScreenRecording
        for method in CaptureMethod.allCases where pendingAuthorization.contains(method) && permissionAllowed(method) {
            pendingAuthorization.remove(method)
            setCaptureEnabled(method, true)
        }
    }
}
