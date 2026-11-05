import Foundation

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

private final class HistoryDictionary: DictionaryLookupServing {
    var methods: [TranslationMethod] = []
    func entry(_ word: String) async throws -> LookupResult { try await entry(word, method: .automatic) }
    func entry(_ word: String, method: TranslationMethod) async throws -> LookupResult {
        methods.append(method)
        // Deliberately ignore cancellation: the model must reject late responses.
        if word == "slow" { try? await Task.sleep(nanoseconds: 100_000_000) }
        if case .mdx = method { throw DictionaryError.notFound }
        return LookupResult(remote: Entry(id: 1, word: word, phonetic: "p", definition: "full definition",
            translation: method.id, tags: [], partsOfSpeech: [], inflections: []), local: nil, notice: nil)
    }
    func suggestions(_ query: String) async throws -> [Suggestion] { [] }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { [] }
    func releaseLocalResources() async {}
}

@main private struct AIHistoryChecks {
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for history")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    @MainActor static func main() async throws {
        let suite = "ODict.TranslationHistoryChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TranslationHistoryStore(folder: root, preferences: preferences)
        let online = Entry(id: 42, word: "Apple", phonetic: "phonetic", definition: String(repeating: "definition", count: 1000),
            translation: "苹果", tags: [.init(code: "fixture", name: "fixture")], partsOfSpeech: [],
            inflections: [.init(type: "plural", typeName: "复数", form: "Apples")])
        _ = try await store.save(.init(id: UUID(), date: Date(), source: "Apple", method: .online,
            title: "在线词典", payload: .online(online)))
        let aiID = UUID()
        _ = try await store.save(.init(id: aiID, date: Date(), source: "Apple", method: .ai,
            title: "AI", payload: .ai(markdown: "complete answer", model: "fixture", partial: false)))
        let rows = try await store.summaries()
        precondition(rows.count == 1 && rows[0].variants.count == 2 && rows[0].selectedMethod == .ai,
                     "group exact source once, retain every method, display last selection")
        _ = try await store.select(source: "Apple", method: .online)
        let reopened = TranslationHistoryStore(folder: root, preferences: preferences)
        let restored = try await reopened.record(source: "Apple", method: .online)
        guard case .online(let entry) = restored?.payload else { preconditionFailure("restore online") }
        precondition(entry.definition == online.definition && entry.inflections.first?.form == "Apples",
                     "full structured remote results survive disk round trip")
        let previousAI = try await reopened.record(source: "Apple", method: .ai)
        precondition(previousAI?.id == aiID, "switching does not overwrite another method's answer")
        _ = try await reopened.save(.init(id: UUID(), date: Date(), source: "Apple", method: .ai,
            title: "AI", payload: .ai(markdown: "replacement", model: "fixture-2", partial: false)))
        let updated = try await reopened.summaries()
        precondition(updated.count == 1 && updated[0].variants.count == 2, "same method replaces its old version")
        _ = try await reopened.save(.init(id: UUID(), date: Date(), source: "apple", method: .ai,
            title: "AI", payload: .ai(markdown: "lowercase", model: "fixture", partial: false)))
        let cases = try await reopened.summaries()
        precondition(cases.count == 2, "case-distinct sources must not merge")
        preferences.set(1, forKey: TranslationHistorySettings.capacityKey)
        let trimmed = try await reopened.trim()
        precondition(trimmed.count == 1 && trimmed[0].source == "apple", "trim by source, never by individual answer")
        preferences.set(20, forKey: TranslationHistorySettings.capacityKey)

        let modelStore = TranslationHistoryStore(folder: root.appendingPathComponent("model"), preferences: preferences)
        let history = TranslationHistoryModel(store: modelStore)
        var config = AIConfiguration(); config.address = "https://fixture.invalid/v1"; config.model = "fixture"
        let fixedConfig = config
        let ai = AIQueryModel(client: PartialHistoryAI(), configuration: { fixedConfig })
        let dictionary = HistoryDictionary()
        let model = LookupModel(router: dictionary, preferences: preferences, ai: ai, translationHistory: history, onlineAvailability: { false })
        precondition(model.selectedMethod == .automatic, "new session always starts automatic")
        model.selectMethod(.ai)
        model.editQuery("draft", composing: false)
        model.selectMethod(.online)
        precondition(model.query == "draft" && !ai.hasSubmitted, "draft changes preserve input without submitting AI")
        model.lookup("word")
        try await wait { !model.isLoading }
        model.selectMethod(.ai)
        try await wait { ai.hasStreamContent }
        model.selectMethod(.system)
        try await wait { !model.isLoading && !ai.isLoading }
        let flushed = await history.flush()
        precondition(flushed)
        let partial = try await history.record(source: "word", method: .ai)
        guard case .ai(let markdown, _, let isPartial) = partial?.payload else { preconditionFailure("save partial on switch") }
        precondition(isPartial && markdown == "已收到的部分回答")
        precondition(history.groups.first?.variants.count == 3 && history.groups.first?.selectedMethod == .system)
        model.selectMethod(.ai)
        try await wait { !model.isLoading }
        precondition(!ai.isLoading && ai.isInputLocked && ai.answer?.markdown == markdown,
                     "switch to saved AI result restores without generating and keeps composer read-only")
        model.suspend()
        model.beginManual(); model.resume()
        try await wait { !model.isLoading }
        precondition(model.selectedMethod == .ai && ai.answer?.markdown == markdown, "session method survives window closing")
        model.lookupCaptured("capture")
        try await wait { ai.hasStreamContent }
        precondition(model.selectedMethod == .ai, "capture shares the session choice")
        model.beginManual()
        precondition(model.query == "word", "capture does not overwrite manual input")
        model.selectMethod(.online)
        try await wait { !model.isLoading }
        model.lookup("slow")
        model.selectMethod(.system)
        try await wait { !model.isLoading }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.entry?.translation == TranslationMethod.system.id, "old source cannot replace new source")
        model.clearHistory()
        let cleared = await history.flush()
        precondition(cleared && history.groups.isEmpty, "clear removes every method, including queued partial answers")
        preferences.set(0, forKey: TranslationHistorySettings.capacityKey)
        model.lookup("not retained")
        try await wait { !model.isLoading }
        let zeroSaved = await history.flush()
        precondition(zeroSaved && history.groups.isEmpty, "zero capacity disables persistent history")
        model.suspend()
        print("PASS: grouped history; complete remote payload; per-method replacement; case identity; capacity; partial archive; shared session choice; AI read-only restore; cancellation; clear. No live network or UI used.")
    }
}
