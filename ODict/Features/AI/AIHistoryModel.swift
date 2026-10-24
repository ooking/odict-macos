import SwiftUI

/// One event-driven writer drains a bounded queue. A failed write stays available
/// in this session for retry; closing the result view cannot cancel an archive.
@MainActor
final class AIHistoryModel: ObservableObject {
    @Published private(set) var records: [AIHistorySummary] = []
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    private let store: AIHistoryStore
    private let preferences: UserDefaults
    private var saved: [AIHistorySummary] = []
    private var pending: [AIHistoryRecord] = []
    private var clearRequested = false
    private var trimRequested = false
    private var loaded = false
    private var worker: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadRevision = UUID()
    private enum Operation { case save(AIHistoryRecord), clear, trim }

    init(store: AIHistoryStore = .shared, preferences: UserDefaults = .standard) {
        self.store = store; self.preferences = preferences
    }

    func load() {
        retry()
        guard !loaded, !isLoading else { return }
        isLoading = true
        let token = UUID(); loadRevision = token
        loadTask = Task { [weak self, store] in
            defer { if self?.loadRevision == token { self?.isLoading = false; self?.loadTask = nil } }
            do {
                let rows = try await store.summaries()
                guard !Task.isCancelled, let self, self.loadRevision == token else { return }
                self.saved = rows.records; self.loaded = true
                if self.message == nil { self.message = rows.notice }
                self.refresh()
            } catch {
                guard !Task.isCancelled, self?.loadRevision == token else { return }
                self?.message = "暂时无法读取 AI 历史，请检查磁盘空间或文件权限后重试。"
            }
        }
    }

    func remember(_ record: AIHistoryRecord) {
        cancelLoad()
        pending.removeAll { $0.id == record.id }
        pending.append(record)
        boundPending()
        refresh(); retry()
    }

    func record(_ id: UUID) async throws -> AIHistoryRecord {
        if let value = pending.first(where: { $0.id == id }) { return value }
        return try await store.record(id)
    }

    func clear() {
        cancelLoad()
        loaded = true
        pending = []; saved = []; records = []
        clearRequested = true
        retry()
    }

    func settingsChanged() {
        cancelLoad()
        boundPending()
        trimRequested = true
        refresh(); retry()
    }

    func retry() {
        guard worker == nil, clearRequested || trimRequested || !pending.isEmpty else { return }
        isSaving = true
        message = nil
        worker = Task { [weak self, store] in
            while !Task.isCancelled {
                guard let operation = self?.nextOperation() else { break }
                do {
                    let rows: AIHistorySnapshot
                    switch operation {
                    case .save(let record): rows = try await store.save(record)
                    case .clear: rows = try await store.clear()
                    case .trim: rows = try await store.trim()
                    }
                    self?.completed(operation, rows: rows)
                } catch {
                    self?.failed(operation)
                    break
                }
            }
            self?.worker = nil; self?.isSaving = false
        }
    }

    func flush() async -> Bool {
        retry()
        await worker?.value
        return pending.isEmpty && !clearRequested && !trimRequested
    }

    private func nextOperation() -> Operation? {
        if clearRequested { clearRequested = false; return .clear }
        if trimRequested { trimRequested = false; return .trim }
        return pending.first.map(Operation.save)
    }

    private func completed(_ operation: Operation, rows: AIHistorySnapshot) {
        cancelLoad()
        if case .save(let record) = operation { pending.removeAll { $0.id == record.id } }
        if !clearRequested { saved = rows.records; loaded = true; message = rows.notice }
        refresh()
    }

    private func failed(_ operation: Operation) {
        if case .clear = operation { clearRequested = true }
        if case .trim = operation { trimRequested = true }
        message = pending.isEmpty ? "AI 历史操作未完成，请检查磁盘空间或文件权限后重试。"
            : "有 AI 结果尚未保存到磁盘，已暂存在本次会话，请重试保存。"
        refresh()
    }

    private func cancelLoad() {
        loadRevision = UUID(); loadTask?.cancel(); loadTask = nil; isLoading = false
    }

    private func boundPending() {
        let capacity = AIHistorySettings.capacity(in: preferences)
        if pending.count > capacity { pending.removeFirst(pending.count - capacity) }
    }

    private func refresh() {
        var seen = Set<UUID>()
        records = (pending.map(\.summary) + saved).filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }.prefix(AIHistorySettings.capacity(in: preferences)).map { $0 }
    }

    deinit { loadTask?.cancel() }
}
