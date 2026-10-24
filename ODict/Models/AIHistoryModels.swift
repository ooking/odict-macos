import Foundation

enum AIHistorySettings {
    static let capacityKey = "ai.history.capacity.v1"
    static let defaultCapacity = 20
    static let capacityRange = 1...100
    static let changed = Notification.Name("ODictAIHistorySettingsChanged")

    static func capacity(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: capacityKey) != nil else { return defaultCapacity }
        return min(max(defaults.integer(forKey: capacityKey), capacityRange.lowerBound), capacityRange.upperBound)
    }
}

/// No endpoint, credentials, prompts, images or rendered objects are archived.
struct AIHistoryRecord: Codable, Sendable {
    let id: UUID
    let date: Date
    let source: String
    let markdown: String
    let model: String
    let isPartial: Bool

    var summary: AIHistorySummary {
        AIHistorySummary(id: id, date: date, sourcePreview: Self.preview(source),
                         answerPreview: Self.preview(markdown), model: model, isPartial: isPartial)
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(160)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct AIHistorySummary: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let sourcePreview: String
    let answerPreview: String
    let model: String
    let isPartial: Bool
}

enum AIHistoryError: Error { case invalidRecord, tooLarge, tooManyFiles }

struct AIHistorySnapshot: Sendable {
    let records: [AIHistorySummary]
    let notice: String?
}
