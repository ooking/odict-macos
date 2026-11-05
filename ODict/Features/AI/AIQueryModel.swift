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
    @Published private(set) var answerModel = ""
    @Published private(set) var isRestoringHistory = false
    @Published private(set) var isViewingHistory = false
    @Published private(set) var isEditingInput = true
    var onSubmit: ((String) -> Void)?
    var onArchive: ((AIHistoryRecord) -> Void)?
    private let client: AIQueryServing
    private let configuration: () -> AIConfiguration
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var requestID = UUID()
    private var requestDate = Date()
    private var requestModel = ""
    private var answerID: UUID?
    private var answerDate = Date()
    private var archivedAnswerID: UUID?
    private var preparingToQuit = false
    var historyDate: Date? { isViewingHistory ? answerDate : nil }

    init(client: AIQueryServing = AIClient(), configuration: @escaping () -> AIConfiguration = { AISettingsStore.configuration }) {
        self.client = client; self.configuration = configuration
        savedConfiguration = configuration()
    }
    var isConfigured: Bool { !savedConfiguration.address.isEmpty && !savedConfiguration.model.isEmpty }
    var hasSubmitted: Bool { !submittedText.isEmpty }
    var isInputLocked: Bool { isLoading || isRestoringHistory || !isEditingInput }
    var isShowingPreviousAnswer: Bool { answer != nil && sourceText != submittedText && !hasStreamContent }

    func submit(_ raw: String) {
        guard !preparingToQuit else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading || submittedText != text else { return }
        guard text.count <= AIConfiguration.maximumInput else {
            message = "请输入 \(AIConfiguration.maximumInput) 字以内的内容。"; return
        }
        guard isConfigured else { message = AIError.configuration.localizedDescription; return }
        archivePartialAnswer()
        invalidateRequest()
        onSubmit?(text)
        requestID = UUID(); requestDate = Date(); requestModel = savedConfiguration.model
        isViewingHistory = false
        submittedText = text
        isCancelled = false
        hasStreamContent = false
        message = nil
        isLoading = true
        isEditingInput = false
        let token = revision
        let client = client
        task = Task { [weak self] in
            do {
                let answer = try await client.streamAnswer(text: text) { [weak self] update in
                    await self?.receive(update, token: token)
                }
                guard !Task.isCancelled, let self, token == self.revision else { return }
                self.answerID = self.requestID; self.answerDate = self.requestDate
                self.answerModel = self.requestModel
                self.answer = answer; self.sourceText = text
                self.hasStreamContent = true
                self.archiveAnswer(isPartial: false)
                self.finish()
            } catch {
                guard !Task.isCancelled, let self, token == self.revision else { return }
                self.message = (error as? URLError)?.code == .timedOut
                    ? "AI 响应超时，可以保留当前内容并重试。" : error.localizedDescription
                self.archivePartialAnswer()
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
            answerID = requestID; answerDate = requestDate; answerModel = requestModel
            if answer?.markdown != content { answer = AIAnswer(markdown: content) }
        }
    }
    private func finish() { isLoading = false; isThinking = false; task = nil }
    private func invalidateRequest() {
        task?.cancel(); task = nil; revision = UUID()
        isRestoringHistory = false
        isLoading = false; isThinking = false
    }
    func cancel() {
        guard isLoading else { return }
        archivePartialAnswer()
        invalidateRequest()
        isCancelled = true
        message = nil
    }
    func beginEditingInput() {
        guard !isLoading, !isRestoringHistory else { return }
        isEditingInput = true
    }
    func reset() {
        archivePartialAnswer()
        invalidateRequest()
        answer = nil; sourceText = ""; submittedText = ""; message = nil
        answerID = nil; archivedAnswerID = nil; answerModel = ""
        isCancelled = false; hasStreamContent = false
        isViewingHistory = false
        isEditingInput = true
    }
    // The history writer owns any pending disk write independently of this view.
    func suspend() { reset() }

    func beginHistoryRestore() { reset(); isRestoringHistory = true }
    func finishHistoryRestore() { isRestoringHistory = false }

    /// Restore already-decoded unified history without generating or archiving again.
    func restoreAnswer(_ record: AIHistoryRecord) {
        reset()
        answerID = record.id; archivedAnswerID = record.id; answerDate = record.date
        sourceText = record.source; submittedText = record.source
        answer = AIAnswer(markdown: record.markdown); answerModel = record.model
        isCancelled = record.isPartial; hasStreamContent = true; isViewingHistory = true; isEditingInput = false
    }

    private func archivePartialAnswer() {
        guard isLoading, hasStreamContent, sourceText == submittedText else { return }
        archiveAnswer(isPartial: true)
    }

    private func archiveAnswer(isPartial: Bool) {
        guard let id = answerID, archivedAnswerID != id, let answer, !answer.markdown.isEmpty else { return }
        let record = AIHistoryRecord(id: id, date: answerDate, source: sourceText,
            markdown: answer.markdown, model: answerModel, isPartial: isPartial)
        onArchive?(record)
        archivedAnswerID = id
    }
    func prepareForTermination() { preparingToQuit = true; cancel() }
    func cancelTerminationPreparation() { preparingToQuit = false }
    func settingsChanged() { reset(); savedConfiguration = configuration() }
    func rejectOversizedPaste() { message = "粘贴内容过长，请分段粘贴，每次最多 4000 字。" }
    deinit { task?.cancel() }
}
