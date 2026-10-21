import Foundation

private final class FixtureDictionary: DictionaryServing {
    var entryRequests: [String] = []
    func suggestions(_ query: String) async throws -> [Suggestion] {
        if query == "failure" { throw DictionaryError.server(503) }
        if query == "empty" { return [] }
        if query == "single" { return [suggestion("unique")] }
        if query == "many" { return (0..<30).map { suggestion("word\($0)") } }
        if query == "duplicates" { return [suggestion("same"), suggestion("same"), suggestion("SAME"), suggestion("")] }
        if query == "slow" { try? await Task.sleep(nanoseconds: 300_000_000); return [suggestion("stale")] }
        return ["play", "player", "playing", "playground"].map(suggestion)
    }
    private func suggestion(_ word: String) -> Suggestion {
        Suggestion(word: word, phonetic: nil, translationPreview: "释义", translation: nil)
    }
    func entry(_ word: String) async throws -> Entry {
        entryRequests.append(word)
        if word == "entry-failure" { throw DictionaryError.server(503) }
        if word == "misspelled" { throw DictionaryError.notFound }
        try await Task.sleep(nanoseconds: 40_000_000)
        return Entry(id: 1, word: word, phonetic: nil, definition: "A definition", translation: "释义",
                     tags: [], partsOfSpeech: [], inflections: [])
    }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { [suggestion("unique")] }
}

@main
private struct LookupModelChecks {
    @MainActor
    static func settled(_ model: LookupModel) async throws {
        for _ in 0..<200 {
            if !model.isSuggesting && !model.isLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("request never settled")
    }

    @MainActor
    static func main() async throws {
        let fixture = FixtureDictionary()
        let suite = "odict.lookup.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LookupModel(dictionary: fixture, history: RecentWordsStore(defaults: defaults), preferences: defaults)
        let localRouter = FixtureLocalRouter()
        let history = RecentWordsStore(defaults: defaults)
        _ = history.remember("old-word", in: [])
        let localModel = LookupModel(router: localRouter, history: history, preferences: defaults)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(localRouter.requests.isEmpty && localModel.recentTranslations["old-word"] == nil,
                     "loading history must not backfill old records")
        localModel.lookup("apple")
        try await settled(localModel)
        precondition(localModel.recentTranslations["apple"] == "苹果", "save local lookup summary")
        let restored = LookupModel(router: localRouter, history: history, preferences: defaults)
        precondition(restored.recentTranslations["apple"] == "苹果" && localRouter.requests == ["apple"],
                     "restore saved local summary without additional lookups")
        localModel.clearHistory()
        precondition(history.load().isEmpty && history.loadTranslations(for: ["apple"]).isEmpty,
                     "clear words and their summaries together")
        let draftModel = LookupModel(router: localRouter, history: history, preferences: defaults)
        draftModel.lookupHovered("hover-only")
        try await settled(draftModel)
        draftModel.suspend()
        draftModel.beginManual()
        draftModel.resume()
        precondition(draftModel.query.isEmpty && draftModel.result == nil && !draftModel.isLoading,
                     "hover without a manual draft must reopen an empty input and no captured result")
        draftModel.editQuery("typed-draft", composing: true)
        draftModel.suspend()
        draftModel.beginManual()
        precondition(draftModel.query == "typed-draft", "manual input must survive closing")
        for captured in ["selected-word", "screenshot-word"] {
            draftModel.lookupCaptured(captured)
            try await settled(draftModel)
            draftModel.suspend()
            draftModel.beginManual()
            precondition(draftModel.query == "typed-draft" && draftModel.result == nil,
                         "captured queries must not overwrite the manual draft or retain captured results")
        }
        draftModel.presentCaptureStatus("未识别到文字", busy: false)
        draftModel.beginManual()
        precondition(draftModel.query == "typed-draft" && draftModel.captureStatus == nil,
                     "capture status must restore the manual draft too")
        draftModel.lookup("history-or-link")
        try await settled(draftModel)
        draftModel.beginManual()
        precondition(draftModel.query == "typed-draft", "result navigation must not overwrite manual input")
        draftModel.editQuery("", composing: false)
        draftModel.lookupHovered("after-clear")
        try await settled(draftModel)
        draftModel.beginManual()
        draftModel.resume()
        precondition(draftModel.query.isEmpty && draftModel.result == nil && !draftModel.isLoading,
                     "explicitly clearing the input must clear the saved manual draft")
        // Repeated hits at different screen positions must share the visible
        // capture request/result, but hide, failure and source changes must retry.
        let hoverFixture = FixtureDictionary()
        let hoverModel = LookupModel(dictionary: hoverFixture, history: history, preferences: defaults)
        hoverModel.lookupHovered("echo")
        hoverModel.lookupHovered("echo")
        try await settled(hoverModel)
        precondition(hoverFixture.entryRequests == ["echo"], "duplicate hover must share its in-flight query")
        hoverModel.lookupHovered(" echo ")
        precondition(hoverModel.entry?.word == "echo" && !hoverModel.isLoading,
                     "same visible hover must retain its answer without a loading flash")
        try await settled(hoverModel)
        precondition(hoverFixture.entryRequests == ["echo"], "same visible word must not request again")
        hoverModel.lookupHovered("next")
        try await settled(hoverModel)
        precondition(hoverModel.entry?.word == "next" && hoverFixture.entryRequests == ["echo", "next"])
        hoverModel.suspend()
        hoverModel.lookupHovered("next")
        try await settled(hoverModel)
        precondition(hoverFixture.entryRequests.count == 3, "hidden capture must not reuse cancelled work")
        hoverModel.sourcesChanged()
        hoverModel.lookupHovered("next")
        try await settled(hoverModel)
        precondition(hoverFixture.entryRequests.count == 4, "source changes must invalidate reuse")
        hoverModel.lookupHovered("entry-failure")
        try await settled(hoverModel)
        hoverModel.lookupHovered("entry-failure")
        try await settled(hoverModel)
        precondition(hoverFixture.entryRequests.filter { $0 == "entry-failure" }.count == 2,
                     "failed queries must remain retryable")
        localModel.lookupHovered("local-hover")
        try await settled(localModel)
        let localID = localModel.localArticle?.id
        localModel.lookupHovered("local-hover")
        precondition(localID != nil && localModel.localArticle?.id == localID,
                     "same local hover must retain the HTML document identity")
        localModel.suspend()
        precondition(localModel.localArticle == nil, "hidden local HTML must still be released")
        precondition(!model.moveSuggestion(by: 1))
        model.query = "play"; model.queryChanged()
        precondition(model.isSuggesting)
        try await settled(model)
        precondition(model.hasMultipleSuggestions && model.suggestions.count == 4)
        precondition(model.entry?.word == "play" && model.selectedSuggestion?.word == "play")
        model.moveSuggestion(by: 1)
        model.moveSuggestion(by: 1)
        model.moveSuggestion(by: -1)
        try await settled(model)
        precondition(model.entry?.word == "player" && model.query == "play")
        precondition(!fixture.entryRequests.contains("playing"), "rapid keyboard navigation must debounce previews")
        let requestsBeforeSubmit = fixture.entryRequests.count
        model.submit()
        precondition(fixture.entryRequests.count == requestsBeforeSubmit, "reuse the displayed entry")
        model.selectSuggestion("playing")
        try await settled(model)
        precondition(model.entry?.word == "playing" && model.suggestions.count == 4)
        precondition(model.recent.first == "playing")
        let uniqueRequests = fixture.entryRequests.filter { $0 == "unique" }.count
        model.query = "single"; model.queryChanged()
        while model.isSuggesting { try await Task.sleep(nanoseconds: 5_000_000) }
        model.submit()
        try await settled(model)
        precondition(fixture.entryRequests.filter { $0 == "unique" }.count == uniqueRequests + 1,
                     "Return during auto preview must reuse the in-flight request")
        precondition(!model.hasMultipleSuggestions && model.suggestions.count == 1)
        precondition(model.entry?.word == "unique" && !model.moveSuggestion(by: 1))
        model.query = "empty"; model.queryChanged()
        try await settled(model)
        precondition(!model.hasMultipleSuggestions && model.entry == nil && model.message != nil)
        model.query = "中文"; model.queryChanged()
        try await settled(model)
        precondition(model.entry?.word == "unique" && !model.hasMultipleSuggestions)
        model.lookup("misspelled")
        try await settled(model)
        precondition(model.entry?.word == "unique" && !model.hasMultipleSuggestions)
        model.query = "slow"; model.queryChanged()
        try await Task.sleep(nanoseconds: 400_000_000)
        model.query = "single"; model.queryChanged()
        try await settled(model)
        precondition(model.entry?.word == "unique" && model.suggestions.first?.word == "unique")
        model.query = "many"; model.queryChanged()
        try await settled(model)
        precondition(model.suggestions.count == 10)
        model.editQuery("拼音组合", composing: true)
        precondition(!model.isSuggesting && model.suggestions.isEmpty && model.entry == nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(!model.isSuggesting && model.suggestions.isEmpty, "marked text must not request suggestions")
        model.editQuery("duplicates", composing: false)
        try await settled(model)
        precondition(model.suggestions.count == 1 && model.suggestions.first?.word == "same")
        model.query = "failure"; model.queryChanged()
        try await settled(model)
        precondition(!model.isSuggesting && model.message != nil)
        model.query = "slow"; model.queryChanged(); model.suspend()
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(!model.isLoading && !model.isSuggesting && model.suggestions.isEmpty)
        model.presentCaptureStatus("正在识别", busy: true)
        precondition(model.captureIsBusy && model.captureStatus != nil && model.query.isEmpty && model.entry == nil)
        model.query = "play"; model.queryChanged()
        precondition(model.captureStatus == nil && !model.captureIsBusy)
        try await settled(model)
        model.presentCaptureStatus("未识别到文字", busy: false)
        precondition(!model.captureIsBusy && model.captureStatus != nil && model.suggestions.isEmpty)
        model.lookup("captured")
        try await settled(model)
        precondition(model.captureStatus == nil && model.entry?.word == "captured")
        model.presentCaptureStatus("正在识别", busy: true)
        model.suspend()
        precondition(model.captureStatus == nil && !model.captureIsBusy)
        print("PASS: hover request/result reuse and invalidation; auto preview; two-column/single-column state; debounced keyboard previews; click/Return; single Chinese/fuzzy result; stale response rejection; candidate cap; failure and close cleanup")
    }
}

private final class FixtureLocalRouter: DictionaryLookupServing {
    var requests: [String] = []
    func entry(_ word: String) async throws -> LookupResult {
        requests.append(word)
        let dictionary = LocalDictionaryConfiguration(id: UUID(), name: "Fixture", mdxPath: "/unused.mdx", resources: [], enabled: true)
        return LookupResult(remote: nil, local: LocalArticle(dictionary: dictionary, word: word,
            headwords: [word], html: "<p>苹果</p>", summary: "苹果"), notice: nil)
    }
    func suggestions(_ query: String) async throws -> [Suggestion] { [] }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { [] }
    func releaseLocalResources() async {}
}
