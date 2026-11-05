import Foundation
import CoreServices

struct SystemDictionaryArticle: Sendable {
    let word: String
    let text: String
    /// Prepare once per result, never on SwiftUI body updates. Keep the original
    /// text for metadata and preserve every character in the reading version.
    let readingText: String
    init(word: String, text: String) {
        self.word = word; self.text = text
        self.readingText = SystemDefinitionLayout.format(text)
    }
}

protocol SystemDictionaryServing {
    func article(_ word: String) async throws -> SystemDictionaryArticle?
}

struct SystemDictionaryService: SystemDictionaryServing {
    // Shared serial executor bounds concurrent non-interruptible system calls.
    private static let queue = BlockingWorkQueue(label: "com.touchany.odict.system-dictionary")
    func article(_ word: String) async throws -> SystemDictionaryArticle? {
        guard !word.isEmpty, word.utf16.count <= 1024 else { return nil }
        let article: SystemDictionaryArticle? = try await Self.queue.perform {
            let range = CFRange(location: 0, length: word.utf16.count)
            guard let definition = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() else { return nil }
            let text = definition as String
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard text.utf8.count <= 1024 * 1024 else { throw DictionaryError.responseTooLarge }
            return SystemDictionaryArticle(word: word, text: text)
        }
        try Task.checkCancellation()
        return article
    }
}

/// Conservative layout of public plain-text definitions. No HTML, dictionary-
/// specific semantic extraction, or guessed translations. Unknown text stays intact.
private enum SystemDefinitionLayout {
    // Only explicit dictionary markers create new paragraphs. Avoid splitting
    // on punctuation, IPA bars, semicolons or ordinary words inside examples.
    private static let paragraphs = try? NSRegularExpression(
        pattern: #"(?=[①-⑳❶-❿➀-➉]|[A-Z]\.[ \t]+(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection)\b)"#)
    private static let examples = try? NSRegularExpression(pattern: #"(?=[▸►‣])"#)
    private static let heading = try? NSRegularExpression(
        pattern: #"(?<=\|)[ \t]+(?=(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection)\b)"#)

    static func format(_ text: String) -> String {
        // Limit formatting work for unusually large definitions; raw text remains
        // readable and selectable rather than creating thousands of view nodes.
        guard text.utf16.count <= 128 * 1024 else { return text }
        var output = text
        for (expression, separator) in [(heading, "\n\n"), (paragraphs, "\n\n"), (examples, "\n")] {
            guard let expression else { continue }
            // Insert separators, retaining original whitespace and markers.
            output = expression.stringByReplacingMatches(in: output,
                range: NSRange(output.startIndex..., in: output), withTemplate: separator + "$0")
        }
        return output
    }
}
