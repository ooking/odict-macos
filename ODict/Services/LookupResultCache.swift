import Foundation

/// Session-only LRU of value data. Never retains renderers, file readers or tasks.
/// Count and estimated payload size are independent bounds, not an app-memory target.
@MainActor
final class LookupResultCache {
    private struct Item {
        let word: String
        let result: LookupResult
        let cost: Int
    }
    private let preferences: UserDefaults
    private let byteLimit = 8 * 1024 * 1024
    private var items: [Item] = [] // Least recently used first; at most 100 items.
    private var bytes = 0

    init(preferences: UserDefaults) { self.preferences = preferences }

    func value(for word: String) -> LookupResult? {
        trim()
        // Preserve case: different headwords may have different meanings.
        guard let index = items.firstIndex(where: { $0.word == word }) else { return nil }
        let item = items.remove(at: index)
        items.append(item)
        return item.result
    }

    func insert(_ result: LookupResult, for word: String) {
        trim()
        guard LookupCacheSettings.capacity(in: preferences) > 0,
              result.notice == nil, result.remote != nil || result.local != nil else { return }
        let cost = payloadCost(result) + word.utf8.count + 256
        guard cost <= byteLimit else { return }
        if let index = items.firstIndex(where: { $0.word == word }) {
            bytes -= items.remove(at: index).cost
        }
        items.append(Item(word: word, result: result, cost: cost))
        bytes += cost
        trim()
    }

    func trim() {
        let capacity = LookupCacheSettings.capacity(in: preferences)
        while !items.isEmpty && (items.count > capacity || bytes > byteLimit) {
            bytes -= items.removeFirst().cost
        }
    }

    func clear() { items = []; bytes = 0 }

    private func payloadCost(_ result: LookupResult) -> Int {
        func size(_ value: String?) -> Int { value?.utf8.count ?? 0 }
        if let article = result.local {
            return size(article.html) + size(article.word) + size(article.summary)
                + article.headwords.reduce(0) { $0 + size($1) }
                + size(article.dictionary.name) + size(article.dictionary.mdxPath)
                + article.dictionary.resources.reduce(0) { $0 + size($1) }
        }
        guard let entry = result.remote else { return 0 }
        return size(entry.word) + size(entry.phonetic) + size(entry.definition) + size(entry.translation)
            + entry.tags.reduce(0) { $0 + size($1.code) + size($1.name) + 64 }
            + entry.partsOfSpeech.reduce(0) { $0 + size($1.code) + size($1.name) + 64 }
            + entry.inflections.reduce(0) { $0 + size($1.type) + size($1.typeName) + size($1.form) + 64 }
    }
}
