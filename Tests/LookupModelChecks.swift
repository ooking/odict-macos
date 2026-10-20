import Foundation

private final class FixtureDictionary: DictionaryServing {
    var entryRequests: [String] = []
    func suggestions(_ query: String) async throws -> [Suggestion] {
        if query == "failure" { throw DictionaryError.server(503) }
        if query == "empty" { return [] }
        if query == "single" { return [suggestion("unique")] }
        if query == "many" { return (0..<30).map { suggestion("word\($0)") } }
        if query == "slow" { try? await Task.sleep(nanoseconds: 300_000_000); return [suggestion("stale")] }
        return ["play", "player", "playing", "playground"].map(suggestion)
    }
    private func suggestion(_ word: String) -> Suggestion {
        Suggestion(word: word, phonetic: nil, translationPreview: "释义", translation: nil)
    }
    func entry(_ word: String) async throws -> Entry {
        entryRequests.append(word)
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
        let model = LookupModel(dictionary: fixture)
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
        print("PASS: auto preview; two-column/single-column state; debounced keyboard previews; click/Return; single Chinese/fuzzy result; stale response rejection; candidate cap; failure and close cleanup")
    }
}
