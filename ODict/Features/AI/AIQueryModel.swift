import SwiftUI

@MainActor
final class AIQueryModel: ObservableObject {
    @Published private(set) var answer: AIAnswer?
    @Published private(set) var sourceText = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isThinking = false
    @Published private(set) var message: String?
    @Published private(set) var savedConfiguration: AIConfiguration
    private let client: AIQueryServing
    private let configuration: () -> AIConfiguration
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var activeText = ""

    init(client: AIQueryServing = AIClient(), configuration: @escaping () -> AIConfiguration = { AISettingsStore.configuration }) {
        self.client = client; self.configuration = configuration
        let saved = configuration()
        savedConfiguration = saved
    }
    var isConfigured: Bool {
        let value = savedConfiguration
        return !value.address.isEmpty && !value.model.isEmpty
    }

    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading || activeText != text else { return }
        reset()
        guard !text.isEmpty else { return }
        guard text.count <= AIConfiguration.maximumInput else {
            message = "请输入 \(AIConfiguration.maximumInput) 字以内的内容。"; return
        }
        guard isConfigured else { message = AIError.configuration.localizedDescription; return }
        isLoading = true
        activeText = text
        isThinking = savedConfiguration.thinking
        let token = revision
        let client = client
        task = Task { [weak self] in
            do {
                let answer = try await client.answer(text: text, kind: .automatic, target: nil, settings: nil)
                guard !Task.isCancelled, let self, token == self.revision else { return }
                self.sourceText = text
                self.answer = answer
                self.finish()
            } catch {
                guard !Task.isCancelled, let self, token == self.revision else { return }
                if (error as? URLError)?.code == .timedOut {
                    self.message = "AI 响应超时，请缩短原文、关闭思考或稍后重试。"
                } else { self.message = error.localizedDescription }
                self.finish()
            }
        }
    }

    private func finish() { isLoading = false; isThinking = false; activeText = ""; task = nil }
    func cancel() {
        task?.cancel(); task = nil; revision = UUID()
        isLoading = false; isThinking = false; activeText = ""
    }
    func reset() { cancel(); answer = nil; sourceText = ""; message = nil }
    func settingsChanged() {
        reset()
        savedConfiguration = configuration()
    }
    func rejectOversizedPaste() {
        reset()
        message = "粘贴内容过长，请分段粘贴，每次最多 4000 字。"
    }
    deinit { task?.cancel() }
}
