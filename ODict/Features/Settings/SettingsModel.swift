import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var showAI = false
    let ai = AISettingsModel()
    @Published var address = UserDefaults.standard.string(forKey: "apiURL") ?? ServiceSettingsStore.defaultAddress
    @Published var key = ""
    @Published private(set) var message: String?
    @Published private(set) var saved = false
    @Published private(set) var keyLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    private let store: ServiceSettingsServing
    private var task: Task<Void, Never>?
    private var revision = UUID()
    var didSave: (() -> Void)?

    init(store: ServiceSettingsServing = ServiceSettingsStore()) { self.store = store }

    func load() {
        guard !keyLoaded, !isLoading, !isSaving else { return }
        revision = UUID()
        let token = revision
        isLoading = true
        message = nil
        task = Task { [weak self, store] in
            defer { if self?.revision == token { self?.isLoading = false; self?.task = nil } }
            do {
                let value = try await store.load()
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.address = value.address
                self?.key = value.key
                self?.keyLoaded = true
            } catch {
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.saved = false
                self?.message = error.localizedDescription
            }
        }
    }

    func save() {
        guard keyLoaded, !isSaving else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = false
        do {
            _ = try ServiceEndpoint(address)
            guard !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ServiceSettingsError.invalidKey }
        } catch { message = error.localizedDescription; return }
        revision = UUID()
        let token = revision
        isSaving = true
        task = Task { [weak self, store] in
            defer { if self?.revision == token { self?.isSaving = false; self?.task = nil } }
            do {
                try await store.save(address: address, key: secret)
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.address = address
                self?.saved = true
                self?.message = secret.isEmpty ? "服务设置已保存，已移除本机密钥。" : "已保存，下一次查词生效。"
                self?.didSave?()
            } catch {
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.message = error.localizedDescription
            }
        }
    }

    func close() {
        ai.close()
        revision = UUID()
        task?.cancel()
        task = nil
        key = ""
        keyLoaded = false
        isLoading = false
        isSaving = false
        message = nil
    }
}
