import Foundation

private func envelope(_ content: String, finish: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content, "reasoning_content": "not shown"], "finish_reason": finish]]])
}
private let valid = "## 译文\n\n你好。"
private final class FixtureTransport: HTTPTransporting {
    var request: URLRequest?
    var status = 200
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (try envelope(valid), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private actor DeferredAI: AIQueryServing {
    private var pending: [String: CheckedContinuation<AIAnswer, Error>] = [:]
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        try await withCheckedThrowingContinuation { pending[text] = $0 }
    }
    func has(_ text: String) -> Bool { pending[text] != nil }
    func finish(_ text: String) {
        pending.removeValue(forKey: text)?.resume(returning: AIAnswer(markdown: text))
    }
}
private final class FixtureDictionary: DictionaryLookupServing {
    var calls = 0
    func entry(_ word: String) async throws -> LookupResult { calls += 1; throw DictionaryError.notFound }
    func suggestions(_ query: String) async throws -> [Suggestion] { calls += 1; return [] }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { calls += 1; return [] }
    func releaseLocalResources() async {}
}

@main private struct AIQueryChecks {
    static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("invalid input accepted") } catch {}
    }
    static func waitFor(_ fixture: DeferredAI, _ text: String) async throws {
        for _ in 0..<200 {
            if await fixture.has(text) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("fixture never started")
    }
    @MainActor static func main() async throws {
        let answer = try AIClient.parse(envelope(valid))
        precondition(answer.markdown == valid)
        let withThinking = try AIClient.parse(envelope("<think>private reasoning</think>\n\(valid)"))
        precondition(withThinking.markdown == answer.markdown)
        rejects { _ = try AIClient.parse(envelope(valid, finish: "length")) }
        rejects { _ = try AIClient.parse(envelope("<think>unfinished")) }
        rejects { _ = try AIClient.parse(envelope("   ")) }
        rejects { _ = try AIClient.parse(envelope(String(repeating: "中", count: 50000))) }
        let flexible = try AIClient.parse(envelope("# 自定义内容\n\n- **重点**\n- 不要求 JSON 字段"))
        precondition(flexible.markdown.contains("**重点**"))
        let cloudURL = try AIEndpoint("https://fixture.invalid/v1/").url
        let localURL = try AIEndpoint("http://localhost:11434/v1/chat/completions").url
        precondition(cloudURL.absoluteString == "https://fixture.invalid/v1/chat/completions")
        precondition(localURL.path == "/v1/chat/completions")
        for invalid in ["http://remote.invalid/v1", "https://user:secret@fixture.invalid", "https://fixture.invalid?key=secret", "file:///tmp/query"] {
            rejects { _ = try AIEndpoint(invalid) }
        }
        var configuration = AIConfiguration()
        configuration.address = "https://fixture.invalid/v1"
        configuration.model = "fixture"
        configuration.thinkingFormat = .enableThinking
        configuration.thinking = true
        configuration.translationPrompt = "请直接给出译文，不增加额外解释。"
        let transport = FixtureTransport()
        let client = AIClient(transportFactory: { _ in transport })
        _ = try await client.answer(text: "Hello.", kind: .translation, target: .english,
                                    settings: AISavedSettings(configuration: configuration, key: "fixture-only"))
        let request = transport.request!
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        precondition(body["enable_thinking"] as? Bool == true)
        precondition(request.timeoutInterval == 180)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        precondition(messages[0]["role"] == "system" && messages[0]["content"]!.contains("Markdown"))
        precondition(messages[1]["content"]!.contains(configuration.translationPrompt))
        precondition(!messages[0]["content"]!.contains(configuration.translationPrompt))
        for format in [AIThinkingFormat.thinkingType, .reasoningEffort] {
            configuration.thinkingFormat = format
            _ = try await client.answer(text: "Hello.", kind: .translation, target: nil,
                                        settings: AISavedSettings(configuration: configuration, key: ""))
            let body = try JSONSerialization.jsonObject(with: transport.request!.httpBody!) as! [String: Any]
            if format == .thinkingType { precondition((body["thinking"] as? [String: String])?["type"] == "enabled") }
            else { precondition(body["reasoning_effort"] as? String == "medium") }
        }
        configuration.thinking = false
        configuration.thinkingFormat = .automatic
        _ = try await client.answer(text: "Hello.", kind: .translation, target: nil,
                                    settings: AISavedSettings(configuration: configuration, key: ""))
        let defaultBody = try JSONSerialization.jsonObject(with: transport.request!.httpBody!) as! [String: Any]
        precondition(defaultBody["thinking"] == nil && defaultBody["enable_thinking"] == nil && defaultBody["reasoning_effort"] == nil)
        configuration.thinking = true
        rejects { try AISettingsStore.validate(configuration, key: "") }
        configuration.thinking = false
        transport.status = 401
        do {
            _ = try await client.answer(text: "Hello.", kind: .translation, target: nil,
                                        settings: AISavedSettings(configuration: configuration, key: "fixture-only"))
            preconditionFailure("HTTP error accepted")
        } catch AIError.http(401) {}
        configuration.address = "http://localhost:11434/v1"
        transport.status = 200
        _ = try await client.answer(text: "Hello.", kind: .translation, target: nil,
                                    settings: AISavedSettings(configuration: configuration, key: ""))
        let ollamaBody = try JSONSerialization.jsonObject(with: transport.request!.httpBody!) as! [String: Any]
        precondition(ollamaBody["response_format"] == nil, "Markdown requests must not constrain output to JSON")
        precondition(ollamaBody["reasoning_effort"] as? String == "none")
        precondition(ollamaBody["max_tokens"] as? Int == 2048)
        let fixedConfiguration = configuration
        let deferred = DeferredAI()
        let suite = "odict.ai.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let historyFolder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: historyFolder)
        }
        let history = AIHistoryModel(store: AIHistoryStore(folder: historyFolder, preferences: defaults), preferences: defaults)
        let model = AIQueryModel(client: deferred, configuration: { fixedConfiguration }, history: history)
        model.submit("old")
        try await waitFor(deferred, "old")
        model.submit("new")
        try await waitFor(deferred, "new")
        await deferred.finish("new")
        try await Task.sleep(nanoseconds: 20_000_000)
        await deferred.finish("old")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(model.answer?.markdown == "new", "old response must never replace a new result")
        model.submit("cancel")
        try await waitFor(deferred, "cancel")
        model.reset()
        await deferred.finish("cancel")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(model.answer == nil && !model.isLoading && model.sourceText.isEmpty)
        model.submit(String(repeating: "a", count: 4001))
        precondition(model.message != nil && !model.isLoading)

        let dictionary = FixtureDictionary()
        let lookup = LookupModel(router: dictionary, history: RecentWordsStore(defaults: defaults), preferences: defaults, ai: model)
        lookup.setMode(.ai)
        lookup.editQuery("manual", composing: false)
        precondition(dictionary.calls == 0 && !model.isLoading, "typing in AI mode must not invoke either service")
        defaults.set(QueryMode.dictionary.rawValue, forKey: QueryMode.captureKey)
        lookup.lookupCaptured("word")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(lookup.mode == .dictionary && dictionary.calls > 0)
        lookup.beginManual()
        precondition(lookup.mode == .ai, "capture preference must not overwrite manual mode")
        lookup.suspend()
        precondition(!model.isLoading && model.answer == nil)
        let historySaved = await history.flush()
        precondition(historySaved)
        print("PASS: bounded Markdown; reasoning separation; endpoint safety; fixed Markdown instruction; thinking adapters; auth errors; stale responses; cancellation; independent modes. No live network, Keychain, or UI used.")
    }
}
