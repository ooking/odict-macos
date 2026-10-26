import Foundation

struct AccountUser: Codable, Sendable { let id: String; let email: String; let nickname: String }
struct AccountSession: Codable, Sendable {
    let user: AccountUser
    let accessToken: String
    let refreshToken: String
    let expiresAt: String
    let refreshExpiresAt: String
    var expiry: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) ?? .distantPast
    }
}
struct AccountHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401, 403: return "登录已失效，请重新登录。"
        case 429: return "请求过于频繁，请稍后重试。"
        default: return "服务暂时不可用（\(status)），请稍后重试。"
        }
    }
}
enum AccountTransport {
    static func post<T: Decodable>(_ type: T.Type, endpoint: String, path: String, body: Data,
                                    deviceHeaders: [String: String] = [:]) async throws -> T {
        let url = try ServiceEndpoint(endpoint).url(path: path.split(separator: "/").map(String.init), query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in deviceHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let transport = HTTPTransport(maximumResponseBytes: 64 * 1024, requestTimeout: 12, resourceTimeout: 16)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw AccountHTTPError(status: response.statusCode) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AccountEnvelope<T>.self, from: data).data
    }
    static func body(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) }
}
private struct AccountEnvelope<T: Decodable>: Decodable { let data: T }
struct AccountAcknowledgement: Decodable, Sendable { }
