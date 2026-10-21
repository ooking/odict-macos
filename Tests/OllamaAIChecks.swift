import Foundation

/// Inspects only response shape/length, never logs model reasoning or uses saved credentials.
private final class InspectingTransport: HTTPTransporting {
    private let transport: HTTPTransport
    private(set) var reasoningCharacters = 0
    private(set) var finalContent = ""
    private(set) var finishReason = ""
    init(timeout: TimeInterval) {
        transport = HTTPTransport(maximumResponseBytes: 1024 * 1024,
                                  requestTimeout: timeout, resourceTimeout: timeout + 10)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await transport.data(for: request)
        if let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let choice = (object["choices"] as? [[String: Any]])?.first,
           let message = choice["message"] as? [String: Any] {
            finalContent = message["content"] as? String ?? ""
            finishReason = choice["finish_reason"] as? String ?? ""
            reasoningCharacters = (message["reasoning_content"] as? String)?.count ?? (message["reasoning"] as? String)?.count ?? 0
        }
        return result
    }
}
@main private struct OllamaAIChecks {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        var configuration = AIConfiguration()
        configuration.address = "http://localhost:11434/v1"
        configuration.model = "qwen3.5:9b"
        configuration.thinkingFormat = .automatic
        for (text, kind, thinking) in [
            ("serendipity", AITaskKind.word, false),
            ("Please let me know when the package arrives.", .translation, false),
            ("请把窗户关上，外面有点冷。", .translation, true)
        ] {
            configuration.thinking = thinking
            let transport = InspectingTransport(timeout: thinking ? 180 : 60)
            let client = AIClient(transportFactory: { _ in transport })
            let start = ProcessInfo.processInfo.systemUptime
            let answer: AIAnswer
            do {
                answer = try await client.answer(text: text, kind: kind, target: .automatic,
                                                settings: AISavedSettings(configuration: configuration, key: ""))
            } catch {
                FileHandle.standardError.write(Data("FAIL: task=\(kind.rawValue), finish=\(transport.finishReason), finalAnswer=\(transport.finalContent)\n".utf8))
                throw error
            }
            precondition(answer.kind == kind && !answer.translation.isEmpty)
            if thinking { precondition(transport.reasoningCharacters > 0, "thinking-enabled request returned no separate reasoning") }
            else { precondition(transport.reasoningCharacters == 0, "thinking-off request still returned reasoning") }
            let elapsed = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start)
            FileHandle.standardError.write(Data("PASS: \(configuration.model), task=\(kind.rawValue), thinking=\(thinking), elapsed=\(elapsed)s, separateReasoning=\(transport.reasoningCharacters > 0)\n".utf8))
            print("RESULT: \(answer.translation)")
        }
        print("PASS: live localhost Ollama, three requests through the production AI client. No saved settings or Keychain accessed.")
    }
}
