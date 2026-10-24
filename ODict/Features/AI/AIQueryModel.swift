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
    let history: AIHistoryModel
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
    private var restoreTask: Task<Void, Never>?
    private var preparingToQuit = false
    var historyDate: Date? { isViewingHistory ? answerDate : nil }

    init(client: AIQueryServing = AIClient(), configuration: @escaping () -> AIConfiguration = { AISettingsStore.configuration },
         history: AIHistoryModel? = nil) {
        self.client = client; self.configuration = configuration
        self.history = history ?? AIHistoryModel()
        savedConfiguration = configuration()
    }
    var isConfigured: Bool { !savedConfiguration.address.isEmpty && !savedConfiguration.model.isEmpty }
    var hasSubmitted: Bool { !submittedText.isEmpty }
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
        requestID = UUID(); requestDate = Date(); requestModel = savedConfiguration.model
        isViewingHistory = false
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
        restoreTask?.cancel(); restoreTask = nil; isRestoringHistory = false
        isLoading = false; isThinking = false
    }
    func cancel() {
        guard isLoading else { return }
        archivePartialAnswer()
        invalidateRequest()
        isCancelled = true
        message = nil
    }
    func reset() {
        archivePartialAnswer()
        invalidateRequest()
        answer = nil; sourceText = ""; submittedText = ""; message = nil
        answerID = nil; archivedAnswerID = nil; answerModel = ""
        isCancelled = false; hasStreamContent = false
        isViewingHistory = false
    }
    // The history writer owns any pending disk write independently of this view.
    func suspend() { reset() }

    func restoreHistory(_ id: UUID, restoredInput: @escaping (String) -> Void) {
        guard !preparingToQuit else { return }
        archivePartialAnswer()
        invalidateRequest()
        let token = revision
        isRestoringHistory = true
        restoreTask = Task { [weak self, history] in
            defer { if self?.revision == token { self?.isRestoringHistory = false; self?.restoreTask = nil } }
            do {
                let record = try await history.record(id)
                guard !Task.isCancelled, let self, self.revision == token else { return }
                self.answerID = record.id; self.archivedAnswerID = record.id
                self.answerDate = record.date; self.answerModel = record.model
                self.sourceText = record.source; self.submittedText = record.source
                self.answer = AIAnswer(markdown: record.markdown)
                self.isCancelled = record.isPartial; self.hasStreamContent = true; self.message = nil
                self.isViewingHistory = true
                restoredInput(record.source)
            } catch {
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.message = "无法打开这条 AI 历史记录，原文件未作修改。"
            }
        }
    }

    private func archivePartialAnswer() {
        guard isLoading, hasStreamContent, sourceText == submittedText else { return }
        archiveAnswer(isPartial: true)
    }

    private func archiveAnswer(isPartial: Bool) {
        guard let id = answerID, archivedAnswerID != id, let answer, !answer.markdown.isEmpty else { return }
        history.remember(AIHistoryRecord(id: id, date: answerDate, source: sourceText,
            markdown: answer.markdown, model: answerModel, isPartial: isPartial))
        archivedAnswerID = id
    }
    func prepareForTermination() { preparingToQuit = true; cancel() }
    func cancelTerminationPreparation() { preparingToQuit = false }
    func settingsChanged() { reset(); savedConfiguration = configuration() }
    func rejectOversizedPaste() { message = "粘贴内容过长，请分段粘贴，每次最多 4000 字。" }
    deinit { task?.cancel(); restoreTask?.cancel() }
}
