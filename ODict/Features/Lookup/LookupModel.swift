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
    @Published private(set) var selectedMethod: TranslationMethod = .automatic
    @Published private(set) var methodOptions: [TranslationMethodOption] = []
    let translationHistory: TranslationHistoryModel
    private var sessionMethod: TranslationMethod = .automatic
    private var manualQuery = ""
    private var submittedSource: String?
    private var aiHistoryMethod: TranslationMethod = .automatic
    private var aiHistoryTitle: String?
    private let onlineAvailability: () async -> Bool
    private var methodRefresh: Task<Void, Never>?
    private var methodRevision = UUID()

    var methodTitle: String {
        if let title = methodOptions.first(where: { $0.method == selectedMethod })?.title { return title }
        if selectedMethod.aiProfileID != nil { return "已移除的 AI 接口" }
        return selectedMethod.title(in: LocalDictionaryStore(defaults: preferences).load())
    }

    func refreshMethods() {
        methodRefresh?.cancel()
        let token = UUID(); methodRevision = token
        let sources = LookupSourceSettings(defaults: preferences)
        let dictionaries = LocalDictionaryStore(defaults: preferences).load()
        func reason(_ source: LookupSource) -> String? { sources.isEnabled(source) ? nil : "已在设置中停用" }
        let aiLibrary = AISettingsStore.library
        let aiReady = (try? AISettingsStore.validate(aiLibrary.effectiveConfiguration, key: "")) != nil
        func options(onlineReady: Bool) -> [TranslationMethodOption] {
            var values = [TranslationMethodOption(method: .automatic, title: TranslationMethod.automatic.title(in: dictionaries), unavailableReason: nil),
                TranslationMethodOption(method: .online, title: "ODict 在线词典", unavailableReason: onlineReady ? reason(.online) : "请先登录在线词典"),
                TranslationMethodOption(method: .system, title: "macOS 系统词典", unavailableReason: reason(.system))]
            values += dictionaries.map { item in
                TranslationMethodOption(method: .mdx(item.id), title: item.name,
                    unavailableReason: !item.enabled ? "词典已停用" : reason(.local))
            }
            values.append(TranslationMethodOption(method: .ai, title: "默认 AI 接口",
                unavailableReason: !aiReady ? "请先配置 AI 服务" : reason(.ai)))
            values += aiLibrary.profiles.map { profile in
                let configuration = aiLibrary.preferences.applying(to: profile.configuration)
                let configured = (try? AISettingsStore.validate(configuration, key: "")) != nil
                let name = profile.name.isEmpty ? "未命名接口" : profile.name
                let title = name + (configuration.model.isEmpty ? "" : " · " + configuration.model)
                    + (profile.id == aiLibrary.selectedID ? "（默认）" : "")
                return TranslationMethodOption(method: .aiProfile(profile.id), title: title,
                    unavailableReason: configured ? reason(.ai) : "请先完成接口配置")
            }
            return values
        }
        methodOptions = options(onlineReady: false)
        let availability = onlineAvailability
        methodRefresh = Task { [weak self] in
            let onlineReady = await availability()
            guard !Task.isCancelled, let self, self.methodRevision == token else { return }
            self.methodOptions = options(onlineReady: onlineReady)
            self.methodRefresh = nil
        }
    }

    /// Explicit selection is session-wide; opening history does not change this default.
    func selectMethod(_ value: TranslationMethod) {
        guard value != selectedMethod else { sessionMethod = value; return }
        let source = submittedSource
        pronunciation.stop(owner: pronunciationOwner)
        cancelRequests()
        ai.reset()
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        selectedMethod = value; sessionMethod = value
        ai.selectProfile(value.aiProfileID)
        mode = value.isAI ? .ai : .dictionary
        contentVisible = true
        focusRequest = UUID()
        if value.isAI { releaseDictionaryResources() }
        if let source {
            query = source
            if !captureContext { manualQuery = source }
            translationHistory.select(source: source, method: value)
            restoreOrLookup(source, generateAI: true)
        } else {
            submittedSource = nil
            if mode == .dictionary { queryChanged() }
        }
    }

    func beginManual() {
        refreshMethods()
        guard captureContext else { return }
        cancelRequests(); ai.reset()
        captureContext = false
        selectedMethod = sessionMethod
        ai.selectProfile(selectedMethod.aiProfileID)
        mode = selectedMethod.isAI ? .ai : .dictionary
        query = manualQuery
        submittedSource = nil
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        contentVisible = false
    }

    /// Automatic routing may choose AI without changing the session selection.
    func useAIForCurrentQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= AIConfiguration.maximumInput else { return }
        cancelRequests(); ai.reset()
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        contentVisible = true; mode = .ai
        isUsingAIForCurrentQuery = selectedMethod == .automatic
        releaseDictionaryResources()
        ai.selectProfile(selectedMethod.aiProfileID)
        ai.submit(text)
    }

    private func releaseDictionaryResources() {
        let router = dictionary
        Task { await router.releaseLocalResources() }
    }

    var offersAITranslation: Bool {
        mode == .dictionary && !isUsingAIForCurrentQuery && !isLoading && !isSuggesting
            && LookupSourceSettings(defaults: preferences).isEnabled(.ai)
            && (sentenceDetected || dictionaryMiss)
    }

    private func routeSentence(_ text: String, allowAI: Bool) -> Bool {
        guard !QueryTextClassifier.isWordOrPhrase(text) else { return false }
        sentenceDetected = true
        if text.count > AIConfiguration.maximumInput {
            message = "内容过长，请分段查询，每次最多 \(AIConfiguration.maximumInput) 字。"
        } else if selectedMethod == .automatic && allowAI && LookupSourceSettings(defaults: preferences).isEnabled(.ai) && AISettingsStore.autoTranslateSentences && ai.isConfigured {
            useAIForCurrentQuery()
        } else {
            message = "这段内容可能是句子，建议使用 AI 翻译。"
        }
        return true
    }

    func lookupCaptured(_ text: String) {
        captureContext = true
        cancelRequests(); ai.reset()
        selectedMethod = sessionMethod
        ai.selectProfile(selectedMethod.aiProfileID)
        mode = selectedMethod.isAI ? .ai : .dictionary
        submittedSource = nil
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
        if captureContext, selectedMethod == sessionMethod, mode == .dictionary,
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

    func aiSettingsChanged() { ai.settingsChanged(); refreshMethods() }

    func restoreAIInput(_ text: String) {
        if !captureContext { manualQuery = text }
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
    @Published var focusRequest = UUID()
    @Published var acceptsSearchFocus = true
    private let dictionary: DictionaryLookupServing
    private let resultCache: LookupResultCache
    private let pronunciation = PronunciationService.shared
    let pronunciationOwner = UUID()
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var previewWord: String?
    private var rememberPreview = false
    private var revision = UUID()
    private var detailRevision = UUID()

    convenience init(dictionary: DictionaryServing = DictionaryClient(), preferences: UserDefaults = .standard,
                     translationHistory: TranslationHistoryModel? = nil,
                     onlineAvailability: @escaping () async -> Bool = {
                         (try? await AccountStore.shared.user(endpoint: ODictService.apiAddress)) != nil
                     }) {
        self.init(router: DictionaryRouter(remote: dictionary, store: LocalDictionaryStore(defaults: preferences)),
                  preferences: preferences, translationHistory: translationHistory, onlineAvailability: onlineAvailability)
    }

    init(router: DictionaryLookupServing,
         preferences: UserDefaults = .standard, ai: AIQueryModel? = nil,
         translationHistory: TranslationHistoryModel? = nil,
         onlineAvailability: @escaping () async -> Bool = {
             (try? await AccountStore.shared.user(endpoint: ODictService.apiAddress)) != nil
         }) {
        self.onlineAvailability = onlineAvailability
        self.preferences = preferences
        self.resultCache = LookupResultCache(preferences: preferences)
        self.mode = .dictionary
        self.ai = ai ?? AIQueryModel()
        self.dictionary = router
        self.translationHistory = translationHistory ?? TranslationHistoryModel()
        self.ai.onSubmit = { [weak self] source in
            guard let self else { return }
            self.cancelRequests()
            self.isUsingAIForCurrentQuery = self.selectedMethod == .automatic
            self.submittedSource = source
            self.aiHistoryMethod = self.selectedMethod
            self.aiHistoryTitle = self.selectedMethod.aiProfileID == nil ? nil : self.methodTitle
            if !self.captureContext { self.manualQuery = source }
        }
        self.ai.onArchive = { [weak self] record in
            guard let self else { return }
            self.translationHistory.remember(TranslationHistoryRecord(id: record.id, date: record.date,
                source: record.source, method: self.aiHistoryMethod,
                title: String(("AI 翻译 · " + (self.aiHistoryTitle ?? record.model)).prefix(120)),
                payload: .ai(markdown: record.markdown, model: record.model, partial: record.isPartial)))
        }
        refreshMethods()
        self.translationHistory.load()
    }

    func editQuery(_ text: String, composing: Bool) {
        if !captureContext { manualQuery = text }
        submittedSource = nil
        contentVisible = true
        query = text
        if mode == .ai {
            captureStatus = nil; captureIsBusy = false
            if selectedMethod == .automatic && text.isEmpty { mode = .dictionary; ai.reset() }
            else { return }
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
        contentVisible = true
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
        submittedSource = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedMethod == .automatic && mode == .ai {
            ai.reset(); mode = .dictionary
            lookup(); return
        }
        if mode == .ai { ai.submit(query); return }
        if let selected = selectedSuggestion { preview(selected.word, remember: true) }
        else { lookup() }
    }

    func queryChanged() {
        if mode == .ai { return }
        submittedSource = nil
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
            #if DEBUG
            let loading = MemoryPhaseDiagnostics.Span("lookup.suggestions")
            defer { loading.mark(Task.isCancelled ? "cancelled" : "finished") }
            #endif
            defer { if token == revision { isSuggesting = false; task = nil } }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                let results: [Suggestion]
                if isChinese(text) { results = try await dictionary.candidates(text, translation: true, search: true, method: selectedMethod) }
                else { results = try await dictionary.candidates(text, translation: false, search: false, method: selectedMethod) }
                guard !Task.isCancelled, token == revision else { return }
                #if DEBUG
                loading.mark("candidates.ready")
                #endif
                acceptSuggestions(results)
                if results.isEmpty {
                    dictionaryMiss = true
                    message = LookupSourceSettings(defaults: preferences).isEnabled(.ai)
                        ? "没有找到候选词，可按回车查询，或用 AI 翻译。" : "没有找到候选词，可按回车查询。"
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
        if remember {
            submittedSource = word
            query = word
            if !captureContext { manualQuery = word }
        }
        if isUsingAIForCurrentQuery { ai.reset(); isUsingAIForCurrentQuery = false }
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
            #if DEBUG
            let loading = MemoryPhaseDiagnostics.Span("lookup.preview")
            defer { loading.mark(Task.isCancelled ? "cancelled" : "finished") }
            #endif
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
            } catch LookupRoutingError.useAI {
                guard !Task.isCancelled, token == detailRevision else { return }
                if rememberPreview {
                    query = word
                    useAIForCurrentQuery()
                } else {
                    message = "按回车使用 AI 查询。"
                }
            } catch {
                guard !Task.isCancelled, token == detailRevision else { return }
                if case DictionaryError.notFound = error { dictionaryMiss = true }
                message = dictionaryMiss
                    ? (LookupSourceSettings(defaults: preferences).isEnabled(.ai) ? "词典未收录，可以试试 AI 翻译。" : "已启用的词典未收录这个词。")
                    : error.localizedDescription
            }
        }
    }

    func lookup(_ word: String? = nil, allowAI: Bool = true) {
        let source = (word ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        submittedSource = source.isEmpty ? nil : source
        if !captureContext { manualQuery = source }
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
        if routeSentence(text, allowAI: allowAI) { return }
        let token = revision
        isLoading = true
        task = Task {
            #if DEBUG
            let loading = MemoryPhaseDiagnostics.Span("lookup.submit")
            defer { loading.mark(Task.isCancelled ? "cancelled" : "finished") }
            #endif
            // acceptSuggestions may start a detail request; don't clear its spinner.
            defer { if token == revision { if detailTask == nil { isLoading = false }; task = nil } }
            do {
                do {
                    let result = try await cachedEntry(text)
                    guard !Task.isCancelled, token == revision else { return }
                    self.result = result
                    message = result.notice
                    rememberEntry(result)
                } catch LookupRoutingError.useAI {
                    guard !Task.isCancelled, token == revision else { return }
                    if allowAI { useAIForCurrentQuery() }
                    else { message = "按回车使用 AI 查询。" }
                } catch DictionaryError.notFound {
                    let results = try await dictionary.candidates(text, translation: isChinese(text), search: true, method: selectedMethod)
                    guard !Task.isCancelled, token == revision else { return }
                    acceptSuggestions(results)
                    if results.isEmpty {
                        dictionaryMiss = true
                        message = LookupSourceSettings(defaults: preferences).isEnabled(.ai)
                            ? "词典未收录，可以试试 AI 翻译。" : "已启用的词典未收录这个词。"
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
        let cacheKey = selectedMethod.id + "\u{0}" + word
        if let cached = resultCache.value(for: cacheKey) {
            #if DEBUG
            memory.mark("cache.hit")
            #endif
            return cached
        }
        let result = try await dictionary.entry(word, method: selectedMethod)
        try Task.checkCancellation()
        resultCache.insert(result, for: cacheKey)
        return result
    }

    func cacheSettingsChanged() { resultCache.trim() }

    private func rememberEntry(_ entry: LookupResult) {
        let source = submittedSource ?? query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let payload: TranslationHistoryPayload
        if let remote = entry.remote { payload = .online(remote) }
        else if let article = entry.system { payload = .system(word: article.word, text: article.text) }
        else if let local = entry.local { payload = .mdx(dictionaryID: local.dictionary.id, word: local.word, summary: String((local.summary ?? "").prefix(160))) }
        else { return }
        translationHistory.remember(TranslationHistoryRecord(id: UUID(), date: Date(), source: source,
            method: selectedMethod, title: String(entry.source.prefix(120)), payload: payload))
    }

    func clearHistory() {
        // Stop generation before clearing so a late partial answer cannot reappear.
        ai.reset(); cancelRequests()
        resultCache.clear()
        translationHistory.clear()
    }

    func openHistory(_ group: TranslationHistoryGroup) {
        cancelRequests(); ai.reset()
        selectedMethod = group.selectedMethod
        query = group.source
        if !captureContext { manualQuery = group.source }
        submittedSource = group.source
        ai.selectProfile(selectedMethod.aiProfileID)
        mode = selectedMethod.isAI ? .ai : .dictionary
        contentVisible = true
        result = nil; suggestions = []; selectedSuggestionIndex = nil; message = nil
        restoreOrLookup(group.source, generateAI: false)
    }

    private func restoreOrLookup(_ source: String, generateAI: Bool) {
        let token = revision
        let method = selectedMethod
        isLoading = true
        if mode == .ai { ai.beginHistoryRestore() }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == token {
                    self.isLoading = false; self.task = nil; self.ai.finishHistoryRestore()
                }
            }
            do {
                let saved = try await self.translationHistory.record(source: source, method: method)
                guard !Task.isCancelled, self.revision == token else { return }
                if let saved {
                    switch saved.payload {
                    case .online(let entry): self.result = LookupResult(remote: entry, local: nil, notice: nil)
                    case .system(let word, let text):
                        self.result = LookupResult(remote: nil, local: nil, notice: nil, system: SystemDictionaryArticle(word: word, text: text))
                    case .mdx(let id, let word, _):
                        let result = try await self.dictionary.entry(word, method: .mdx(id))
                        guard !Task.isCancelled, self.revision == token else { return }
                        self.result = result
                    case .ai(let markdown, let model, let partial):
                        self.mode = .ai
                        self.isUsingAIForCurrentQuery = method == .automatic
                        self.ai.restoreAnswer(AIHistoryRecord(id: saved.id, date: saved.date, source: saved.source,
                            markdown: markdown, model: model, isPartial: partial))
                        self.releaseDictionaryResources()
                    }
                } else if generateAI || (!method.isAI && method != .automatic) {
                    // Detach this restore task before lookup cancels/replaces its revision.
                    self.task = nil
                    self.lookup(source, allowAI: generateAI)
                } else if method == .automatic && !self.ai.hasSubmitted {
                    self.task = nil
                    self.mode = .dictionary
                    self.lookup(source, allowAI: false)
                } else {
                    self.message = "该原文在此方式下尚无已保存结果，请提交查询。"
                }
            } catch {
                guard !Task.isCancelled, self.revision == token else { return }
                self.message = error.localizedDescription
            }
        }
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
        refreshMethods()
        translationHistory.load()
        guard !contentVisible else { return }
        contentVisible = true
        guard !query.isEmpty, captureStatus == nil else { return }
        restoreOrLookup(query.trimmingCharacters(in: .whitespacesAndNewlines), generateAI: false)
    }

    func sourcesChanged() {
        resultCache.clear()
        suspend()
        refreshMethods()
        result = nil
        suggestions = []
        selectedSuggestionIndex = nil
    }

    func suspend() {
        methodRefresh?.cancel(); methodRefresh = nil; methodRevision = UUID()
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
