import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

@MainActor
final class AccountLoginModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var user: AccountUser?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var browser: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?
    private var revision = UUID()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
    }
    func load() {
        let endpoint = ODictService.apiAddress
        task?.cancel(); user = nil; message = nil; revision = UUID(); let run = revision
        task = Task { [weak self] in
            do { let value = try await AccountStore.shared.user(endpoint: endpoint); guard !Task.isCancelled, self?.revision == run else { return }; self?.user = value }
            catch { if self?.revision == run { self?.message = error.localizedDescription } }
        }
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DictionaryError.configuration }
        return Data(bytes).base64URL
    }
    func login(didSave: @escaping () -> Void) {
        let endpoint = ODictService.apiAddress
        guard !busy else { return }
        busy = true; message = nil; task?.cancel(); revision = UUID(); let run = revision
        task = Task { [weak self] in
            defer { if self?.revision == run { self?.busy = false; self?.browser = nil; self?.task = nil } }
            do {
                _ = try ServiceEndpoint(endpoint)
                guard var url = URLComponents(string: ODictService.webOrigin), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                      (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else { throw DictionaryError.configuration }
                guard let self else { throw CancellationError() }
                let verifier = try self.random(); let state = try self.random()
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
                url.path = "/auth/client"
                url.queryItems = [.init(name: "client_id", value: "odict-macos"), .init(name: "redirect_uri", value: "com.touchany.odict:/auth/callback"),
                                  .init(name: "code_challenge", value: challenge), .init(name: "state", value: state)]
                guard let address = url.url else { throw DictionaryError.configuration }
                let callback: URL = try await withCheckedThrowingContinuation { continuation in
                    let browser = ASWebAuthenticationSession(url: address, callbackURLScheme: "com.touchany.odict") { result, error in
                        if let result { continuation.resume(returning: result) }
                        else { continuation.resume(throwing: error ?? CancellationError()) }
                    }
                    browser.presentationContextProvider = self
                    self.browser = browser
                    if !browser.start() { self.browser = nil; continuation.resume(throwing: DictionaryError.configuration) }
                }
                try Task.checkCancellation()
                guard self.revision == run, let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.scheme == "com.touchany.odict", parts.path == "/auth/callback",
                      parts.queryItems?.filter({ $0.name == "state" }).count == 1,
                      parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
                      parts.queryItems?.filter({ $0.name == "code" }).count == 1,
                      let code = parts.queryItems?.first(where: { $0.name == "code" })?.value else { throw DictionaryError.unauthorized }
                let user = try await AccountStore.shared.exchange(endpoint: endpoint, code: code, verifier: verifier)
                try Task.checkCancellation()
                guard self.revision == run else { return }
                self.user = user; self.message = "登录成功。"; didSave()
            } catch {
                guard !Task.isCancelled, self?.revision == run else { return }
                if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self?.message = error.localizedDescription }
            }
        }
    }
    func logout() {
        let endpoint = ODictService.apiAddress
        guard !busy else { return }; busy = true; message = nil; task?.cancel(); revision = UUID(); let run = revision
        task = Task { [weak self] in
            defer { if self?.revision == run { self?.busy = false; self?.task = nil } }
            do { try await AccountStore.shared.logout(endpoint: endpoint); guard !Task.isCancelled, self?.revision == run else { return }; self?.user = nil; self?.message = "已退出当前客户端。" }
            catch { if !Task.isCancelled, self?.revision == run { self?.message = error.localizedDescription } }
        }
    }
    func close() { revision = UUID(); browser?.cancel(); browser = nil; task?.cancel(); task = nil; busy = false }
}

struct AccountSettingsView: View {
    @ObservedObject var settings: SettingsModel
    @StateObject private var account = AccountLoginModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ODict 账号").font(AppTypography.section)
            if let user = account.user {
                Text(user.nickname).font(AppTypography.body)
                Text(user.email).font(AppTypography.secondary).foregroundColor(.secondary)
                Button("退出当前客户端") { account.logout() }.disabled(account.busy)
            } else {
                Text("登录后即可使用在线词典，本地词典无需登录。").font(AppTypography.secondary).foregroundColor(.secondary)
            }
            Button(account.user == nil ? "在网页中登录" : "切换账号") {
                account.login { settings.didSave?() }
            }.disabled(account.busy)
            if account.busy { HStack { ProgressView().controlSize(.small); Button("取消") { account.close() } } }
            if let message = account.message { Text(message).font(AppTypography.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("登录凭证仅保存在本机钥匙串。登录会关联当前设备的派生标识；退出只撤销本端会话。").font(AppTypography.secondary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

        }
        .onAppear { account.load() }
        .onDisappear { account.close() }
    }
}
