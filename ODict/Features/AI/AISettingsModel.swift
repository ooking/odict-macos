import SwiftUI

enum AIConnectionVerificationState: Equatable {
    case idle, checking, success, failure(String), cancelled
}

@MainActor
final class AISettingsModel: ObservableObject {
    @Published var configuration = AISettingsStore.configuration
    @Published var key = ""
    @Published var profiles = AISettingsStore.library.profiles
    @Published var selectedID = AISettingsStore.library.selectedID
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isFetchingModels = false
    @Published private(set) var modelsMessage: String?
    private var draftKeys: [UUID: String] = [:]
    private var modelsTask: Task<Void, Never>?
    private var modelsRevision = UUID()
    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var verificationState: AIConnectionVerificationState = .idle
    var isVerifying: Bool { verificationState == .checking }
    @Published private(set) var message: String?
    @Published private(set) var succeeded = false
    private let client: AIQueryServing
    private let loadSettings: () async throws -> AISavedSettings
    private let saveSettings: ((AIConfiguration, String) async throws -> Void)?
    private var task: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var revision = UUID()
    private var verificationRevision = UUID()

    init(client: AIQueryServing = AIClient(),
         loadSettings: @escaping () async throws -> AISavedSettings = { try await AISettingsStore.load() },
         saveSettings: ((AIConfiguration, String) async throws -> Void)? = nil) {
        self.client = client
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
    }

    func load() {
        guard !loaded, !isLoading else { return }
        isLoading = true
        let token = revision
        let loadSettings = loadSettings
        let profile = profiles.first(where: { $0.id == selectedID })
        let useSelected = selectedID != AISettingsStore.library.selectedID
        task = Task { [weak self] in
            do {
                let saved: AISavedSettings
                if useSelected, let profile {
                    saved = AISavedSettings(configuration: profile.configuration,
                                            key: try await KeychainStore.loadSecret(account: profile.keyAccount))
                } else { saved = try await loadSettings() }
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.configuration = saved.configuration
                self.key = saved.key
                self.loaded = true
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.isLoading = false; self.task = nil
                self.message = error.localizedDescription; self.succeeded = false
            }
        }
    }

    private func draft() throws -> AISavedSettings {
        var value = configuration
        value.address = value.address.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try AISettingsStore.validate(value, key: secret)
        return AISavedSettings(configuration: value, key: secret)
    }

    func save() {
        guard loaded, !isSaving else { return }
        cancelModels(); cancelVerification(clearFeedback: true)
        succeeded = false; message = nil
        let saved: AISavedSettings
        do { saved = try draft() } catch { message = error.localizedDescription; return }
        isSaving = true
        syncDraft()
        let library = AIServiceLibrary(profiles: profiles, selectedID: selectedID)
        let keys = draftKeys
        let saveSettings = saveSettings
        let token = revision
        task = Task { [weak self] in
            do {
                if let saveSettings { try await saveSettings(saved.configuration, saved.key) }
                else {
                    var normalized = library
                    if let index = normalized.profiles.firstIndex(where: { $0.id == normalized.selectedID }) {
                        normalized.profiles[index].configuration = saved.configuration
                    }
                    var normalizedKeys = keys
                    normalizedKeys[normalized.selectedID] = saved.key
                    try await AISettingsStore.saveLibrary(normalized, keys: normalizedKeys)
                }
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.configuration = saved.configuration
                self.isSaving = false; self.task = nil; self.succeeded = true
                self.message = "AI 设置已保存，下次查询生效。"
            } catch {
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.isSaving = false; self.task = nil; self.message = error.localizedDescription
            }
        }
    }

    func verify() {
        guard !isSaving, !isVerifying else { return }
        guard loaded else {
            verificationState = .failure("请先读取钥匙串，再验证连接。")
            return
        }
        let saved: AISavedSettings
        do { saved = try draft() }
        catch { verificationState = .failure(error.localizedDescription); return }
        verificationState = .checking
        let token = verificationRevision
        let client = client
        verification = Task { [weak self] in
            do {
                _ = try await client.answer(text: "Hello.", kind: .translation, target: nil, settings: saved)
                guard !Task.isCancelled, let self, token == self.verificationRevision else { return }
                self.verification = nil
                self.verificationState = .success
            } catch {
                guard !Task.isCancelled, let self, token == self.verificationRevision else { return }
                self.verification = nil
                let text = (error as? URLError)?.code == .timedOut
                    ? "请求超时，请检查服务或思考设置后重试。" : error.localizedDescription
                self.verificationState = .failure(text)
            }
        }
    }

    private func syncDraft() {
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) { profiles[index].configuration = configuration }
        draftKeys[selectedID] = key
    }
    func rename(_ name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles[index].name = String(name.prefix(60))
        message = nil; succeeded = false
    }
    func select(_ id: UUID) {
        guard id != selectedID, loaded, !isSaving else { return }
        syncDraft()
        activate(id)
    }
    private func activate(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        cancelModels(); edited()
        selectedID = id; configuration = profile.configuration; key = ""
        revision = UUID()
        if let secret = draftKeys[id] { key = secret; return }
        loaded = false; isLoading = true
        let token = revision
        task = Task { [weak self] in
            do {
                let secret = try await KeychainStore.loadSecret(account: profile.keyAccount)
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.key = secret; self.loaded = true; self.isLoading = false; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.isLoading = false; self.task = nil; self.message = error.localizedDescription
            }
        }
    }
    func addProfile() {
        guard loaded, !isSaving, profiles.count < AISettingsStore.maximumProfiles else { return }
        syncDraft()
        let profile = AIServiceProfile(id: UUID(), name: "新配置", configuration: AIConfiguration())
        profiles.append(profile); draftKeys[profile.id] = ""
        activate(profile.id)
    }
    func removeProfile() {
        guard loaded, !isSaving, profiles.count > 1 else { return }
        draftKeys.removeValue(forKey: selectedID)
        profiles.removeAll { $0.id == selectedID }
        activate(profiles[0].id)
    }
    func fetchModels() {
        guard loaded, !isSaving, !isFetchingModels else { return }
        cancelModels()
        isFetchingModels = true
        let token = modelsRevision
        let address = configuration.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client
        modelsTask = Task { [weak self] in
            do {
                let models = try await client.models(address: address, key: secret)
                guard !Task.isCancelled, let self, self.modelsRevision == token else { return }
                self.availableModels = models; self.isFetchingModels = false; self.modelsTask = nil
                self.modelsMessage = "已获取 \(models.count) 个模型，可从列表选择或手动填写。"
            } catch {
                guard !Task.isCancelled, let self, self.modelsRevision == token else { return }
                self.modelsMessage = "获取失败：" + error.localizedDescription
                self.isFetchingModels = false; self.modelsTask = nil
            }
        }
    }
    func cancelModels() {
        modelsTask?.cancel(); modelsTask = nil; modelsRevision = UUID()
        isFetchingModels = false; availableModels = []; modelsMessage = nil
    }

    // Only user edits invalidate feedback; programmatic loading/saving must not erase it.
    func update<Value: Equatable>(_ path: WritableKeyPath<AIConfiguration, Value>, value: Value) {
        guard configuration[keyPath: path] != value else { return }
        if (path as AnyKeyPath) == \AIConfiguration.address { cancelModels() }
        edited()
        configuration[keyPath: path] = value
    }
    func updateKey(_ value: String) {
        guard key != value else { return }
        cancelModels(); edited()
        key = value
    }
    private func edited() {
        cancelVerification(clearFeedback: true)
        message = nil; succeeded = false
    }
    func cancelVerification(clearFeedback: Bool = false) {
        let wasVerifying = isVerifying
        verification?.cancel(); verification = nil
        verificationRevision = UUID()
        if clearFeedback { verificationState = .idle }
        else if wasVerifying { verificationState = .cancelled }
    }
    func close() {
        cancelVerification(clearFeedback: true); task?.cancel(); task = nil; revision = UUID()
        cancelModels(); draftKeys.removeAll()
        profiles = AISettingsStore.library.profiles; selectedID = AISettingsStore.library.selectedID
        key = ""; loaded = false; isLoading = false; isSaving = false
    }
    deinit { task?.cancel(); verification?.cancel(); modelsTask?.cancel() }
}
