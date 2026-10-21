import SwiftUI

enum AIConnectionVerificationState: Equatable {
    case idle, checking, success, failure(String), cancelled
}

@MainActor
final class AISettingsModel: ObservableObject {
    @Published var configuration = AISettingsStore.configuration
    @Published var key = ""
    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var verificationState: AIConnectionVerificationState = .idle
    var isVerifying: Bool { verificationState == .checking }
    @Published private(set) var message: String?
    @Published private(set) var succeeded = false
    private let client: AIQueryServing
    private let loadSettings: () async throws -> AISavedSettings
    private let saveSettings: (AIConfiguration, String) async throws -> Void
    private var task: Task<Void, Never>?
    private var verification: Task<Void, Never>?
    private var revision = UUID()
    private var verificationRevision = UUID()

    init(client: AIQueryServing = AIClient(),
         loadSettings: @escaping () async throws -> AISavedSettings = { try await AISettingsStore.load() },
         saveSettings: @escaping (AIConfiguration, String) async throws -> Void = { try await AISettingsStore.save($0, key: $1) }) {
        self.client = client
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
    }

    func load() {
        guard !loaded, !isLoading else { return }
        isLoading = true
        let token = revision
        let loadSettings = loadSettings
        task = Task { [weak self] in
            do {
                let saved = try await loadSettings()
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
        cancelVerification(clearFeedback: true)
        succeeded = false; message = nil
        let saved: AISavedSettings
        do { saved = try draft() } catch { message = error.localizedDescription; return }
        isSaving = true
        let saveSettings = saveSettings
        let token = revision
        task = Task { [weak self] in
            do {
                try await saveSettings(saved.configuration, saved.key)
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

    // Only user edits invalidate feedback; programmatic loading/saving must not erase it.
    func update<Value: Equatable>(_ path: WritableKeyPath<AIConfiguration, Value>, value: Value) {
        guard configuration[keyPath: path] != value else { return }
        edited()
        configuration[keyPath: path] = value
    }
    func updateKey(_ value: String) {
        guard key != value else { return }
        edited()
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
        key = ""; loaded = false; isLoading = false; isSaving = false
    }
    deinit { task?.cancel(); verification?.cancel() }
}
