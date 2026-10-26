import Foundation

struct Entry: Decodable, Identifiable {
    let id: Int
    let word: String
    let phonetic: String?
    let definition: String?
    let translation: String?
    let tags: [Tag]
    let partsOfSpeech: [PartOfSpeech]
    let inflections: [Inflection]

    struct Tag: Decodable { let code: String; let name: String? }
    struct PartOfSpeech: Decodable { let code: String; let name: String; let weightPercent: Int }
    struct Inflection: Decodable { let type: String; let typeName: String; let form: String }
}

struct Suggestion: Decodable, Identifiable {
    var id: String { word }
    let word: String
    let phonetic: String?
    let translationPreview: String?
    let translation: String?
}

protocol DictionaryServing {
    func entry(_ word: String) async throws -> Entry
    func suggestions(_ query: String) async throws -> [Suggestion]
    func search(_ query: String, translation: Bool) async throws -> [Suggestion]
}

enum DictionaryError: LocalizedError {
    case configuration, missingKey, notFound, unauthorized, limited(String?), server(Int), invalidResponse, responseTooLarge
    var errorDescription: String? {
        switch self {
        case .configuration: return "请在设置中填写有效的 HTTPS API 地址。"
        case .missingKey: return "请先在设置的在线词典中登录 ODict 账号。"
        case .notFound: return "没有找到这个词，试试其他拼写。"
        case .unauthorized: return "登录已失效，请在设置的在线词典中重新登录。"
        case .limited(let seconds): return seconds.map { "查询过于频繁，请在 \($0) 秒后重试。" } ?? "查询过于频繁，请稍后重试。"
        case .server(let status): return "词典服务暂不可用（\(status)），请稍后重试。"
        case .invalidResponse: return "无法读取词典返回的数据。"
        case .responseTooLarge: return "词典返回的数据过大，请缩小查询范围或检查服务配置。"
        }
    }
}
