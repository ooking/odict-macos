import Foundation

final class RecentWordsStore {
    private let defaults: UserDefaults
    private let limit = 20
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in defaults.stringArray(forKey: "recentWords") ?? [] {
            let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 255, seen.insert(text.lowercased()).inserted else { continue }
            result.append(text)
            if result.count == limit { break }
        }
        return result
    }

    func remember(_ word: String, in recent: [String]) -> [String] {
        let values = [word] + recent.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        let result = Array(values.prefix(limit))
        defaults.set(result, forKey: "recentWords")
        return result
    }

    func clear() { defaults.removeObject(forKey: "recentWords") }
}
