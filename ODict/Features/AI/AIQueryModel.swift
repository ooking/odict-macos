import SwiftUI

@MainActor
final class AIQueryModel: ObservableObject {
    @Published private(set) var answer: AIAnswer?
    @Published private(set) var sourceText = ""
    @Published private(set) var submittedText = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isThinking = false
    @Published private(set) var isCancelled = false
    @Published private(set) var hasStreamContent = false
    @Published private(set) var message: String?
    @Published private(set) var savedConfiguration: AIConfiguration
    private let client: AIQueryServing
    private let configuration: () -> AIConfiguration
    private var task: Task<Void, Never>?
    private var revision = UUID()

    init(client: AIQueryServing = AIClient(), configuration: @escaping () -> AIConfiguration = { AISettingsStore.configuration }) {
        self.client = client; self.configuration = configuration
        savedConfiguration = configuration()
    }
    var isConfigured: Bool { !savedConfiguration.address.isEmpty && !savedConfiguration.model.isEmpty }
    var hasSubmitted: Bool { !submittedText.isEmpty }
    var isShowingPreviousAnswer: Bool { answer != nil && sourceText != submittedText && !hasStreamContent }

    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading || submittedText != text else { return }
        guard text.count <= AIConfiguration.maximumInput else {
            message = "请输入 \(AIConfiguration.maximumInput) 字以内的内容。"; return
        }
        guard isConfigured else { message = AIError.configuration.localizedDescription; return }
        invalidateRequest()
        submittedText = text
        isCancelled = false
        hasStreamContent = false
        message = nil
        isLoading = true
        let token = revision
        let client = client
        task = Task { [weak self] in
            do {
                let answer = try await client.streamAnswer(text: text) { [weak self] update in
                    await self?.receive(update, token: token)
                }
                guard !Task.isCancelled, let self, token == self.revision else { return }
                self.answer = answer; self.sourceText = text
                self.hasStreamContent = true
                self.finish()
            } catch {
                guard !Task.isCancelled, let self, token == self.revision else { return }
                self.message = (error as? URLError)?.code == .timedOut
                    ? "AI 响应超时，可以保留当前内容并重试。" : error.localizedDescription
                self.finish()
            }
        }
    }
    private func receive(_ update: AIStreamUpdate, token: UUID) {
        guard token == revision, isLoading else { return }
        switch update {
        case .thinking:
            if !hasStreamContent { isThinking = true }
        case .text(let content):
            guard !content.isEmpty else { return }
            isThinking = false
            hasStreamContent = true
            sourceText = submittedText
            if answer?.markdown != content { answer = AIAnswer(markdown: content) }
        }
    }
    private func finish() { isLoading = false; isThinking = false; task = nil }
    private func invalidateRequest() {
        task?.cancel(); task = nil; revision = UUID()
        isLoading = false; isThinking = false
    }
    func cancel() {
        guard isLoading else { return }
        invalidateRequest()
        isCancelled = true
        message = nil
    }
    func reset() {
        invalidateRequest()
        answer = nil; sourceText = ""; submittedText = ""; message = nil
        isCancelled = false; hasStreamContent = false
    }
    func settingsChanged() { reset(); savedConfiguration = configuration() }
    func rejectOversizedPaste() { message = "粘贴内容过长，请分段粘贴，每次最多 4000 字。" }
    deinit { task?.cancel() }
}
