import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var address = UserDefaults.standard.string(forKey: "apiURL") ?? "https://odict-api.touchany.com"
    @State private var key = ""
    @State private var message: String?
    @State private var saved = false
    @State private var keyLoaded = false
    let didSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ODict 设置").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                Text("全局快捷键").font(.headline)
                KeyboardShortcuts.Recorder("唤出 / 收起词典", name: .toggleDictionary)
                Text("点击录制框后按下组合键；按删除键可清除。快捷键会自动保存。")
                    .font(.caption).foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("词典服务").font(.headline)
                TextField("HTTPS API 地址", text: $address)
                SecureField("只读 API 密钥", text: $key).disabled(!keyLoaded)
                Text("密钥只保存在本机钥匙串中。请使用只读产品密钥，不要填写管理密钥。更换服务器时请同时更换对应密钥。")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("获取 API 密钥", destination: URL(string: "https://odict.touchany.com/admin/api-clients")!)
            }.textFieldStyle(.roundedBorder)
            if let message { Text(message).font(.callout).foregroundColor(saved ? .secondary : .red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("macOS 原生词典 · v1.0").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("保存服务设置", action: save).keyboardShortcut(.defaultAction).disabled(!keyLoaded)
            }
        }.padding(26).frame(width: 460)
            .onAppear {
                do { key = try KeychainStore.read(); keyLoaded = true }
                catch { message = error.localizedDescription }
            }
    }

    private func save() {
        saved = false
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            message = "请输入有效的 HTTPS 地址，不包含账户、查询参数或片段。"; return
        }
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else { message = "密钥中不能包含空格或换行。"; return }
        do {
            try KeychainStore.save(secret)
            UserDefaults.standard.set(value, forKey: "apiURL")
            saved = true
            message = secret.isEmpty ? "服务设置已保存，已移除本机密钥。" : "已保存，下一次查词生效。"
            didSave()
        } catch { message = error.localizedDescription }
    }
}
