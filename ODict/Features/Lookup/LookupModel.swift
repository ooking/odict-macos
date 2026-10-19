import SwiftUI
import AVFoundation

@MainActor
final class LookupModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var entry: Entry?
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var selectedSuggestionIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isSuggesting = false
    @Published private(set) var message: String?
    @Published private(set) var recent = Array((UserDefaults.standard.stringArray(forKey: "recentWords") ?? []).prefix(20))
    @Published var focusRequest = UUID()
    private let dictionary: DictionaryServing
    private var speech: AVSpeechSynthesizer?
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var previewWord: String?
    private var rememberPreview = false
    private var revision = UUID()
    private var detailRevision = UUID()

    init(dictionary: DictionaryServing = DictionaryClient()) { self.dictionary = dictionary }

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
        if let selected = selectedSuggestion { preview(selected.word, remember: true) }
        else { lookup() }
    }

    func queryChanged() {
        cancelRequests()
        entry = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 255 else { return }
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
                if results.isEmpty { message = "没有找到候选词，可按回车查询完整词条。" }
            } catch {
                guard !Task.isCancelled, token == revision else { return }
                message = error.localizedDescription
            }
        }
    }

    // Only the selected entry is held in memory. Keyboard repeats cancel and debounce
    // previews; hovering never requests data. One unique candidate skips the sidebar.
    private func acceptSuggestions(_ results: [Suggestion]) {
        suggestions = Array(results.prefix(10))
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
        message = nil
        if let current = entry, current.word.caseInsensitiveCompare(word) == .orderedSame {
            isLoading = false
            if remember { rememberWord(current.word) }
            return
        }
        entry = nil
        isLoading = true
        detailTask = Task {
            defer {
                if token == detailRevision {
                    isLoading = false; detailTask = nil; previewWord = nil; rememberPreview = false
                }
            }
            do {
                if delay { try await Task.sleep(nanoseconds: 150_000_000) }
                let result = try await dictionary.entry(word)
                guard !Task.isCancelled, token == detailRevision else { return }
                entry = result
                if rememberPreview { rememberWord(result.word) }
            } catch {
                guard !Task.isCancelled, token == detailRevision else { return }
                message = error.localizedDescription
            }
        }
    }

    func lookup(_ word: String? = nil) {
        if let word { query = word }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRequests()
        entry = nil
        suggestions = []
        selectedSuggestionIndex = nil
        message = nil
        guard !text.isEmpty else { return }
        guard text.count <= 255 else { message = "请输入 255 字以内的单词或短语。"; return }
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
                    if results.isEmpty { message = "没有找到相关词条，请换一个中文关键词。" }
                } else {
                    do {
                        let result = try await dictionary.entry(text)
                        guard !Task.isCancelled, token == revision else { return }
                        entry = result
                        rememberWord(result.word)
                    } catch DictionaryError.notFound {
                        let results = try await dictionary.search(text, translation: false)
                        guard !Task.isCancelled, token == revision else { return }
                        acceptSuggestions(results)
                        if results.isEmpty { message = "没有找到这个词。" }
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

    private func rememberWord(_ word: String) {
        recent.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        recent.insert(word, at: 0)
        recent = Array(recent.prefix(20))
        UserDefaults.standard.set(recent, forKey: "recentWords")
    }

    func pronounce(_ word: String) {
        if speech == nil { speech = AVSpeechSynthesizer() }
        speech?.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        speech?.speak(utterance)
    }

    func clearHistory() {
        recent = []
        UserDefaults.standard.removeObject(forKey: "recentWords")
    }

    private func cancelRequests() {
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

    func suspend() {
        cancelRequests()
        speech?.stopSpeaking(at: .immediate)
        speech = nil
    }
}
