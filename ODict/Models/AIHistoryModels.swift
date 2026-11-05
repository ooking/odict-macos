import Foundation

/// No endpoint, credentials, prompts, images or rendered objects are archived.
struct AIHistoryRecord: Codable, Sendable {
    let id: UUID
    let date: Date
    let source: String
    let markdown: String
    let model: String
    let isPartial: Bool
}
