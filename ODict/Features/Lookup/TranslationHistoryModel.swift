import SwiftUI

/// Event-driven disk queue. Only summaries and bounded, not-yet-written answers
/// are retained. A window closing cannot cancel a pending archive.
@MainActor
final class TranslationHistoryModel: ObservableObject {
    @Published private(set) var groups: [TranslationHistoryGroup] = []
    @Published private(set) var message: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isLoading = false
    private let store: TranslationHistoryStore
    private enum Operation {
        case save(TranslationHistoryRecord), select(String, TranslationMethod), clear, trim
    }
    private struct Pending { let id = UUID(); let operation: Operation; let cost: Int }
    private var pending: [Pending] = []
    private var worker: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var loaded = false

    init(store: TranslationHistoryStore = .shared) { self.store = store }
    func load() {
        retry()
        guard !loaded, !isLoading, worker == nil else { return }
        isLoading = true
        let token = generation
        loadTask = Task { [weak self, store] in
            do {
                let values = try await store.summaries()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.groups = values; self.loaded = true; self.message = nil
            } catch {
                if self?.generation == token { self?.message = "无法读取查询历史，请检查磁盘空间与文件权限后重试。" }
            }
            if self?.generation == token { self?.isLoading = false; self?.loadTask = nil }
        }
    }
    func remember(_ record: TranslationHistoryRecord) {
        let cost: Int
        switch record.payload {
        case .ai(let markdown, let model, _): cost = markdown.utf8.count + model.utf8.count + 4096
        case .online(let entry): cost = entry.estimatedPayloadBytes + 4096
        case .system(_, let text): cost = text.utf8.count
        case .mdx: cost = 4096
        }
        guard pending.count < 256, pending.reduce(0, { $0 + $1.cost }) + cost <= 16 * 1024 * 1024 else {
            message = "历史写入积压，当前结果未加入保存队列，请在磁盘恢复后重新查询。"; return
        }
        enqueue(.save(record), cost: cost)
    }
    func select(source: String, method: TranslationMethod) {
        pending.removeAll { item in
            guard item.id != activeID else { return false }
            if case .select(let existing, _) = item.operation { return existing == source }
            return false
        }
        enqueue(.select(source, method))
    }
    func record(source: String, method: TranslationMethod) async throws -> TranslationHistoryRecord? {
        for item in pending.reversed() {
            if case .clear = item.operation { return nil }
            if case .save(let record) = item.operation, record.source == source, record.method == method { return record }
        }
        return try await store.record(source: source, method: method)
    }
    func clear() {
        // In-flight disk work finishes first; the clear operation then removes it.
        pending = pending.filter { $0.id == activeID }
        groups = []
        enqueue(.clear)
    }
    func settingsChanged() {
        guard !pending.contains(where: { if case .trim = $0.operation { return true }; return false }) else { return }
        enqueue(.trim)
    }
    private var activeID: UUID?
    private func enqueue(_ operation: Operation, cost: Int = 0) {
        generation = UUID(); loadTask?.cancel(); loadTask = nil; isLoading = false
        pending.append(Pending(operation: operation, cost: cost)); retry()
    }
    func retry() {
        guard worker == nil, !pending.isEmpty else { return }
        isSaving = true; message = nil
        worker = Task { [weak self, store] in
            while let item = self?.pending.first {
                self?.activeID = item.id
                do {
                    let rows: [TranslationHistoryGroup]
                    switch item.operation {
                    case .save(let record): rows = try await store.save(record)
                    case .select(let source, let method): rows = try await store.select(source: source, method: method)
                    case .clear: rows = try await store.clear()
                    case .trim: rows = try await store.trim()
                    }
                    guard let self else { break }
                    self.pending.removeAll { $0.id == item.id }
                    let clearing = self.pending.contains { if case .clear = $0.operation { return true }; return false }
                    if !clearing { self.groups = rows }
                    self.loaded = true
                } catch {
                    let isClearing: Bool
                    if case .clear = item.operation { isClearing = true } else { isClearing = false }
                    if !isClearing, let self,
                       self.pending.contains(where: { if case .clear = $0.operation { return true }; return false }) {
                        self.pending.removeAll { $0.id == item.id }
                        continue
                    }
                    self?.message = "查询历史尚未完成保存，请检查磁盘空间或文件权限后重试。"
                    break
                }
            }
            self?.activeID = nil; self?.worker = nil; self?.isSaving = false
        }
    }
    func flush() async -> Bool { retry(); await worker?.value; return pending.isEmpty }
    deinit { loadTask?.cancel() }
}
