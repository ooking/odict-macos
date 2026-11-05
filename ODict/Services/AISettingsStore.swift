import Foundation

struct AISavedSettings: Sendable {
    let configuration: AIConfiguration
    let key: String
}

struct AIServiceProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var configuration: AIConfiguration
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var keyAccount: String { id == Self.legacyID ? "ai-service-key" : "ai-service-key-" + id.uuidString }
}

/// Output preferences belong to the translation feature, independent of the selected service.
struct AISharedPreferences: Codable, Equatable, Sendable {
    var target: AITargetLanguage
    var explanationLanguage: AITargetLanguage
    var wordPrompt: String
    var translationPrompt: String

    init(configuration: AIConfiguration) {
        target = configuration.target
        explanationLanguage = configuration.explanationLanguage
        wordPrompt = configuration.wordPrompt
        translationPrompt = configuration.translationPrompt
    }
    func applying(to configuration: AIConfiguration) -> AIConfiguration {
        var value = configuration
        value.target = target
        value.explanationLanguage = explanationLanguage
        value.wordPrompt = wordPrompt
        value.translationPrompt = translationPrompt
        return value
    }
}

struct AIServiceLibrary: Codable, Sendable {
    var profiles: [AIServiceProfile]
    var selectedID: UUID
    // Absent in v2 libraries: migrate from the previously active profile without writing on read.
    var shared: AISharedPreferences? = nil
    var preferences: AISharedPreferences { shared ?? AISharedPreferences(configuration: selected.configuration) }
    var effectiveConfiguration: AIConfiguration { preferences.applying(to: selected.configuration) }
    var selected: AIServiceProfile { profiles.first(where: { $0.id == selectedID }) ?? profiles[0] }
}

enum AISettingsStore {
    static let libraryKey = "ai.services.v2"
    static let maximumProfiles = 10
    static var library: AIServiceLibrary {
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let library = try? JSONDecoder().decode(AIServiceLibrary.self, from: data),
           !library.profiles.isEmpty, library.profiles.count <= maximumProfiles,
           Set(library.profiles.map(\.id)).count == library.profiles.count,
           library.profiles.contains(where: { $0.id == library.selectedID }) { return library }
        let profile = AIServiceProfile(id: AIServiceProfile.legacyID, name: "默认配置", configuration: legacyConfiguration)
        return AIServiceLibrary(profiles: [profile], selectedID: profile.id)
    }
    static func saveLibrary(_ library: AIServiceLibrary, keys: [UUID: String]) async throws {
        guard !library.profiles.isEmpty, library.profiles.count <= maximumProfiles,
              Set(library.profiles.map(\.id)).count == library.profiles.count,
              library.profiles.contains(where: { $0.id == library.selectedID }),
              library.profiles.allSatisfy({ $0.name.count <= 60 && $0.configuration.address.count <= 2048 &&
                  $0.configuration.model.count <= 200 && $0.configuration.wordPrompt.count <= AIConfiguration.maximumPrompt &&
                  $0.configuration.translationPrompt.count <= AIConfiguration.maximumPrompt }) else {
            throw AIError.validation("配置内容过长，请检查配置名称、地址、模型和提示语。")
        }
        for key in keys.values { try validateKey(key) }
        try validate(library.effectiveConfiguration, key: keys[library.selectedID] ?? "")
        try await KeychainStore.saveAILibrary(library, keys: keys)
    }
    private static let preferenceKey = "ai.configuration.v1"
    static let sentenceTranslationKey = "lookup.autoTranslateSentences.v1"
    static var autoTranslateSentences: Bool {
        get {
            if UserDefaults.standard.object(forKey: sentenceTranslationKey) != nil {
                return UserDefaults.standard.bool(forKey: sentenceTranslationKey)
            }
            return configuration.autoTranslateSentences
        }
        set {
            UserDefaults.standard.set(newValue, forKey: sentenceTranslationKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static let changed = Notification.Name("ODictAISettingsChanged")
    static var configuration: AIConfiguration { library.effectiveConfiguration }
    private static var legacyConfiguration: AIConfiguration {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              var value = try? JSONDecoder().decode(AIConfiguration.self, from: data) else { return AIConfiguration() }
        // Refresh the previous built-in JSON-oriented default, preserving custom wording.
        if value.translationPrompt == "请自然、准确地翻译原文，保留语气、段落和专有名词。译文放在 translation 中；必要的关键词、表达或语法说明放在 explanation 中，避免逐字生硬翻译。" {
            value.translationPrompt = AIConfiguration.defaultTranslationPrompt
        }
        return value
    }
    static func configuration(profileID: UUID) -> AIConfiguration? {
        let library = library
        guard let profile = library.profiles.first(where: { $0.id == profileID }) else { return nil }
        return library.preferences.applying(to: profile.configuration)
    }
    static func load(profileID: UUID? = nil) async throws -> AISavedSettings {
        try await KeychainStore.loadAISettings(profileID: profileID)
    }
    static func save(_ configuration: AIConfiguration, key: String) async throws {
        try validate(configuration, key: key)
        var library = library
        library.shared = AISharedPreferences(configuration: configuration)
        let id = library.selected.id
        if let index = library.profiles.firstIndex(where: { $0.id == id }) { library.profiles[index].configuration = configuration }
        try await saveLibrary(library, keys: [id: key])
    }
    static func validate(_ configuration: AIConfiguration, key: String) throws {
        guard configuration.address.count <= 2048 else { throw AIError.validation("API 地址过长，最多 2048 字。") }
        _ = try AIEndpoint(configuration.address)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.model.count <= 200 else { throw AIError.validation("模型名称不能为空，且最多 200 字。") }
        try validateKey(key)
        guard !configuration.wordPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.translationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              configuration.wordPrompt.count <= AIConfiguration.maximumPrompt,
              configuration.translationPrompt.count <= AIConfiguration.maximumPrompt else {
            throw AIError.validation("解释和翻译提示语不能为空，且每份最多 6000 字。")
        }
        if configuration.thinking, configuration.thinkingFormat.resolved(address: configuration.address) == nil {
            throw AIError.unsupportedThinking
        }
    }
    static func validateKey(_ key: String) throws {
        guard key.count <= 8192,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw AIError.validation("API 密钥含空格、换行或过长，请检查密钥。")
        }
    }
}

struct AIEndpoint {
    let url: URL
    var modelsURL: URL { url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models") }
    private static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
    }
    init(_ address: String) throws {
        guard var value = URLComponents(string: address), let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.port.map({ (1...65535).contains($0) }) ?? true,
              value.scheme?.lowercased() == "https" || (value.scheme?.lowercased() == "http" && Self.isLocalHost(host)) else {
            throw AIError.validation("API 地址无效：请使用 HTTPS；本机或局域网可使用 HTTP。地址不能包含账号、密码、查询参数或片段。")
        }
        var path = value.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        value.percentEncodedPath = path
        guard let url = value.url else { throw AIError.configuration }
        self.url = url
    }
}
