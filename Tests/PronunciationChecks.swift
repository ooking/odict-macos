import Foundation

@main private struct PronunciationChecks {
    @MainActor static func main() throws {
        let suite = "ODict.PronunciationChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = PronunciationSettingsStore(preferences: preferences)
        precondition(store.sources.count == 2)
        precondition(Set(store.sources.map(\.id)).count == 2)
        let raw = "  Hello & 你好? #+/%=\nHow are you?  "
        for source in store.sources {
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
        print("Pronunciation checks passed (encoding, validation, persistence, limits and request cleanup).")
    }
}
