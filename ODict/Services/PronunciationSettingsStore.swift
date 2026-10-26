import Foundation
import Combine

@MainActor
final class PronunciationSettingsStore: ObservableObject {
    static let shared = PronunciationSettingsStore()
    static let key = "pronunciation.sources.v1"
    static let maximumSources = 32
    @Published private(set) var sources: [PronunciationSource]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.key) {
            sources = (try? JSONDecoder().decode([PronunciationSource].self, from: data)) ?? []
        } else { sources = PronunciationSource.defaults }
    }

    var enabledSources: [PronunciationSource] { sources.filter { $0.enabled && $0.validationMessage == nil } }

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
        var errorDescription: String? { self == .limit ? "最多可添加 32 个发音来源。" : "请检查来源配置。" }
    }
}
