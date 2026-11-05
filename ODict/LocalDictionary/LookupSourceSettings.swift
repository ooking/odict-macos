import Foundation

/// One bounded, normalized list owns both source ordering and enablement.
enum LookupSource: String, Codable, CaseIterable, Identifiable {
    case system, local, online, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统词典"
        case .local: return "MDX词典"
        case .online: return "在线 ODict 词典"
        case .ai: return "AI翻译"
        }
    }
}

struct LookupSourceOption: Codable, Identifiable, Equatable {
    let source: LookupSource
    var enabled: Bool
    var id: LookupSource { source }
}

struct LookupSourceSettings {
    static let key = "lookupSources.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [LookupSourceOption] {
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LookupSourceOption].self, from: $0) } ?? []
        var seen = Set<LookupSource>()
        var result = saved.filter { seen.insert($0.source).inserted }
        for source in LookupSource.allCases where seen.insert(source).inserted {
            result.append(LookupSourceOption(source: source, enabled: true))
        }
        // A removed/disabled last MDX must not leave a checked source behind.
        if !LocalDictionaryStore(defaults: defaults).load().contains(where: \.enabled),
           let index = result.firstIndex(where: { $0.source == .local }) {
            result[index].enabled = false
        }
        return result
    }
    func reconcile(available: Set<LookupSource>) {
        let options = load().map {
            LookupSourceOption(source: $0.source, enabled: $0.enabled && available.contains($0.source))
        }
        if let data = try? JSONEncoder().encode(options), data != defaults.data(forKey: Self.key) {
            defaults.set(data, forKey: Self.key)
            NotificationCenter.default.post(name: LocalDictionaryStore.changed, object: nil)
        }
    }
    var active: [LookupSource] { load().filter(\.enabled).map(\.source) }
    func isEnabled(_ source: LookupSource) -> Bool { active.contains(source) }
    func save(_ options: [LookupSourceOption]) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: LocalDictionaryStore.changed, object: nil)
    }
    func setEnabled(_ source: LookupSource, _ enabled: Bool) {
        save(load().map { $0.source == source ? LookupSourceOption(source: source, enabled: enabled) : $0 })
    }
}

/// The router chooses AI; the main-actor model owns its existing streaming service.
enum LookupRoutingError: Error { case useAI }
