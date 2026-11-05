import Foundation

/// Stable identities shared by routing, history and both window presentations.
/// Session selection lives in LookupModel and is deliberately never persisted.
enum TranslationMethod: Hashable, Codable, Identifiable, Sendable {
    case automatic, online, system, mdx(UUID), ai, aiProfile(UUID)

    var isAI: Bool {
        switch self { case .ai, .aiProfile: return true; default: return false }
    }
    var aiProfileID: UUID? {
        if case .aiProfile(let id) = self { return id }
        return nil
    }
    var id: String {
        switch self {
        case .automatic: return "automatic"
        case .online: return "online"
        case .system: return "system"
        case .mdx(let id): return "mdx-" + id.uuidString
        case .ai: return "ai"
        case .aiProfile(let id): return "ai-" + id.uuidString
        }
    }
    func title(in dictionaries: [LocalDictionaryConfiguration]) -> String {
        switch self {
        case .automatic: return "自动选择翻译方式"
        case .online: return "ODict 在线词典"
        case .system: return "macOS 系统词典"
        case .mdx(let id): return dictionaries.first { $0.id == id }?.name ?? "已移除的 MDX 词典"
        case .ai: return "AI 翻译（默认接口）"
        case .aiProfile: return "AI 翻译（指定接口）"
        }
    }
}

struct TranslationMethodOption: Identifiable {
    let method: TranslationMethod
    let title: String
    let unavailableReason: String?
    var id: String { method.id }
    var isAI: Bool { method.isAI }
    var isMDX: Bool {
        if case .mdx = method { return true }
        return false
    }
}
