import Foundation

@main private struct PronunciationChecks {
    @MainActor static func main() throws {
        let suite = "ODict.PronunciationChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = PronunciationSettingsStore(preferences: preferences)
        precondition(store.sources.count == 3)
        precondition(Set(store.sources.map(\.id)).count == 3)
        precondition(Set(store.sources.map(\.colorHex)).count == 3)
        precondition(store.sources.first(where: { $0.kind == .system })?.enabled == true)
        precondition(PronunciationSettingsStore(preferences: preferences).sources == store.sources)
        let occupied = Set(store.sources.map(\.colorHex))
        precondition(!occupied.contains(store.newSource().colorHex))
        var generated = Set<String>()
        for _ in 0..<64 {
            let color = PronunciationSource.randomColor(excluding: generated)
            precondition(!generated.contains(color))
            generated.insert(color)
        }
        precondition(PronunciationService.previewText == "hello")
        // Legacy JSON has no kind key. Migration adds TTS exactly once while
        // retaining existing IDs, colors and disabled states.
        let migrationPreferences = UserDefaults(suiteName: suite + ".migration")!
        defer { migrationPreferences.removePersistentDomain(forName: suite + ".migration") }
        let legacyID = UUID()
        let legacy = [["id": legacyID.uuidString, "name": "Legacy", "template": "https://example.com/?q={text}",
                       "enabled": false, "colorHex": "123456"]] as [[String: Any]]
        migrationPreferences.set(try JSONSerialization.data(withJSONObject: legacy), forKey: PronunciationSettingsStore.key)
        let migrated = PronunciationSettingsStore(preferences: migrationPreferences)
        precondition(migrated.sources.count == 2)
        precondition(migrated.sources.first?.id == legacyID && migrated.sources.first?.colorHex == "123456")
        precondition(migrated.sources.first?.kind == .remote && migrated.sources.first?.enabled == false)
        let system = migrated.sources.first(where: { $0.kind == .system })!
        precondition(system.validationMessage == nil && system.resolvedURL(text: "hello") == nil)
        try migrated.remove(system)
        precondition(PronunciationSettingsStore(preferences: migrationPreferences).sources.count == 1)
        var configuredSystem = PronunciationSource(name: "macOS 系统语音", kind: .system,
            systemVoiceIdentifier: "fixture.voice", systemVoiceGender: .female,
            systemLanguage: "en-US", systemRate: 1.2)
        try migrated.save(configuredSystem)
        let renamedSystem = PronunciationSettingsStore(preferences: migrationPreferences).sources.last!
        precondition(renamedSystem.id == configuredSystem.id && renamedSystem.name == "系统语音")
        precondition(renamedSystem.systemVoiceIdentifier == "fixture.voice" && renamedSystem.systemVoiceGender == .female)
        precondition(renamedSystem.systemLanguage == "en-US" && renamedSystem.systemRate == 1.2)
        let fixtureVoice = SystemSpeechVoice(id: "fixture.voice", name: "Fixture", language: "en-US", gender: .female)
        precondition(fixtureVoice.matches(renamedSystem))
        configuredSystem.systemVoiceGender = .male
        precondition(!fixtureVoice.matches(configuredSystem))
        configuredSystem.systemVoiceGender = .female
        configuredSystem.systemLanguage = "en-GB"
        precondition(!fixtureVoice.matches(configuredSystem))
        configuredSystem.systemRate = .nan
        precondition(configuredSystem.validationMessage != nil)
        let raw = "  Hello & 你好? #+/%=\nHow are you?  "
        for source in store.sources.filter({ $0.kind == .remote }) {
            precondition(source.validationMessage == nil)
            let url = source.resolvedURL(text: raw)!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            precondition(components.queryItems?.first(where: { $0.name == "audio" })?.value == raw)
            precondition(components.queryItems?.count == 2)
            precondition(components.fragment == nil)
            precondition(source.resolvedURL(text: " \n\t") == nil)
        }
        var source = PronunciationSource(name: "Path", template: "https://example.com/audio/{text}?q={text}")
        let url = source.resolvedURL(text: "a/b & c")!
        precondition(url.absoluteString.contains("a%2Fb%20%26%20c"))
        precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a/b & c")
        for invalid in ["file:///tmp/{text}", "http://example.com/{text}",
                        "https://{text}.example.com/audio", "https://user:password@example.com/{text}",
                        "https://example.com/audio", "https://example.com/{text}#fragment"] {
            source.template = invalid
            precondition(source.validationMessage != nil, invalid)
        }
        source.template = "https://example.com/?text={text}"
        try store.save(source)
        source.name = "Updated"; source.enabled = false; source.colorHex = "FF0000"
        try store.save(source)
        let reloaded = PronunciationSettingsStore(preferences: preferences)
        precondition(reloaded.sources.last == source)
        precondition(!reloaded.enabledSources.contains(where: { $0.id == source.id }))
        for item in reloaded.sources { try reloaded.remove(item) }
        precondition(PronunciationSettingsStore(preferences: preferences).sources.isEmpty)
        for index in 0..<PronunciationSettingsStore.maximumSources {
            try reloaded.save(PronunciationSource(name: "Source \(index)", template: source.template))
        }
        do {
            try reloaded.save(PronunciationSource(name: "Overflow", template: source.template))
            preconditionFailure("source limit must be enforced")
        } catch { }

        // Invalid/empty requests must release any state immediately and remain
        // retryable. These checks never create a remote audio request.
        source.enabled = true
        let playback = PronunciationService()
        let owner = UUID()
        playback.play(source: source, text: "", owner: owner)
        precondition(playback.state == .error)
        precondition(playback.errorMessage != nil)
        playback.stop(owner: UUID())
        precondition(playback.state == .error)
        playback.stop(owner: owner)
        precondition(playback.state == .idle && playback.owner == nil && playback.sourceID == nil)
        precondition(playback.errorMessage == nil)
        source.enabled = true
        source.template = "file:///tmp/{text}"
        playback.play(source: source, text: "hello", owner: owner)
        precondition(playback.state == .error)
        playback.stop()
        precondition(playback.state == .idle)
        print("Pronunciation checks passed (encoding, unique colors, migration, validation, persistence, limits and request cleanup).")
    }
}
