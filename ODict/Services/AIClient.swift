import Foundation

protocol AIQueryServing {
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer
    func streamAnswer(text: String, onUpdate: @escaping @Sendable (AIStreamUpdate) async -> Void) async throws -> AIAnswer
}

extension AIQueryServing {
    func streamAnswer(text: String, onUpdate: @escaping @Sendable (AIStreamUpdate) async -> Void) async throws -> AIAnswer {
        let result = try await answer(text: text, kind: .automatic, target: nil, settings: nil)
        await onUpdate(.text(result.markdown))
        return result
    }
}

/// No persistent session or response cache: each cancelled/finished query releases its transport.
actor AIClient: AIQueryServing {
    private let transportFactory: (TimeInterval) -> HTTPTransporting
    private let streamFactory: (TimeInterval) -> AIStreamingTransporting
    init(transportFactory: @escaping (TimeInterval) -> HTTPTransporting = { timeout in
        HTTPTransport(maximumResponseBytes: 1024 * 1024, requestTimeout: timeout, resourceTimeout: timeout + 10)
    }, streamFactory: @escaping (TimeInterval) -> AIStreamingTransporting = { AIStreamTransport(timeout: $0) }) {
        self.transportFactory = transportFactory; self.streamFactory = streamFactory
    }

    func answer(text: String, kind: AITaskKind, target: AITargetLanguage? = nil,
                settings: AISavedSettings? = nil) async throws -> AIAnswer {
        let (request, timeout) = try await makeRequest(text: text, kind: kind, target: target, settings: settings, stream: false)
        let transport = transportFactory(timeout)
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch DictionaryError.responseTooLarge { throw AIError.responseTooLarge }
        catch DictionaryError.invalidResponse { throw AIError.invalidResponse }
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else { throw AIError.http(response.statusCode) }
        return try Self.parse(data)
    }

    private func makeRequest(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?,
                             stream: Bool) async throws -> (URLRequest, TimeInterval) {
        let saved: AISavedSettings
        if let settings { saved = settings } else { saved = try await AISettingsStore.load() }
        try Task.checkCancellation()
        let configuration = saved.configuration
        try AISettingsStore.validate(configuration, key: saved.key)
        guard !text.isEmpty, text.count <= AIConfiguration.maximumInput else { throw AIError.configuration }
        let taskKind = kind.resolved(for: text)
        let chosenTarget = target ?? configuration.target
        let direction = chosenTarget == .automatic
            ? "原文主要是中文则译成英文，否则译成简体中文。"
            : "翻译目标语言：\(chosenTarget.title)。"
        let systemPrompt = AIConfiguration.defaultSystemPrompt
            .replacingOccurrences(of: "{{task}}", with: taskKind.rawValue)
            .replacingOccurrences(of: "{{translation_direction}}", with: direction)
            .replacingOccurrences(of: "{{explanation_language}}", with: configuration.explanationLanguage.title)
        let prompt = taskKind == .word ? configuration.wordPrompt : configuration.translationPrompt
        var body: [String: Any] = ["model": configuration.model, "stream": stream,
            "messages": [["role": "system", "content": systemPrompt],
                         ["role": "user", "content": "任务偏好：\n\(prompt)"],
                         ["role": "user", "content": "请处理以下原文：\n<source>\n\(text)\n</source>"]]]
        if AIThinkingFormat.isLocalOllama(configuration.address) {
            body["max_tokens"] = configuration.thinking ? 8192 : 2048
        }
        switch configuration.thinkingFormat.resolved(address: configuration.address) {
        case .enableThinking: body["enable_thinking"] = configuration.thinking
        case .thinkingType: body["thinking"] = ["type": configuration.thinking ? "enabled" : "disabled"]
        case .reasoningEffort: body["reasoning_effort"] = configuration.thinking ? "medium" : "none"
        default: break
        }
        var request = URLRequest(url: try AIEndpoint(configuration.address).url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !saved.key.isEmpty { request.setValue("Bearer \(saved.key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let timeout: TimeInterval = configuration.thinking ? 180 : 60
        request.timeoutInterval = timeout
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        return (request, timeout)
    }

    func streamAnswer(text: String, onUpdate: @escaping @Sendable (AIStreamUpdate) async -> Void) async throws -> AIAnswer {
        let (request, timeout) = try await makeRequest(text: text, kind: .automatic, target: nil, settings: nil, stream: true)
        let transport = streamFactory(timeout)
        defer { withExtendedLifetime(transport) {} }
        var decoder = AIStreamDecoder()
        var isSSE = false
        var receivedResponse = false
        var fallback = Data()
        var lastPublication = -Double.infinity
        var lastText = ""
        var publishedThinking = false
        do {
            for try await event in transport.events(for: request) {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    guard (200...299).contains(response.statusCode) else { throw AIError.http(response.statusCode) }
                    receivedResponse = true
                    isSSE = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                case .data(let data):
                    guard receivedResponse else { throw AIError.invalidResponse }
                    if isSSE {
                        try decoder.append(data)
                        if !publishedThinking && (decoder.hasReasoning || decoder.thinkingInContent) {
                            publishedThinking = true; await onUpdate(.thinking)
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        // Coalesce token bursts; do not create a timer or reparse Markdown for every token.
                        if now - lastPublication >= 0.2, let text = decoder.visibleText, !text.isEmpty, text != lastText {
                            lastText = text; lastPublication = now
                            await onUpdate(.text(text))
                        }
                        if decoder.isComplete { break }
                    } else {
                        guard fallback.count + data.count <= 1024 * 1024 else { throw AIError.responseTooLarge }
                        fallback.append(data)
                    }
                }
                if decoder.isComplete { break }
            }
        } catch {
            // Keep the newest safe partial answer on a broken connection, but never publish after cancellation.
            if !Task.isCancelled, let text = decoder.visibleText, !text.isEmpty, text != lastText {
                await onUpdate(.text(text))
            }
            throw error
        }
        try Task.checkCancellation()
        if isSSE, let text = decoder.visibleText, !text.isEmpty, text != lastText {
            await onUpdate(.text(text))
        }
        guard receivedResponse else { throw AIError.invalidResponse }
        let answer = try isSSE ? decoder.finish() : Self.parse(fallback)
        await onUpdate(.text(answer.markdown))
        return answer
    }

    static func parse(_ data: Data) throws -> AIAnswer {
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let choice = envelope.choices.first else { throw AIError.invalidResponse }
        if choice.finish_reason == "length" { throw AIError.truncated }
        guard choice.finish_reason == nil || choice.finish_reason == "stop",
              let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AIError.invalidResponse
        }
        return try finalAnswer(content)
    }

    static func finalAnswer(_ raw: String) throws -> AIAnswer {
        var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never expose an unfinished inline reasoning prefix in the answer pane.
        if content.hasPrefix("<think>") {
            guard let end = content.range(of: "</think>") else { throw AIError.truncated }
            content = String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty else { throw AIError.invalidResponse }
        guard content.utf8.count <= 128 * 1024 else { throw AIError.responseTooLarge }
        return AIAnswer(markdown: content)
    }
}
