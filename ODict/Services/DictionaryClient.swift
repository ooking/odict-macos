import Foundation

// Immutable dependencies; URLSession lifecycle and buffering belong to the transport.
final class DictionaryClient: DictionaryServing {
    private let transport: HTTPTransporting
    private let rateLimit = RequestRateLimit()

    init(transport: HTTPTransporting = HTTPTransport()) {
        self.transport = transport
    }

    func entry(_ word: String) async throws -> Entry {
        try await request(path: ["entries", word])
    }

    func suggestions(_ query: String) async throws -> [Suggestion] {
        try await request(path: ["suggestions"], query: [.init(name: "q", value: query), .init(name: "limit", value: "6")])
    }

    func search(_ query: String, translation: Bool) async throws -> [Suggestion] {
        try await request(path: ["search"], query: [.init(name: "q", value: query),
            .init(name: "mode", value: translation ? "translation" : "fuzzy"), .init(name: "limit", value: "10")])
    }

    private func request<T: Decodable>(path: [String], query: [URLQueryItem] = []) async throws -> T {
        try Task.checkCancellation()
        // Capture once so a Debug server change cannot split one request across endpoints.
        let address = ODictService.apiAddress
        let endpoint = try ServiceEndpoint(address)
        let url = try endpoint.url(path: path, query: query + [
            .init(name: "source_language", value: "zh-CN"), .init(name: "target_language", value: "zh-CN")
        ])
        try rateLimit.check(url)
        let accountGeneration = await AccountStore.shared.generation(endpoint: address)
        let token = try await AccountStore.shared.access(endpoint: address)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var (data, http) = try await transport.data(for: request)
        if http.statusCode == 401 {
            let refreshed = try await AccountStore.shared.access(endpoint: address, rejectedToken: token)
            try Task.checkCancellation()
            request.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
            (data, http) = try await transport.data(for: request)
        }
        let currentGeneration = await AccountStore.shared.generation(endpoint: address)
        guard currentGeneration == accountGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw DictionaryError.unauthorized
        case 404: throw DictionaryError.notFound
        case 429:
            throw DictionaryError.limited(rateLimit.record(http))
        default: throw DictionaryError.server(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Envelope<T>.self, from: data).data }
        catch { throw DictionaryError.invalidResponse }
    }
}

private struct Envelope<T: Decodable>: Decodable { let data: T }
