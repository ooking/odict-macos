import SwiftUI
import KeyboardShortcuts
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(HoverLookupController.preferenceKey) private var hoverEnabled = false
    @AppStorage(HoverTrigger.preferenceKey) private var hoverTrigger = HoverTrigger.control.rawValue
    @State private var accessibilityAllowed = false
    @State private var screenAllowed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ODict 设置").font(.title2.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Text("词典窗口").font(.headline)
                    KeyboardShortcuts.Recorder("唤出 / 收起", name: .toggleDictionary)
                    Text("点击热键框后按下组合键；按删除键可清除。取词偏好和热键均自动保存。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("选中取词").font(.headline)
                    KeyboardShortcuts.Recorder("取词热键", name: .selectedTextLookup)
                    Text("先在其他应用选中文字，再按热键查询。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("悬停取词").font(.headline)
                        Spacer()
                        Toggle("启用", isOn: $hoverEnabled).toggleStyle(.switch)
                            .accessibilityLabel("启用悬停取词")
                    }
                    HStack(spacing: 12) {
                        Text("取词方式")
                        Picker("取词方式", selection: $hoverTrigger) {
                            ForEach(HoverTrigger.allCases) { trigger in
                                Text(trigger.title).tag(trigger.rawValue)
                            }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 220)
                    }
                    KeyboardShortcuts.Recorder("开关热键", name: .toggleHoverLookup)
                    Text((HoverTrigger(rawValue: hoverTrigger) ?? .control).instruction
                        + "开关热键用于开启或关闭悬停取词，无需打开设置。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("无需选中文字。移入释义卡片可朗读、复制，点击后可编辑；移开鼠标或按 Escape 收起。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: hoverEnabled) { _ in notifyHoverPreferenceChanged() }
                .onChange(of: hoverTrigger) { _ in notifyHoverPreferenceChanged() }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("截图取词").font(.headline)
                    KeyboardShortcuts.Recorder("取词热键", name: .screenshotLookup)
                    Text("按热键后框选图片、视频或应用中的文字，在本机识别后查询。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("取词权限").font(.headline)
                    permissionRow("辅助功能", allowed: accessibilityAllowed) {
                        CapturePermissions.openSettings(screenRecording: false)
                    }
                    permissionRow("屏幕录制", allowed: screenAllowed) {
                        CapturePermissions.openSettings(screenRecording: true)
                    }
                    Text("选中取词读取当前应用选中的文字；悬停取词读取鼠标处文字，必要时仅截取附近区域。所有图片均在本机识别，不上传图片。仅将取出的文字交给词典服务查询。授权后请重新触发取词；屏幕录制权限可能需要按系统提示重新打开应用。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("词典服务").font(.headline)
                    TextField("HTTPS API 地址", text: $model.address).disabled(!model.keyLoaded || model.isSaving)
                    SecureField("只读 API 密钥", text: $model.key).disabled(!model.keyLoaded || model.isSaving)
                    if model.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取钥匙串，请留意系统授权提示…").font(.caption).foregroundColor(.secondary)
                        }
                    } else if !model.keyLoaded {
                        Button("重试读取钥匙串") { model.load() }.controlSize(.small)
                    }
                    Text("密钥只保存在本机钥匙串中。请使用只读产品密钥，不要填写管理密钥。更换服务器时请同时更换对应密钥。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("获取 API 密钥", destination: URL(string: "https://odict.touchany.com/admin/api-clients")!)
                }.textFieldStyle(.roundedBorder)
                if let message = model.message { Text(message).font(.callout).foregroundColor(model.saved ? .secondary : .red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("macOS 原生词典 · v1.0").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if model.isSaving { ProgressView().controlSize(.small).accessibilityLabel("正在保存服务设置") }
                    Button(model.isSaving ? "正在保存…" : "保存服务设置", action: model.save)
                        .keyboardShortcut(.defaultAction).disabled(!model.keyLoaded || model.isSaving)
                }
            }.padding(26).frame(width: 512, alignment: .leading)
        }.frame(width: 512, height: min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80))
            .onAppear {
                refreshPermissions()
                model.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissions()
            }
    }

    private func notifyHoverPreferenceChanged() {
        NotificationCenter.default.post(name: HoverLookupController.preferenceChanged, object: nil)
    }

    private func permissionRow(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: allowed ? "checkmark.circle" : "lock.circle")
            Text(allowed ? "已授权" : "未授权").font(.caption).foregroundColor(.secondary)
            Spacer()
            Button(allowed ? "查看权限" : "授权…", action: action).controlSize(.small)
        }
    }

    private func refreshPermissions() {
        accessibilityAllowed = CapturePermissions.accessibility
        screenAllowed = CapturePermissions.screenRecording
    }

}
