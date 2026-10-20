import SwiftUI
import KeyboardShortcuts
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(HoverLookupController.preferenceKey) private var hoverEnabled = false
    @State private var accessibilityAllowed = false
    @State private var screenAllowed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ODict 设置").font(.title2.bold())
                VStack(alignment: .leading, spacing: 10) {
                    Text("全局快捷键").font(.headline)
                    KeyboardShortcuts.Recorder("唤出 / 收起词典", name: .toggleDictionary)
                    KeyboardShortcuts.Recorder("选中取词", name: .selectedTextLookup)
                    KeyboardShortcuts.Recorder("截图取词", name: .screenshotLookup)
                    Text("点击录制框后按下组合键；按删除键可清除。快捷键会自动保存。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("按住 Control 悬停取词", isOn: $hoverEnabled)
                        .onChange(of: hoverEnabled) { _ in
                            NotificationCenter.default.post(name: HoverLookupController.preferenceChanged, object: nil)
                        }
                    Text("按住 Control，将鼠标停在单词上约 0.3 秒即可查词，无需选中。需要辅助功能权限；图片及无法直接读取的文字还需要屏幕录制权限。移入释义卡片可朗读、复制，点击卡片后可编辑查询；移开鼠标或按 Escape 收起。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("取词权限").font(.headline)
                    permissionRow("辅助功能", allowed: accessibilityAllowed) {
                        if !accessibilityAllowed { CapturePermissions.requestAccessibility() }
                        CapturePermissions.openSettings(screenRecording: false)
                    }
                    permissionRow("屏幕录制", allowed: screenAllowed) {
                        if !screenAllowed { _ = CGRequestScreenCaptureAccess() }
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
