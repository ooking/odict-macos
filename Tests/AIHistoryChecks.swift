import Foundation

private actor HistoryFixtureAI: AIQueryServing {
    private(set) var calls = 0
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        calls += 1
        return AIAnswer(markdown: "完整回答：" + String(repeating: text, count: 600))
    }
}

private actor PartialHistoryAI: AIQueryServing {
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        throw AIError.invalidResponse
    }
    func streamAnswer(text: String, onUpdate: @escaping @Sendable (AIStreamUpdate) async -> Void) async throws -> AIAnswer {
        await onUpdate(.text("已收到的部分回答"))
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return AIAnswer(markdown: "不应等待到这里")
    }
}

private actor LateHistoryAI: AIQueryServing {
    private var pending: [String: CheckedContinuation<AIAnswer, Never>] = [:]
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        await withCheckedContinuation { pending[text] = $0 }
    }
    func has(_ text: String) -> Bool { pending[text] != nil }
    func finish(_ text: String) { pending.removeValue(forKey: text)?.resume(returning: AIAnswer(markdown: text + " 的回答")) }
}

@main
private struct AIHistoryChecks {
    @MainActor
    private static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for a history operation")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @MainActor
    static func main() async throws {
        let suite = "ODict.AIHistoryChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        precondition(AIHistorySettings.capacity(in: preferences) == 20)
        let folder = root.appendingPathComponent("records", isDirectory: true)
        let store = AIHistoryStore(folder: folder, preferences: preferences)
        var ids: [UUID] = []
        for i in 0..<21 {
            let id = UUID(); ids.append(id)
            let record = AIHistoryRecord(id: id, date: Date(timeIntervalSince1970: Double(i)),
                source: "source-\(i)", markdown: "answer-\(i)", model: "fixture-model", isPartial: false)
            _ = try await store.save(record)
        }
        let saved = try await store.summaries()
        precondition(saved.records.count == 20 && saved.records.first?.id == ids.last)
        precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(ids[0].uuidString + ".json").path))
        let reopened = AIHistoryStore(folder: folder, preferences: preferences)
        let loaded = try await reopened.record(ids[20])
        precondition(loaded.source == "source-20" && loaded.markdown == "answer-20")

        // A missing index recovers the independently committed complete answers.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("index.json"))
        let recoveredStore = AIHistoryStore(folder: folder, preferences: preferences)
        let recovered = try await recoveredStore.summaries()
        precondition(recovered.records.count == 20)
        let damagedURL = folder.appendingPathComponent(UUID().uuidString + ".json")
        try Data("damaged fixture".utf8).write(to: damagedURL)
        let tolerantStore = AIHistoryStore(folder: folder, preferences: preferences)
        let tolerant = try await tolerantStore.summaries()
        precondition(tolerant.records.count == 20 && tolerant.notice != nil)
        precondition(FileManager.default.fileExists(atPath: damagedURL.path))

        preferences.set(2, forKey: AIHistorySettings.capacityKey)
        let trimmed = try await tolerantStore.trim()
        precondition(trimmed.records.count == 2)

        // Model output is restored byte-for-byte without invoking the provider.
        preferences.set(20, forKey: AIHistorySettings.capacityKey)
        let modelStore = AIHistoryStore(folder: root.appendingPathComponent("model"), preferences: preferences)
        let history = AIHistoryModel(store: modelStore, preferences: preferences)
        let client = HistoryFixtureAI()
        var config = AIConfiguration(); config.model = "fixture-model"; config.address = "https://fixture.invalid/v1"
        let configuration = config
        let model = AIQueryModel(client: client, configuration: { configuration }, history: history)
        model.submit("original")
        try await wait { !model.isLoading }
        let expected = model.answer!.markdown
        let flushed = await history.flush()
        precondition(flushed && history.records.count == 1)
        let id = history.records[0].id
        model.suspend()
        precondition(model.answer == nil && model.sourceText.isEmpty && model.submittedText.isEmpty)
        var restoredInput = ""
        model.restoreHistory(id) { restoredInput = $0 }
        try await wait { !model.isRestoringHistory }
        precondition(model.answer?.markdown == expected && restoredInput == "original")
        precondition(model.answerModel == "fixture-model" && model.isViewingHistory)
        let calls = await client.calls
        precondition(calls == 1, "Opening history must not request AI")

        // Stopping/closing a stream retains partial output exactly once.
        let partial = AIQueryModel(client: PartialHistoryAI(), configuration: { configuration }, history: history)
        partial.submit("unfinished")
        try await wait { partial.hasStreamContent }
        partial.suspend()
        let partialSaved = await history.flush()
        precondition(partialSaved && partial.answer == nil)
        let partialID = history.records.first(where: { $0.sourcePreview == "unfinished" })!.id
        let partialRecord = try await history.record(partialID)
        precondition(partialRecord.isPartial && partialRecord.markdown == "已收到的部分回答")

        // Clear queued/in-flight data before new records, rather than allowing
        // a late save completion to resurrect cleared history.
        history.clear()
        let newest = AIHistoryRecord(id: UUID(), date: Date(), source: "after clear", markdown: "keep this", model: "fixture", isPartial: false)
        history.remember(newest)
        let cleared = await history.flush()
        let clearState = try await modelStore.summaries()
        precondition(cleared && clearState.records.map(\.id) == [newest.id])

        // An unavailable destination retains an in-session copy for retry.
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let retryStore = AIHistoryStore(folder: blocked, preferences: preferences)
        let retryHistory = AIHistoryModel(store: retryStore, preferences: preferences)
        retryHistory.remember(newest)
        let failed = await retryHistory.flush()
        precondition(!failed && retryHistory.message != nil)
        let unsaved = try await retryHistory.record(newest.id)
        precondition(unsaved.markdown == newest.markdown)
        try FileManager.default.removeItem(at: blocked)
        let retried = await retryHistory.flush()
        precondition(retried)

        // A provider that ignores cancellation must not archive its old response.
        let lateClient = LateHistoryAI()
        let lateHistory = AIHistoryModel(store: AIHistoryStore(folder: root.appendingPathComponent("late"), preferences: preferences), preferences: preferences)
        let lateModel = AIQueryModel(client: lateClient, configuration: { configuration }, history: lateHistory)
        lateModel.submit("old")
        let oldDeadline = Date().addingTimeInterval(5)
        while !(await lateClient.has("old")) {
            precondition(Date() < oldDeadline)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        lateModel.submit("new")
        let newDeadline = Date().addingTimeInterval(5)
        while !(await lateClient.has("new")) {
            precondition(Date() < newDeadline)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await lateClient.finish("new")
        try await wait { !lateModel.isLoading }
        await lateClient.finish("old")
        try await Task.sleep(nanoseconds: 20_000_000)
        let lateSaved = await lateHistory.flush()
        precondition(lateSaved && lateHistory.records.count == 1 && lateHistory.records[0].sourcePreview == "new")
        print("PASS: default capacity, retention, restart/index recovery, corrupt-file isolation, lazy restore without AI calls, partial output, result release, clear ordering, write retry, stale-response protection. Temporary fixtures only.")
    }
}
