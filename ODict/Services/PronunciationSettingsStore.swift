import Foundation
import Combine

@MainActor
final class PronunciationSettingsStore: ObservableObject {
    static let shared = PronunciationSettingsStore()
    static let key = "pronunciation.sources.v1"
    static let maximumSources = 33
    private static let systemMigrationKey = "pronunciation.systemSourceAdded.v1"
    @Published private(set) var sources: [PronunciationSource]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.key) {
            sources = (try? JSONDecoder().decode([PronunciationSource].self, from: data)) ?? []
        } else { sources = PronunciationSource.defaults }
        var renamed = false
        for index in sources.indices where sources[index].kind == .system && sources[index].name == "macOS 系统语音" {
            sources[index].name = "系统语音"
            renamed = true
        }
        if renamed, let data = try? JSONEncoder().encode(sources) {
            preferences.set(data, forKey: Self.key)
        }
        // Add the newly introduced default once; respect subsequent deletion or
        // disabling, and retain all existing source identities and colors.
        if !preferences.bool(forKey: Self.systemMigrationKey) {
            if !sources.contains(where: { $0.kind == .system }) {
                sources.append(.systemSource(excluding: Set(sources.map(\.colorHex))))
            }
            if let data = try? JSONEncoder().encode(sources) {
                preferences.set(data, forKey: Self.key)
                preferences.set(true, forKey: Self.systemMigrationKey)
            }
        }
    }

    var enabledSources: [PronunciationSource] { sources.filter { $0.enabled && $0.validationMessage == nil } }

    func newSource() -> PronunciationSource {
        PronunciationSource(name: "", template: "https://",
            colorHex: PronunciationSource.randomColor(excluding: Set(sources.map(\.colorHex))))
    }

    func save(_ source: PronunciationSource) throws {
        guard source.validationMessage == nil else { throw SettingsError.invalid }
        var next = sources
        if let index = next.firstIndex(where: { $0.id == source.id }) { next[index] = source }
        else {
            guard next.count < Self.maximumSources else { throw SettingsError.limit }
            next.append(source)
        }
        try persist(next)
    }

    func remove(_ source: PronunciationSource) throws {
        try persist(sources.filter { $0.id != source.id })
    }

    private func persist(_ next: [PronunciationSource]) throws {
        let data = try JSONEncoder().encode(next)
        preferences.set(data, forKey: Self.key)
        let playback = PronunciationService.shared
        if let id = playback.sourceID,
           sources.first(where: { $0.id == id }) != next.first(where: { $0.id == id }) { playback.stop() }
        sources = next
    }

    private enum SettingsError: LocalizedError {
        case invalid, limit
        var errorDescription: String? { self == .limit ? "最多可添加 33 个发音来源。" : "请检查来源配置。" }
    }
}
