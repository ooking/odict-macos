import Foundation

private final class UnusedOnline: DictionaryServing {
    var calls = 0
    func entry(_ word: String) async throws -> Entry { calls += 1; throw DictionaryError.notFound }
    func suggestions(_ query: String) async throws -> [Suggestion] { calls += 1; return [] }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { calls += 1; return [] }
}
@main private struct CandidateRedirectChecks {
    @MainActor static func settled(_ model: LookupModel) async throws {
        for _ in 0..<300 {
            if !model.isSuggesting && !model.isLoading { return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw NSError(domain:"CandidateChecks",code:1,userInfo:[NSLocalizedDescriptionKey:"query did not settle"])
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: CandidateRedirectChecks /path/to/dictionaries\n".utf8))
            exit(64)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let folder = root.appendingPathComponent("LDOCE6++.En-Cn.V3-0", isDirectory: true)
        guard let dictionary = try LocalDictionaryDiscovery.discover(folder).first else {
            throw NSError(domain: "CandidateChecks", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The specified root must contain an MDX dictionary in LDOCE6++.En-Cn.V3-0."
            ])
        }
        let reader = try MDXReader(url:URL(fileURLWithPath:dictionary.mdxPath))
        for word in ["recoated","recoating","recoats"] {
            let raw = try reader.rawRecordsForChecks(word)
            precondition(raw.count == 1 && raw[0].content == "@@@LINK=coat","unexpected dictionary fixture mapping")
            print("RAW:",word,"->",raw[0].content,"offset",raw[0].offset)
        }
        let absent = try reader.rawRecordsForChecks("recoat")
        precondition(absent.isEmpty,"recoat has no independent entry in this dictionary fixture")
        let suite = "ODict.CandidateRedirectChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = LocalDictionaryStore(defaults:defaults)
        try store.save([dictionary],mode:.localFirst)
        let online = UnusedOnline(), library = LocalDictionaryLibrary()
        let model = LookupModel(router:DictionaryRouter(remote:online,local:library,store:store),history:RecentWordsStore(defaults:defaults),preferences:defaults)
        model.editQuery("reco",composing:false)
        try await settled(model)
        precondition(model.suggestions.contains { $0.word == "recoated" })
        precondition(model.selectedSuggestion?.word == "recoagulate")
        precondition(model.localArticle?.word == "recoagulate" && model.localArticle?.headwords == ["coagulate"])
        model.selectSuggestion("recoated")
        try await settled(model)
        precondition(model.selectedSuggestion?.word == "recoated")
        precondition(model.result?.word == "recoated" && model.localArticle?.headwords == ["coat"])
        precondition(model.localArticle?.correspondingHeadwords == ["coat"])
        precondition(model.recent.first == "recoated" && !model.recent.contains("coat"))
        let identity = model.localArticle?.id
        model.submit()
        try await settled(model)
        precondition(model.localArticle?.id == identity,"Return reuses the selected alias result")
        precondition(model.moveSuggestion(by:1))
        try await settled(model)
        precondition(model.selectedSuggestion?.word == "recoating" && model.result?.word == "recoating")
        precondition(model.localArticle?.headwords == ["coat"] && model.localArticle?.id != identity,
                     "two aliases sharing a target must retain independent selection identity")
        model.selectSuggestion("recoagulate")
        model.selectSuggestion("recoated")
        try await settled(model)
        precondition(model.result?.word == "recoated" && model.selectedSuggestion?.word == "recoated")
        precondition(model.localArticle?.headwords == ["coat"])
        precondition(online.calls == 0,"the entire reproduction stays offline")
        model.suspend()
        await library.release()
        print("PASS: actual reco candidates; selected word vs terminal headword; click/keyboard/Return; alias reuse; history identity; rapid selection; zero online calls")
    }
}
