import Foundation

/// Built-in endpoints shared by online lookup, account login and device reporting.
enum ODictService {
    static let defaultAPIAddress = "https://odict.touchany.com/api/"
    static let defaultWebOrigin = "https://odict.touchany.com"
    static let defaultLoginCallback = "com.touchany.odict:/auth/callback"

    #if DEBUG
    static var apiAddress: String { DebugLoginConfiguration.load().apiAddress }
    static var webOrigin: String { DebugLoginConfiguration.load().webOrigin }
    static var loginCallback: String { DebugLoginConfiguration.load().callback }
    #else
    static let apiAddress = defaultAPIAddress
    static let webOrigin = defaultWebOrigin
    static let loginCallback = defaultLoginCallback
    #endif

    static func allowsWebURL(_ value: URLComponents) -> Bool {
        if value.scheme == "https" { return true }
        #if DEBUG
        return value.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(value.host ?? "")
        #else
        return false
        #endif
    }
}

struct ServiceEndpoint: Sendable {
    private let components: URLComponents
    init(_ address: String) throws {
        guard let value = URLComponents(string: address), ODictService.allowsWebURL(value),
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

#if DEBUG
/// One small, non-secret configuration; no observers, sessions or background work.
struct DebugLoginConfiguration: Codable, Equatable {
    var apiAddress = ODictService.defaultAPIAddress
    var webOrigin = ODictService.defaultWebOrigin
    var callback = ODictService.defaultLoginCallback
    private static let key = "debug.loginConfiguration"

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), data.count <= 8192,
              var value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.validated()) != nil else { return Self() }
        // Correct the previous built-in address without replacing custom local settings.
        if value.apiAddress == "https://odict-api.touchany.com" || value.apiAddress == "https://odict-api.touchany.com/" {
            value.apiAddress = ODictService.defaultAPIAddress
        }
        return value
    }

    func validated() throws -> Self {
        let value = Self(apiAddress: apiAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                         webOrigin: webOrigin.trimmingCharacters(in: .whitespacesAndNewlines),
                         callback: callback.trimmingCharacters(in: .whitespacesAndNewlines))
        guard [value.apiAddress, value.webOrigin, value.callback].allSatisfy({ $0.utf8.count <= 2048 }) else {
            throw ConfigurationError.invalidAddress
        }
        guard (try? ServiceEndpoint(value.apiAddress)) != nil,
              let web = URLComponents(string: value.webOrigin), ODictService.allowsWebURL(web),
              let host = web.host, !host.isEmpty, web.url != nil,
              web.user == nil, web.password == nil, web.query == nil, web.fragment == nil,
              web.path.isEmpty || web.path == "/",
              web.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationError.invalidAddress
        }
        // ASWebAuthenticationSession on macOS 12 captures the registered custom scheme.
        guard let redirect = URLComponents(string: value.callback), redirect.url != nil,
              redirect.scheme == "com.touchany.odict", redirect.user == nil, redirect.password == nil,
              redirect.port == nil, redirect.query == nil, redirect.fragment == nil,
              redirect.path.hasPrefix("/"), !redirect.path.isEmpty else {
            throw ConfigurationError.invalidCallback
        }
        return value
    }

    func save() throws {
        let value = try validated()
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: Self.key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    private enum ConfigurationError: LocalizedError {
        case invalidAddress, invalidCallback
        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "请输入有效的 HTTPS 地址；本地 localhost、127.0.0.1 或 ::1 可使用 HTTP。网页地址不能包含路径、查询参数或登录信息。"
            case .invalidCallback: return "回调 URL 必须使用 com.touchany.odict 协议并包含路径，不能包含端口、查询参数或登录信息。"
            }
        }
    }
}
#endif
