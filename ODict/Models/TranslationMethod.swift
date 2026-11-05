import Foundation

/// Stable identities shared by routing, history and both window presentations.
/// Session selection lives in LookupModel and is deliberately never persisted.
enum TranslationMethod: Hashable, Codable, Identifiable, Sendable {
    case automatic, online, system, mdx(UUID), ai

    var id: String {
        switch self {
        case .automatic: return "automatic"
        case .online: return "online"
        case .system: return "system"
        case .mdx(let id): return "mdx-" + id.uuidString
        case .ai: return "ai"
        }
    }
    func title(in dictionaries: [LocalDictionaryConfiguration]) -> String {
        switch self {
        case .automatic: return "自动选择翻译方式"
        case .online: return "ODict 在线词典"
        case .system: return "macOS 系统词典"
        case .mdx(let id): return dictionaries.first { $0.id == id }?.name ?? "已移除的 MDX 词典"
        case .ai: return "AI 翻译"
        }
    }
}

struct TranslationMethodOption: Identifiable {
    let method: TranslationMethod
    let title: String
    let unavailableReason: String?
    var id: String { method.id }
    var isMDX: Bool {
        if case .mdx = method { return true }
        return false
    }
}
