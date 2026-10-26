import Foundation

/// Built-in endpoints shared by online lookup, account login and device reporting.
enum ODictService {
    static let apiAddress = "https://odict-api.touchany.com"
    static let webOrigin = "https://odict.touchany.com"
}

struct ServiceEndpoint: Sendable {
    private let components: URLComponents
    init(_ address: String) throws {
        guard let value = URLComponents(string: address), value.scheme == "https",
              let host = value.host, !host.isEmpty, value.url != nil,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.port.map({ (1...65535).contains($0) }) ?? true else { throw DictionaryError.configuration }
        components = value
    }

    func url(path: [String], query: [URLQueryItem]) throws -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let segments = try path.map { segment -> String in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw DictionaryError.configuration
            }
            return encoded
        }
        var value = components
        // Preserve an already percent-encoded deployment prefix exactly once.
        var prefix = value.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        value.percentEncodedPath = prefix + "/" + segments.joined(separator: "/")
        value.queryItems = query
        guard let url = value.url else { throw DictionaryError.configuration }
        return url
    }
}
