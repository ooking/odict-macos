import Foundation

/// The online API model stays unchanged. Local HTML and remote structured entries
/// meet only at this routing boundary, not in either renderer.
struct LookupResult {
    let remote: Entry?
    let local: LocalArticle?
    let notice: String?
    var system: SystemDictionaryArticle? = nil
    var word: String { remote?.word ?? local?.word ?? system?.word ?? "" }
    var translation: String? { remote?.translation ?? local?.summary ?? system.map { String($0.text.prefix(240)) } }
    var source: String { system != nil ? "macOS 系统词典" : (local.map { "\($0.dictionary.name) · 本地" } ?? "ODict · 在线") }
}

protocol DictionaryLookupServing {
    func entry(_ word: String) async throws -> LookupResult
    func suggestions(_ query: String) async throws -> [Suggestion]
    func search(_ query: String, translation: Bool) async throws -> [Suggestion]
    func releaseLocalResources() async
    func entry(_ word: String, method: TranslationMethod) async throws -> LookupResult
    func candidates(_ query: String, translation: Bool, search: Bool, method: TranslationMethod) async throws -> [Suggestion]
}

extension DictionaryLookupServing {
    func entry(_ word: String, method: TranslationMethod) async throws -> LookupResult { try await entry(word) }
    func candidates(_ query: String, translation: Bool, search: Bool, method: TranslationMethod) async throws -> [Suggestion] {
        if search { return try await self.search(query, translation: translation) }
        return try await suggestions(query)
    }
}

final class DictionaryRouter: DictionaryLookupServing {
    private let remote: DictionaryServing
    private let store: LocalDictionaryStore
    private let local: LocalDictionaryLibrary
    init(remote: DictionaryServing, local: LocalDictionaryLibrary = .shared, store: LocalDictionaryStore = LocalDictionaryStore(),
         system: SystemDictionaryServing = SystemDictionaryService()) {
        self.remote = remote; self.local = local; self.store = store
        self.sources = store.sourceSettings; self.system = system
    }
    private let sources: LookupSourceSettings
    private let system: SystemDictionaryServing
    private var dictionaries: [LocalDictionaryConfiguration] {
        sources.isEnabled(.local) ? store.load().filter(\.enabled) : []
    }
    private func selectedDictionary(_ id: UUID) throws -> LocalDictionaryConfiguration {
        guard sources.isEnabled(.local), let item = store.load().first(where: { $0.id == id && $0.enabled }) else {
            throw NSError(domain: "ODict.TranslationMethod", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "这本 MDX 词典已移除或停用，请选择其他翻译方式。"])
        }
        return item
    }

    private func requireEnabled(_ source: LookupSource) throws {
        guard sources.isEnabled(source) else {
            throw NSError(domain: "ODict.TranslationMethod", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "该翻译方式已停用，请在设置中启用，或选择其他方式。"])
        }
    }

    func entry(_ word: String, method: TranslationMethod) async throws -> LookupResult {
        try Task.checkCancellation()
        switch method {
        case .automatic: return try await entry(word)
        case .online:
            try requireEnabled(.online)
            return LookupResult(remote: try await remote.entry(word), local: nil, notice: nil)
        case .system:
            try requireEnabled(.system)
            guard let article = try await system.article(word) else { throw DictionaryError.notFound }
            return LookupResult(remote: nil, local: nil, notice: nil, system: article)
        case .mdx(let id):
            let item = try selectedDictionary(id)
            guard let article = try await local.article(word, in: item) else { throw DictionaryError.notFound }
            return LookupResult(remote: nil, local: article, notice: nil)
        case .ai: throw LookupRoutingError.useAI
        }
    }

    func candidates(_ query: String, translation: Bool, search: Bool, method: TranslationMethod) async throws -> [Suggestion] {
        try Task.checkCancellation()
        switch method {
        case .automatic: return try await candidates(query, translation: translation, search: search)
        case .online:
            try requireEnabled(.online)
            return search ? try await remote.search(query, translation: translation) : try await remote.suggestions(query)
        case .system:
            try requireEnabled(.system)
            guard let article = try await system.article(query) else { return [] }
            return [Suggestion(word: query, phonetic: nil, translationPreview: String(article.text.prefix(160)), translation: nil)]
        case .mdx(let id):
            let item = try selectedDictionary(id)
            let exact = try await local.words(query, in: item, exact: true)
            return exact.isEmpty ? try await local.words(query, in: item, exact: false) : exact
        case .ai: return []
        }
    }

    func entry(_ word: String) async throws -> LookupResult {
        var unavailable: [String] = []
        for source in sources.active {
            try Task.checkCancellation()
            switch source {
            case .system:
                do {
                    if let article = try await system.article(word) {
                        return LookupResult(remote: nil, local: nil, notice: notice(unavailable), system: article)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { unavailable.append("系统词典：" + error.localizedDescription) }
            case .local:
                for dictionary in dictionaries {
                    try Task.checkCancellation()
                    do {
                        if let article = try await local.article(word, in: dictionary) {
                            return LookupResult(remote: nil, local: article, notice: notice(unavailable))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { unavailable.append("\(dictionary.name)：\(error.localizedDescription)") }
                }
            case .online:
                do { return LookupResult(remote: try await remote.entry(word), local: nil, notice: notice(unavailable)) }
                catch is CancellationError { throw CancellationError() }
                catch DictionaryError.notFound { continue }
                catch { unavailable.append("在线词典：" + error.localizedDescription) }
            case .ai:
                throw LookupRoutingError.useAI
            }
        }
        if let warning = notice(unavailable) {
            throw NSError(domain: "ODict.DictionaryRouter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: warning])
        }
        throw DictionaryError.notFound
    }
    func suggestions(_ query: String) async throws -> [Suggestion] {
        try await candidates(query, translation: false, search: false)
    }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] {
        try await candidates(query, translation: translation, search: true)
    }
    private func candidates(_ query: String, translation: Bool, search: Bool) async throws -> [Suggestion] {
        var lastError: Error?
        // Respect the same source boundary as detail routing; AI is only a
        // confirmation candidate here, never a network request.
        for source in sources.active {
            try Task.checkCancellation()
            switch source {
            case .system:
                do {
                    if let article = try await system.article(query) {
                        return [Suggestion(word: query, phonetic: nil,
                                           translationPreview: String(article.text.prefix(160)), translation: nil)]
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            case .local:
                let words = try await localCandidates(query)
                if !words.isEmpty { return words }
            case .online:
                do {
                    let words = search ? try await remote.search(query, translation: translation)
                        : try await remote.suggestions(query)
                    if !words.isEmpty { return words }
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error; continue }
            case .ai:
                // A confirmation candidate keeps typing/preview free of AI calls.
                return [Suggestion(word: query, phonetic: nil, translationPreview: "按回车使用 AI 查询", translation: nil)]
            }
        }
        if let lastError { throw lastError }
        return []
    }
    private func localCandidates(_ query: String) async throws -> [Suggestion] {
        let active = dictionaries
        // Exact matches across the ordered dictionaries precede prefix suggestions.
        // A prefix match in an earlier dictionary must not mask a later exact entry.
        for exact in [true, false] {
            for dictionary in active {
                try Task.checkCancellation()
                do {
                    let words = try await local.words(query, in: dictionary, exact: exact)
                    if !words.isEmpty { return words }
                } catch is CancellationError { throw CancellationError() }
                catch { continue } // Detail lookup reports unavailable sources with the final result.
            }
        }
        return []
    }
    private func notice(_ failures: [String]) -> String? {
        failures.isEmpty ? nil : "已跳过暂不可用的词典来源：\n" + failures.joined(separator: "\n")
    }
    func releaseLocalResources() async { await local.release() }
}
