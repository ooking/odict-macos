import Foundation

enum TranslationHistorySettings {
    static let capacityKey = "translationHistory.capacity.v1"
    static let defaultCapacity = 20
    static let capacityRange = 0...100
    static let changed = Notification.Name("ODictTranslationHistorySettingsChanged")
    static func capacity(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: capacityKey) != nil else { return defaultCapacity }
        return min(max(defaults.integer(forKey: capacityKey), 0), 100)
    }
}

/// Archive only answer data. No credentials, endpoints, prompts, HTML or renderers.
struct TranslationHistoryRecord: Codable, Sendable {
    let id: UUID
    let date: Date
    let source: String
    let method: TranslationMethod
    let title: String
    let payload: TranslationHistoryPayload
}

enum TranslationHistoryPayload: Codable, Sendable {
    case online(Entry)
    case system(word: String, text: String)
    case mdx(dictionaryID: UUID, word: String, summary: String)
    case ai(markdown: String, model: String, partial: Bool)
}

struct TranslationHistoryVariant: Codable, Identifiable, Sendable {
    let id: UUID
    let method: TranslationMethod
    let title: String
    let preview: String
    let bytes: Int
}

struct TranslationHistoryGroup: Codable, Identifiable, Sendable {
    let id: UUID
    let source: String
    var date: Date
    var selectedMethod: TranslationMethod
    var variants: [TranslationHistoryVariant]
    var selected: TranslationHistoryVariant? { variants.first { $0.method == selectedMethod } }
}

enum TranslationHistoryError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "无法读取这条历史记录，请重新查询。"
        case .tooLarge: return "历史结果超过保存上限，请缩小查询内容。"
        }
    }
}
