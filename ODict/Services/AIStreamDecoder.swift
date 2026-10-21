import Foundation

enum AIStreamUpdate: Sendable { case thinking, text(String) }

/// SSE lines can split anywhere, including inside a UTF-8 scalar. Decode only complete event data.
struct AIStreamDecoder {
    private var pending = Data()
    private var eventData = Data()
    private(set) var rawContent = ""
    private(set) var hasReasoning = false
    private(set) var isComplete = false
    private var sawFinish = false
    private var wasTruncated = false

    mutating func append(_ data: Data) throws {
        pending.append(data)
        var consumed = pending.startIndex
        while let end = pending[consumed...].firstIndex(of: 10) {
            var line = pending.subdata(in: consumed..<end)
            consumed = pending.index(after: end)
            if line.last == 13 { line.removeLast() }
            try consume(line)
        }
        if consumed > pending.startIndex { pending.removeSubrange(pending.startIndex..<consumed) }
        guard pending.count <= 128 * 1024 else { throw AIError.responseTooLarge }
    }
    mutating func finish() throws -> AIAnswer {
        if !pending.isEmpty { try consume(pending); pending.removeAll() }
        try dispatch()
        guard isComplete || sawFinish else { throw AIError.truncated }
        if wasTruncated { throw AIError.truncated }
        return try AIClient.finalAnswer(rawContent)
    }
    var visibleText: String? {
        let value = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || "<think>".hasPrefix(value) { return nil }
        if value.hasPrefix("<think>") {
            guard let end = value.range(of: "</think>") else { return nil }
            return String(value[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
    var thinkingInContent: Bool {
        let value = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("<think>") && !value.contains("</think>")
    }
    private mutating func consume(_ line: Data) throws {
        guard line.count <= 128 * 1024 else { throw AIError.responseTooLarge }
        if line.isEmpty { try dispatch(); return }
        let prefix = Data("data:".utf8)
        guard line.starts(with: prefix) else { return }
        var value = line.dropFirst(prefix.count)
        if value.first == 32 { value = value.dropFirst() }
        if !eventData.isEmpty { eventData.append(10) }
        guard eventData.count + value.count <= 128 * 1024 else { throw AIError.responseTooLarge }
        eventData.append(contentsOf: value)
    }
    private mutating func dispatch() throws {
        guard !eventData.isEmpty else { return }
        defer { eventData.removeAll(keepingCapacity: true) }
        if eventData == Data("[DONE]".utf8) { isComplete = true; return }
        guard !isComplete else { return }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String?; let reasoning_content: String?; let reasoning: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            let choices: [Choice]?
            let error: ErrorPayload?
            struct ErrorPayload: Decodable { let message: String? }
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: eventData), chunk.error == nil else {
            throw AIError.invalidResponse
        }
        guard let choice = chunk.choices?.first else { return } // Usage-only chunks have no choices.
        if let finish = choice.finish_reason {
            sawFinish = true
            isComplete = true
            if finish == "length" { wasTruncated = true }
            else if finish != "stop" { throw AIError.invalidResponse }
        }
        if let delta = choice.delta {
            if delta.reasoning_content?.isEmpty == false || delta.reasoning?.isEmpty == false { hasReasoning = true }
            if let content = delta.content {
                guard rawContent.utf8.count + content.utf8.count <= 128 * 1024 else { throw AIError.responseTooLarge }
                rawContent += content
            }
        }
    }
}
