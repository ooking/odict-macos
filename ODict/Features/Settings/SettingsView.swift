import SwiftUI
import KeyboardShortcuts
import AppKit

struct SettingsView: View {
    @State private var address = UserDefaults.standard.string(forKey: "apiURL") ?? "https://odict-api.touchany.com"
    @State private var key = ""
    @State private var message: String?
    @State private var saved = false
    @State private var keyLoaded = false
    @State private var keyLoading = false
    @State private var keyLoadID = UUID()
    @State private var keyLoadToken = UUID()
    @State private var isSaving = false
    @State private var accessibilityAllowed = false
    @State private var screenAllowed = false
    let didSave: () -> Void

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
                    Text("取词权限").font(.headline)
                    permissionRow("辅助功能", allowed: accessibilityAllowed) {
                        if !accessibilityAllowed { CapturePermissions.requestAccessibility() }
                        CapturePermissions.openSettings(screenRecording: false)
                    }
                    permissionRow("屏幕录制", allowed: screenAllowed) {
                        if !screenAllowed { _ = CGRequestScreenCaptureAccess() }
                        CapturePermissions.openSettings(screenRecording: true)
                    }
                    Text("选中取词只读取当前应用选中的文字；截图取词在本机识别，不上传图片。仅将取出的文字交给词典服务查询。授权后请重新触发取词；屏幕录制权限可能需要按系统提示重新打开应用。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("词典服务").font(.headline)
                    TextField("HTTPS API 地址", text: $address).disabled(isSaving)
                    SecureField("只读 API 密钥", text: $key).disabled(!keyLoaded || isSaving)
                    if keyLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取钥匙串，请留意系统授权提示…").font(.caption).foregroundColor(.secondary)
                        }
                    } else if !keyLoaded {
                        Button("重试读取钥匙串") { keyLoadID = UUID() }.controlSize(.small)
                    }
                    Text("密钥只保存在本机钥匙串中。请使用只读产品密钥，不要填写管理密钥。更换服务器时请同时更换对应密钥。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("获取 API 密钥", destination: URL(string: "https://odict.touchany.com/admin/api-clients")!)
                }.textFieldStyle(.roundedBorder)
                if let message { Text(message).font(.callout).foregroundColor(saved ? .secondary : .red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("macOS 原生词典 · v1.0").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small).accessibilityLabel("正在保存服务设置") }
                    Button(isSaving ? "正在保存…" : "保存服务设置", action: save)
                        .keyboardShortcut(.defaultAction).disabled(!keyLoaded || isSaving)
                }
            }.padding(26).frame(width: 512, alignment: .leading)
        }.frame(width: 512, height: min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80))
            .onAppear {
                refreshPermissions()
            }
            .task(id: keyLoadID) { await loadKey() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissions()
            }
    }

    @MainActor
    private func loadKey() async {
        guard !keyLoaded else { return }
        let token = UUID()
        keyLoadToken = token
        keyLoading = true
        message = nil
        defer { if keyLoadToken == token { keyLoading = false } }
        do {
            let value = try await KeychainStore.read()
            guard !Task.isCancelled, keyLoadToken == token else { return }
            key = value
            keyLoaded = true
        } catch {
            guard !Task.isCancelled, keyLoadToken == token else { return }
            saved = false
            message = error.localizedDescription
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

    private func save() {
        guard keyLoaded, !isSaving else { return }
        saved = false
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            message = "请输入有效的 HTTPS 地址，不包含账户、查询参数或片段。"; return
        }
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else { message = "密钥中不能包含空格或换行。"; return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await KeychainStore.save(secret)
                UserDefaults.standard.set(value, forKey: "apiURL")
                saved = true
                message = secret.isEmpty ? "服务设置已保存，已移除本机密钥。" : "已保存，下一次查词生效。"
                didSave()
            } catch { message = error.localizedDescription }
        }
    }
}
