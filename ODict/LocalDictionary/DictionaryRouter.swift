import Foundation

/// The online API model stays unchanged. Local HTML and remote structured entries
/// meet only at this routing boundary, not in either renderer.
struct LookupResult {
    let remote: Entry?
    let local: LocalArticle?
    let notice: String?
    var word: String { remote?.word ?? local?.word ?? "" }
    var translation: String? { remote?.translation ?? local?.summary }
    var source: String { local.map { "\($0.dictionary.name) · 本地" } ?? "ODict · 在线" }
}

protocol DictionaryLookupServing {
    func entry(_ word: String) async throws -> LookupResult
    func suggestions(_ query: String) async throws -> [Suggestion]
    func search(_ query: String, translation: Bool) async throws -> [Suggestion]
    func releaseLocalResources() async
}

final class DictionaryRouter: DictionaryLookupServing {
    private let remote: DictionaryServing
    private let store: LocalDictionaryStore
    private let local: LocalDictionaryLibrary
    init(remote: DictionaryServing, local: LocalDictionaryLibrary = .shared, store: LocalDictionaryStore = LocalDictionaryStore()) {
        self.remote = remote; self.local = local; self.store = store
    }
    private var dictionaries: [LocalDictionaryConfiguration] {
        store.mode == .onlineOnly ? [] : store.load().filter(\.enabled)
    }
    func entry(_ word: String) async throws -> LookupResult {
        let active = dictionaries
        #if DEBUG
        LocalDictionaryDebug.trace("route.begin", "word=\(String(reflecting: word)) localDictionaries=\(active.count)")
        #endif
        var unavailable: [String] = []
        for dictionary in active {
            try Task.checkCancellation()
            do {
                if let article = try await local.article(word, in: dictionary) {
                    #if DEBUG
                    LocalDictionaryDebug.trace("route.local", articleID: article.id)
                    #endif
                    return LookupResult(remote: nil, local: article, notice: notice(unavailable))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                #if DEBUG
                LocalDictionaryDebug.trace("lookup.failed", "dictionary=\(String(reflecting: dictionary.name)) domain=\((error as NSError).domain) code=\((error as NSError).code)")
                #endif
                unavailable.append("\(dictionary.name)：\(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        #if DEBUG
        LocalDictionaryDebug.trace("route.online", "localUnavailable=\(unavailable.count)")
        #endif
        do { return LookupResult(remote: try await remote.entry(word), local: nil, notice: notice(unavailable)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard let warning = notice(unavailable) else { throw error }
            throw NSError(domain: "ODict.DictionaryRouter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: warning + "\n在线词典：" + error.localizedDescription])
        }
    }
    func suggestions(_ query: String) async throws -> [Suggestion] {
        let candidates = try await localCandidates(query)
        if !candidates.isEmpty { return candidates }
        return try await remote.suggestions(query)
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
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] {
        if !translation {
            let candidates = try await localCandidates(query)
            if !candidates.isEmpty { return candidates }
        }
        // MDX headword indexes do not provide Chinese full-text reverse lookup.
        return try await remote.search(query, translation: translation)
    }
    private func notice(_ failures: [String]) -> String? {
        failures.isEmpty ? nil : "已跳过无法读取的本地词典：\n" + failures.joined(separator: "\n")
    }
    func releaseLocalResources() async { await local.release() }
}
