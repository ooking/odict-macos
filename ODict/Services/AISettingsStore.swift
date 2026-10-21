import Foundation

struct AISavedSettings: Sendable {
    let configuration: AIConfiguration
    let key: String
}

enum AISettingsStore {
    private static let preferenceKey = "ai.configuration.v1"
    static let changed = Notification.Name("ODictAISettingsChanged")
    static var configuration: AIConfiguration {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(AIConfiguration.self, from: data) else { return AIConfiguration() }
        return value
    }
    static func load() async throws -> AISavedSettings {
        try await KeychainStore.loadAISettings()
    }
    static func save(_ configuration: AIConfiguration, key: String) async throws {
        try validate(configuration, key: key)
        let data = try JSONEncoder().encode(configuration)
        try await KeychainStore.saveAIKey(key, configuration: data, preferenceKey: preferenceKey)
    }
    static func validate(_ configuration: AIConfiguration, key: String) throws {
        guard configuration.address.count <= 2048 else { throw AIError.configuration }
        _ = try AIEndpoint(configuration.address)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.model.count <= 200, key.count <= 8192,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !configuration.wordPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.translationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.wordPrompt.count <= AIConfiguration.maximumPrompt,
              configuration.translationPrompt.count <= AIConfiguration.maximumPrompt else { throw AIError.configuration }
        if configuration.thinking, configuration.thinkingFormat.resolved(address: configuration.address) == nil {
            throw AIError.unsupportedThinking
        }
    }
}

struct AIEndpoint {
    let url: URL
    init(_ address: String) throws {
        guard var value = URLComponents(string: address), let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.port.map({ (1...65535).contains($0) }) ?? true,
              value.scheme == "https" || (value.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw AIError.configuration
        }
        var path = value.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        value.percentEncodedPath = path
        guard let url = value.url else { throw AIError.configuration }
        self.url = url
    }
}
