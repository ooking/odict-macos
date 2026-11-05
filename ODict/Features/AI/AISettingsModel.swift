import SwiftUI

enum AIConnectionVerificationState: Equatable {
    case idle, checking, success, failure(String), cancelled
}

@MainActor
final class AISettingsModel: ObservableObject {
    @Published var configuration: AIConfiguration
    @Published var key = ""
    @Published var profiles: [AIServiceProfile]
    @Published var selectedID: UUID
    @Published private(set) var activeID: UUID
    @Published private(set) var savedActiveID: UUID
    @Published private(set) var savedActiveName: String
    @Published private(set) var hasChanges = false
    @Published private(set) var shared: AISharedPreferences
    var selectedName: String { profileName(selectedID) }
    var activeName: String { profileName(activeID) }
    private func profileName(_ id: UUID) -> String {
        let name = profiles.first(where: { $0.id == id })?.name ?? ""
        return name.isEmpty ? "未命名配置" : name
    }
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isFetchingModels = false
    @Published private(set) var modelsMessage: String?
    private struct EditorSnapshot {
        let profiles: [AIServiceProfile]
        let selectedID: UUID
        let configuration: AIConfiguration
        let key: String
        let keys: [UUID: String]
        let loaded: Bool
        let hasChanges: Bool
    }
    private var editorSnapshot: EditorSnapshot?
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
        let library = AISettingsStore.library
        configuration = library.effectiveConfiguration
        profiles = library.profiles
        selectedID = library.selectedID
        activeID = library.selectedID
        savedActiveID = library.selectedID
        savedActiveName = library.selected.name
        shared = library.preferences
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
        var value = shared.applying(to: configuration)
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
        do { saved = try draft() } catch { message = "「\(selectedName)」：" + error.localizedDescription; return }
        isSaving = true
        syncDraft()
        let editingID = selectedID
        let library = AIServiceLibrary(profiles: profiles, selectedID: activeID, shared: shared)
        let keys = draftKeys
        let saveSettings = saveSettings
        let token = revision
        task = Task { [weak self] in
            do {
                if let saveSettings { try await saveSettings(saved.configuration, saved.key) }
                else {
                    var normalized = library
                    if let index = normalized.profiles.firstIndex(where: { $0.id == editingID }) {
                        normalized.profiles[index].configuration = saved.configuration
                    }
                    var normalizedKeys = keys
                    normalizedKeys[editingID] = saved.key
                    try await AISettingsStore.saveLibrary(normalized, keys: normalizedKeys)
                }
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.configuration = saved.configuration
                self.savedActiveID = self.activeID; self.savedActiveName = self.activeName
                self.hasChanges = false
                self.isSaving = false; self.task = nil; self.succeeded = true
                self.message = "已保存全部更改，查询使用「\(self.activeName)」。"
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

    private func snapshotEditor() {
        editorSnapshot = EditorSnapshot(profiles: profiles, selectedID: selectedID,
            configuration: configuration, key: key, keys: draftKeys, loaded: loaded, hasChanges: hasChanges)
    }
    func beginEditingProfile(_ id: UUID) {
        guard !isSaving, !isLoading, editorSnapshot == nil,
              profiles.contains(where: { $0.id == id }) else { return }
        snapshotEditor()
        cancelModels(); cancelVerification(clearFeedback: true); message = nil; succeeded = false
        if loaded { select(id) } else { activate(id) }
    }
    func beginAddingProfile() {
        guard loaded, !isSaving, profiles.count < AISettingsStore.maximumProfiles, editorSnapshot == nil else { return }
        snapshotEditor()
        addProfile()
    }
    func finishEditingProfile() -> Bool {
        guard loaded, !isSaving else { return false }
        do {
            let saved = try draft()
            configuration = saved.configuration; key = saved.key
            syncDraft()
            editorSnapshot = nil
            cancelModels(); cancelVerification(clearFeedback: true)
            message = nil; succeeded = false
            return true
        } catch {
            message = error.localizedDescription; succeeded = false
            return false
        }
    }
    func cancelEditingProfile() {
        guard let snapshot = editorSnapshot else { return }
        cancelModels(); cancelVerification(clearFeedback: true)
        task?.cancel(); task = nil; revision = UUID()
        profiles = snapshot.profiles; selectedID = snapshot.selectedID
        configuration = snapshot.configuration; key = snapshot.key; draftKeys = snapshot.keys
        loaded = snapshot.loaded; hasChanges = snapshot.hasChanges; isLoading = false
        editorSnapshot = nil; message = nil; succeeded = false
    }
    func setDefaultProfile(_ id: UUID) {
        guard !isSaving, !isLoading, editorSnapshot == nil,
              profiles.contains(where: { $0.id == id }), activeID != id else { return }
        activeID = id; hasChanges = true; message = nil; succeeded = false
    }
    func removeProfile(_ id: UUID) {
        guard !isSaving, !isLoading, editorSnapshot == nil, profiles.count > 1,
              profiles.contains(where: { $0.id == id }) else { return }
        if id == selectedID { removeProfile(); return }
        profiles.removeAll { $0.id == id }; draftKeys.removeValue(forKey: id)
        if activeID == id { activeID = profiles[0].id }
        hasChanges = true; message = nil; succeeded = false
    }

    private func syncDraft() {
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) { profiles[index].configuration = configuration }
        draftKeys[selectedID] = key
    }
    func rename(_ name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        let bounded = String(name.prefix(60))
        guard profiles[index].name != bounded else { return }
        profiles[index].name = bounded
        hasChanges = true
        message = nil; succeeded = false
    }
    func updateShared<Value: Equatable>(_ path: WritableKeyPath<AISharedPreferences, Value>, value: Value) {
        guard shared[keyPath: path] != value else { return }
        edited()
        shared[keyPath: path] = value
    }
    func useSelectedProfile() {
        guard loaded, !isSaving, activeID != selectedID else { return }
        activeID = selectedID; hasChanges = true
        message = nil; succeeded = false
    }
    func select(_ id: UUID) {
        guard id != selectedID, loaded, !isSaving else { return }
        syncDraft()
        activate(id)
    }
    private func activate(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        cancelModels(); edited(markChanges: false)
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
        var number = profiles.count + 1
        while profiles.contains(where: { $0.name == "配置 \(number)" }) { number += 1 }
        let profile = AIServiceProfile(id: UUID(), name: "配置 \(number)", configuration: AIConfiguration())
        profiles.append(profile); draftKeys[profile.id] = ""; hasChanges = true
        activate(profile.id)
    }
    func removeProfile() {
        guard loaded, !isSaving, profiles.count > 1 else { return }
        hasChanges = true
        draftKeys.removeValue(forKey: selectedID)
        profiles.removeAll { $0.id == selectedID }
        if activeID == selectedID { activeID = profiles[0].id }
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
    private func edited(markChanges: Bool = true) {
        if markChanges { hasChanges = true }
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
        cancelModels(); draftKeys.removeAll(); editorSnapshot = nil
        let library = AISettingsStore.library
        profiles = library.profiles; selectedID = library.selectedID; activeID = library.selectedID
        shared = library.preferences
        savedActiveID = library.selectedID; savedActiveName = library.selected.name; hasChanges = false
        key = ""; loaded = false; isLoading = false; isSaving = false
    }
    deinit { task?.cancel(); verification?.cancel(); modelsTask?.cancel() }
}
