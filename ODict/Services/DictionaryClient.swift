import Foundation

// Never forward credentials through redirects or persist authenticated responses to disk.
final class DictionaryClient: NSObject, DictionaryServing, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
        let address = UserDefaults.standard.string(forKey: "apiURL") ?? "https://odict-api.touchany.com"
        guard var components = URLComponents(string: address), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw DictionaryError.configuration }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 }
            + "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query + [.init(name: "source_language", value: "zh-CN"), .init(name: "target_language", value: "zh-CN")]
        guard let url = components.url else { throw DictionaryError.configuration }
        let key = try KeychainStore.read()
        guard !key.isEmpty else { throw DictionaryError.missingKey }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DictionaryError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw DictionaryError.unauthorized
        case 404: throw DictionaryError.notFound
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).flatMap { $0 >= 0 ? String($0) : nil }
            throw DictionaryError.limited(retry)
        default: throw DictionaryError.server(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Envelope<T>.self, from: data).data }
        catch { throw DictionaryError.invalidResponse }
    }
}

private struct Envelope<T: Decodable>: Decodable { let data: T }
