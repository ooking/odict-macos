import SwiftUI
import KeyboardShortcuts
import AppKit

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case capture = "取词方式"
    case shortcuts = "快捷键"
    case dictionaries = "词典来源"
    case service = "在线词典"
    case ai = "AI"
    case privacy = "权限与隐私"

    var id: Self { self }
    var icon: String {
        switch self {
        case .capture: return "text.cursor"
        case .shortcuts: return "command"
        case .dictionaries: return "books.vertical"
        case .service: return "network"
        case .ai: return "sparkles"
        case .privacy: return "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .capture: return "选择适合你的取词方式，随时继续阅读。"
        case .shortcuts: return "设置全局快捷键，无需切换应用即可查词。"
        case .dictionaries: return "管理本地词典、查询顺序和词典资源。"
        case .service: return "连接在线词典，补充本地未收录的内容。"
        case .ai: return "独立配置 AI，解释单词与短语，翻译句子。"
        case .privacy: return "管理取词所需的系统权限，了解数据如何使用。"
        }
    }
}

struct SettingsView: View {
    private static let versionLabel: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (Build \(build))"
    }()

    @ObservedObject var model: SettingsModel
    // Retain the lightweight configuration across category switches, including
    // import status. The child cancels pending discovery when it disappears.
    @StateObject private var dictionaryModel = LocalDictionarySettingsModel()
    @AppStorage(HoverLookupController.preferenceKey) private var hoverEnabled = false
    @AppStorage(HoverTrigger.preferenceKey) private var hoverTrigger = HoverTrigger.control.rawValue
    @AppStorage(QueryMode.captureKey) private var captureMode = QueryMode.dictionary.rawValue
    @State private var category = SettingsCategory.capture
    @State private var accessibilityAllowed = false
    @State private var screenAllowed = false

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
        .onChange(of: hoverEnabled) { _ in notifyHoverPreferenceChanged() }
        .onChange(of: hoverTrigger) { _ in notifyHoverPreferenceChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置").font(AppTypography.section).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)
            ForEach(SettingsCategory.allCases) { item in
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
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text("ODict").font(AppTypography.section)
                Text(Self.versionLabel).font(AppTypography.caption).foregroundColor(.secondary)
            }.padding(12)
        }
        .padding(12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    @ViewBuilder private var categoryContent: some View {
        switch category {
        case .capture: captureSettings
        case .shortcuts: shortcutSettings
        case .dictionaries:
            settingsGroup { LocalDictionarySettingsView(model: dictionaryModel) }
        case .service: serviceSettings.onAppear { model.load() }
        case .ai: AISettingsView(model: model.ai)
        case .privacy: privacySettings
        }
    }

    private var captureSettings: some View {
        VStack(spacing: 18) {
            settingsGroup {
                Text("查询模式").font(AppTypography.section)
                Picker("取词后使用", selection: $captureMode) {
                    ForEach(QueryMode.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                helpText("选中、截图和悬停取词共用此设置。手动查询窗口单独记住上次模式；两种模式不会自动互相兜底。")
            }
            settingsGroup {
                HStack {
                    Text("悬停取词").font(AppTypography.section)
                    Spacer()
                    Toggle("启用悬停取词", isOn: $hoverEnabled).labelsHidden().toggleStyle(.switch)
                }
                helpText("无需选中文字，使用触发键读取鼠标附近的文字。")
                Divider().padding(.vertical, 4)
                HStack {
                    Text("触发方式")
                    Spacer()
                    Picker("触发方式", selection: $hoverTrigger) {
                        ForEach(HoverTrigger.allCases) { trigger in Text(trigger.title).tag(trigger.rawValue) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 200).disabled(!hoverEnabled)
                }
                helpText((HoverTrigger(rawValue: hoverTrigger) ?? .control).instruction)
                helpText("移入释义卡片可朗读、复制，点击后可编辑；移开鼠标或按 Escape 收起。")
            }
            settingsGroup {
                Text("选中取词").font(AppTypography.section)
                helpText("先在其他应用选中文字，再按取词热键查询。")
                Divider().padding(.vertical, 4)
                Text("截图取词").font(AppTypography.section)
                helpText("按热键后框选图片、视频或应用中的文字，在本机识别后查询。")
                Button("设置取词快捷键") { category = .shortcuts }
                    .padding(.top, 4)
            }
            helpText("取词偏好自动保存。若无法取词，请在「权限与隐私」中查看授权状态。")
        }
    }

    private var shortcutSettings: some View {
        VStack(spacing: 18) {
            settingsGroup {
                shortcutRow("唤出 / 收起词典", name: .toggleDictionary)
                Divider()
                shortcutRow("选中取词", name: .selectedTextLookup)
                Divider()
                shortcutRow("截图取词", name: .screenshotLookup)
                Divider()
                shortcutRow("开启 / 关闭悬停取词", name: .toggleHoverLookup)
            }
            helpText("点击热键框后按下组合键；按删除键可清除。快捷键自动保存，并在其他应用中生效。")
        }
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
                permissionRow("屏幕录制", allowed: screenAllowed) {
                    CapturePermissions.openSettings(screenRecording: true)
                }
                helpText("授权后请重新触发取词；屏幕录制权限可能需要按系统提示重新打开应用。")
            }
            settingsGroup {
                Text("数据与隐私").font(AppTypography.section)
                helpText("选中取词读取当前应用选中的文字；悬停取词读取鼠标处文字，必要时仅截取附近区域。")
                helpText("所有图片均在本机识别，不上传图片。词典模式只将查询文字交给词典服务；AI 模式将文字发送至你配置的 AI 服务。")
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

    private func permissionRow(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: allowed ? "checkmark.circle" : "lock.circle").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(allowed ? "已授权" : "未授权").font(AppTypography.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(allowed ? "查看权限" : "授权…", action: action)
        }.padding(.vertical, 4)
    }

    private func refreshPermissions() {
        accessibilityAllowed = CapturePermissions.accessibility
        screenAllowed = CapturePermissions.screenRecording
    }
}
