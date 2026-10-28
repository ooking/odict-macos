import SwiftUI

@MainActor
final class LookupModel: ObservableObject {
    @Published var query = "" {
        didSet {
            if query != oldValue { pronunciation.stop(owner: pronunciationOwner) }
        }
    }
    @Published private(set) var mode: QueryMode
    let ai: AIQueryModel
    private let preferences: UserDefaults
    private var captureContext = false
    // Keep one session-only input per mode. Captures and result/history
    // navigation share query, but never overwrite these manual drafts.
    private var dictionaryManualQuery = ""
    private var aiManualQuery = ""
    private var manualQuery: String {
        get { mode == .dictionary ? dictionaryManualQuery : aiManualQuery }
        set {
            if mode == .dictionary { dictionaryManualQuery = newValue }
            else { aiManualQuery = newValue }
        }
    }

    func setMode(_ value: QueryMode) {
        guard value != mode || isUsingAIForCurrentQuery else { return }
        cancelRequests()
        ai.reset()
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        mode = value
        if !captureContext {
            query = manualQuery
            contentVisible = true
        }
        pronunciation.stop(owner: pronunciationOwner)
        if value == .ai {
            let router = dictionary
            Task { await router.releaseLocalResources() }
        }
        if !captureContext { preferences.set(value.rawValue, forKey: QueryMode.manualKey) }
        focusRequest = UUID()
    }

    func beginManual() {
        let manualMode = QueryMode(rawValue: preferences.string(forKey: QueryMode.manualKey) ?? "") ?? .dictionary
        let restoreDraft = captureContext || mode != manualMode || query != manualQuery || isUsingAIForCurrentQuery
        captureContext = false
        setMode(manualMode)
        guard restoreDraft else { return }
        cancelRequests()
        ai.reset()
        pronunciation.stop(owner: pronunciationOwner)
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        query = manualQuery
        // The window's resume restores results only for the manual draft.
        contentVisible = false
    }

    /// One-query override: never changes either persisted mode or manual drafts.
    func useAIForCurrentQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= AIConfiguration.maximumInput else { return }
        cancelRequests()
        ai.reset()
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        contentVisible = true
        isUsingAIForCurrentQuery = true
        let router = dictionary
        Task { await router.releaseLocalResources() }
        ai.submit(text)
    }

    var offersAITranslation: Bool {
        mode == .dictionary && !isUsingAIForCurrentQuery && !isLoading && !isSuggesting
            && (sentenceDetected || dictionaryMiss)
    }

    private func routeSentence(_ text: String) -> Bool {
        guard !QueryTextClassifier.isWordOrPhrase(text) else { return false }
        sentenceDetected = true
        if text.count > AIConfiguration.maximumInput {
            message = "内容过长，请分段查询，每次最多 \(AIConfiguration.maximumInput) 字。"
        } else if ai.savedConfiguration.autoTranslateSentences && ai.isConfigured {
            useAIForCurrentQuery()
        } else {
            message = "这段内容可能是句子，建议使用 AI 翻译。"
        }
        return true
    }

    func lookupCaptured(_ text: String) {
        captureContext = true
        setMode(QueryMode(rawValue: preferences.string(forKey: QueryMode.captureKey) ?? "") ?? .dictionary)
        lookup(text)
    }

    /// The manual window's selection button imports into its existing input.
    func lookupSelectionInInput(_ text: String) {
        captureContext = false
        manualQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lookup(manualQuery)
        focusRequest = UUID()
    }

    /// Reuse only the visible capture's exact query or its current request. No
    /// case folding or failed-answer reuse. Completed lookups use the bounded cache.
    func lookupHovered(_ text: String) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureMode = QueryMode(rawValue: preferences.string(forKey: QueryMode.captureKey) ?? "") ?? .dictionary
        if captureContext, mode == .dictionary, captureMode == .dictionary,
           contentVisible, captureStatus == nil, query == word,
           (result != nil && message == result?.notice) || (isLoading && message == nil) {
            #if DEBUG
            MemoryPhaseDiagnostics.snapshot("hover.lookup.reused")
            #endif
            return
        }
        #if DEBUG
        MemoryPhaseDiagnostics.snapshot("hover.lookup.dispatched")
        #endif
        lookupCaptured(word)
    }

    func aiSettingsChanged() { ai.settingsChanged() }

    func restoreAIInput(_ text: String) {
        aiManualQuery = text
        query = text
        focusRequest = UUID()
    }

    @Published private(set) var result: LookupResult?
    var entry: Entry? { result?.remote }
    var localArticle: LocalArticle? { result?.local }
    var source: String? { result?.source }
    @Published private(set) var contentVisible = true
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var selectedSuggestionIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isSuggesting = false
    @Published private(set) var isUsingAIForCurrentQuery = false
    @Published private(set) var sentenceDetected = false
    @Published private(set) var dictionaryMiss = false
    @Published private(set) var message: String?
    @Published private(set) var captureStatus: String?
    @Published private(set) var captureIsBusy = false
    @Published private(set) var recent: [String]
    @Published private(set) var recentTranslations: [String: String]
    @Published var focusRequest = UUID()
    @Published var acceptsSearchFocus = true
    private let dictionary: DictionaryLookupServing
    private let history: RecentWordsStore
    private let resultCache: LookupResultCache
    private let pronunciation = PronunciationService.shared
    let pronunciationOwner = UUID()
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var previewWord: String?
    private var rememberPreview = false
    private var revision = UUID()
    private var detailRevision = UUID()

    convenience init(dictionary: DictionaryServing = DictionaryClient(), history: RecentWordsStore = RecentWordsStore(),
                     preferences: UserDefaults = .standard) {
        self.init(router: DictionaryRouter(remote: dictionary), history: history, preferences: preferences)
    }

    init(router: DictionaryLookupServing, history: RecentWordsStore = RecentWordsStore(),
         preferences: UserDefaults = .standard, ai: AIQueryModel? = nil) {
        self.preferences = preferences
        self.resultCache = LookupResultCache(preferences: preferences)
        self.mode = QueryMode(rawValue: preferences.string(forKey: QueryMode.manualKey) ?? "") ?? .dictionary
        self.ai = ai ?? AIQueryModel()
        self.dictionary = router
        self.history = history
        let saved = history.load()
        recent = saved
        recentTranslations = history.loadTranslations(for: saved)
    }

    func editQuery(_ text: String, composing: Bool) {
        manualQuery = text
        contentVisible = true
        query = text
        if mode == .ai {
            captureStatus = nil; captureIsBusy = false
            return
        }
        if composing {
            cancelRequests()
            result = nil
            suggestions = []
            selectedSuggestionIndex = nil
            message = nil
        } else { queryChanged() }
    }

    func presentCaptureStatus(_ text: String, busy: Bool, preservingManualInput: Bool = false) {
        if !preservingManualInput { captureContext = true }
        ai.reset()
        cancelRequests()
        if !preservingManualInput { query = "" }
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        captureStatus = text
        captureIsBusy = busy
    }

    var hasMultipleSuggestions: Bool { suggestions.count > 1 }

    var selectedSuggestion: Suggestion? {
        guard let index = selectedSuggestionIndex, suggestions.indices.contains(index) else { return nil }
        return suggestions[index]
    }

    @discardableResult
    func moveSuggestion(by step: Int) -> Bool {
        guard hasMultipleSuggestions else { return false }
        let index = selectedSuggestionIndex.map { min(max($0 + step, 0), suggestions.count - 1) }
            ?? (step > 0 ? 0 : suggestions.count - 1)
        guard index != selectedSuggestionIndex else { return true }
        selectedSuggestionIndex = index
        preview(suggestions[index].word, delay: true)
        return true
    }

    func selectSuggestion(_ word: String) {
        guard let index = suggestions.firstIndex(where: { $0.word == word }) else { return }
        selectedSuggestionIndex = index
        preview(word, remember: true)
    }

    func submit() {
        if mode == .ai { ai.submit(query); return }
        if let selected = selectedSuggestion { preview(selected.word, remember: true) }
        else { lookup() }
    }

    func queryChanged() {
        if mode == .ai { return }
        contentVisible = true
        cancelRequests()
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .dictionary else { return }
        guard !text.isEmpty else { return }
        // While typing, offer confirmation but never send source text to AI.
        if !QueryTextClassifier.isWordOrPhrase(text) {
            sentenceDetected = true
            message = text.count > AIConfiguration.maximumInput
                ? "内容过长，请分段查询，每次最多 \(AIConfiguration.maximumInput) 字。"
                : "这段内容可能是句子，建议使用 AI 翻译。"
            return
        }
        let token = revision
        isSuggesting = true
        task = Task {
            defer { if token == revision { isSuggesting = false; task = nil } }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                let results: [Suggestion]
                if isChinese(text) { results = try await dictionary.search(text, translation: true) }
                else { results = try await dictionary.suggestions(text) }
                guard !Task.isCancelled, token == revision else { return }
                acceptSuggestions(results)
                if results.isEmpty {
                    dictionaryMiss = true
                    message = "没有找到候选词，可按回车查询，或用 AI 翻译。"
                }
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                message = error.localizedDescription
            }
        }
    }

    // Keyboard repeats cancel and debounce
    // previews; hovering never requests data. One unique candidate skips the sidebar.
    private func acceptSuggestions(_ results: [Suggestion]) {
        var seen = Set<String>()
        var accepted: [Suggestion] = []
        // Explicitly traverse once: a lazy Collection can evaluate its predicate
        // more than once, so mutating a deduplication set inside it is unsafe.
        for result in results {
            guard !result.word.isEmpty, result.word.count <= 255,
                  seen.insert(result.word.lowercased()).inserted else { continue }
            accepted.append(result)
            if accepted.count == 10 { break }
        }
        suggestions = accepted
        selectedSuggestionIndex = suggestions.isEmpty ? nil : 0
        if let first = suggestions.first { preview(first.word) }
    }

    private func preview(_ word: String, delay: Bool = false, remember: Bool = false) {
        if detailTask != nil, previewWord == word {
            rememberPreview = rememberPreview || remember
            return
        }
        detailTask?.cancel()
        detailTask = nil
        detailRevision = UUID()
        let token = detailRevision
        previewWord = word
        rememberPreview = remember
        dictionaryMiss = false
        message = nil
        if let current = result, current.word.caseInsensitiveCompare(word) == .orderedSame {
            message = current.notice
            isLoading = false
            if remember { rememberEntry(current) }
            return
        }
        result = nil
        isLoading = true
        detailTask = Task {
            defer {
                if token == detailRevision {
                    isLoading = false; detailTask = nil; previewWord = nil; rememberPreview = false
                }
            }
            do {
                if delay { try await Task.sleep(nanoseconds: 150_000_000) }
                let result = try await cachedEntry(word)
                guard !Task.isCancelled, token == detailRevision else { return }
                self.result = result
                message = result.notice
                if rememberPreview { rememberEntry(result) }
            } catch {
                guard !Task.isCancelled, token == detailRevision else { return }
                if case DictionaryError.notFound = error { dictionaryMiss = true }
                message = dictionaryMiss ? "词典未收录，可以试试 AI 翻译。" : error.localizedDescription
            }
        }
    }

    func lookup(_ word: String? = nil) {
        if mode == .ai {
            if let word { query = word }
            contentVisible = true
            cancelRequests()
            ai.submit(query)
            return
        }
        contentVisible = true
        if let word { query = word }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRequests()
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        guard !text.isEmpty else { return }
        if routeSentence(text) { return }
        let token = revision
        isLoading = true
        task = Task {
            // acceptSuggestions may start a detail request; don't clear its spinner.
            defer { if token == revision { if detailTask == nil { isLoading = false }; task = nil } }
            do {
                if isChinese(text) {
                    let results = try await dictionary.search(text, translation: true)
                    guard !Task.isCancelled, token == revision else { return }
                    acceptSuggestions(results)
                    if results.isEmpty {
                        dictionaryMiss = true
                        message = "没有找到相关词条，可以试试 AI 翻译。"
                    }
                } else {
                    do {
                        let result = try await cachedEntry(text)
                        guard !Task.isCancelled, token == revision else { return }
                        self.result = result
                        message = result.notice
                        rememberEntry(result)
                    } catch DictionaryError.notFound {
                        let results = try await dictionary.search(text, translation: false)
                        guard !Task.isCancelled, token == revision else { return }
                        acceptSuggestions(results)
                        if results.isEmpty {
                            dictionaryMiss = true
                            message = "词典未收录，可以试试 AI 翻译。"
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                message = (error as? URLError)?.code == .timedOut ? "连接超时，请检查网络后重试。" : error.localizedDescription
            }
        }
    }

    private func isChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    private func cachedEntry(_ word: String) async throws -> LookupResult {
        #if DEBUG
        let memory = MemoryPhaseDiagnostics.Span("dictionary.entry")
        defer { memory.mark("finished") }
        #endif
        try Task.checkCancellation()
        if let cached = resultCache.value(for: word) {
            #if DEBUG
            memory.mark("cache.hit")
            #endif
            return cached
        }
        let result = try await dictionary.entry(word)
        try Task.checkCancellation()
        resultCache.insert(result, for: word)
        return result
    }

    func cacheSettingsChanged() {
        resultCache.trim()
        recent = history.trim()
        recentTranslations = history.loadTranslations(for: recent)
    }

    private func rememberEntry(_ entry: LookupResult) {
        recent = history.remember(entry.word, in: recent)
        recentTranslations = recentTranslations.filter { recent.contains($0.key) }
        if recent.contains(entry.word) {
            recentTranslations[entry.word] = RecentWordsStore.summary(entry.translation ?? "")
        }
        history.saveTranslations(recentTranslations, for: recent)
    }


    func clearHistory() {
        resultCache.clear()
        recent = []
        recentTranslations = [:]
        history.clear()
    }

    private func cancelRequests() {
        if isUsingAIForCurrentQuery { ai.reset(); isUsingAIForCurrentQuery = false }
        sentenceDetected = false
        dictionaryMiss = false
        captureStatus = nil
        captureIsBusy = false
        task?.cancel()
        detailTask?.cancel()
        task = nil
        detailTask = nil
        previewWord = nil
        rememberPreview = false
        revision = UUID()
        detailRevision = UUID()
        isLoading = false
        isSuggesting = false
    }

    func resume() {
        guard !contentVisible else { return }
        if mode == .ai { contentVisible = true; return }
        let reload = !contentVisible && result == nil && !query.isEmpty && !isLoading && !isSuggesting && captureStatus == nil
        contentVisible = true
        if reload { lookup() }
    }

    func sourcesChanged() {
        resultCache.clear()
        suspend()
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
    }

    func suspend() {
        #if DEBUG
        MemoryPhaseDiagnostics.snapshot("lookup.suspend.begin")
        #endif
        // Archive AI output, then release result data and render trees. Manual
        // input drafts, compact history metadata and the configured cache survive.
        ai.suspend()
        contentVisible = false
        cancelRequests()
        // Dropping HTML and its WebView releases the renderer and resource tasks.
        result = nil
        suggestions = []; selectedSuggestionIndex = nil; message = nil
        let router = dictionary
        Task {
            await router.releaseLocalResources()
            #if DEBUG
            MemoryPhaseDiagnostics.snapshot("lookup.localResources.released")
            #endif
        }
        pronunciation.stop(owner: pronunciationOwner)
    }
}
