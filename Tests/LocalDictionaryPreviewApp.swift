import SwiftUI

private final class PreviewRemote: DictionaryServing {
    func entry(_ word: String) async throws -> Entry {
        Entry(id:1,word:word,phonetic:"/həˈləʊ/",definition:"used as a greeting",translation:"int. 你好；喂（模拟在线数据）",tags:[],partsOfSpeech:[],inflections:[])
    }
    func suggestions(_ query: String) async throws -> [Suggestion] { [Suggestion(word:query,phonetic:nil,translationPreview:nil,translation:nil)] }
    func search(_ query: String,translation: Bool) async throws -> [Suggestion] { try await suggestions(query) }
}
private struct PreviewRoot: View {
    @StateObject private var model: LookupModel
    @State private var settings = false
    @State private var diagnostics = ""
    private let dictionaries: [LocalDictionaryConfiguration]
    private let store = LocalDictionaryStore()
    init() {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["ODICT_FIXTURE_ROOT"] ?? "/Volumes/Data/dict")
        dictionaries = ["oxford-advanced-learner-dictionary-8","LDOCE6++.En-Cn.V3-0"].compactMap {
            try? LocalDictionaryDiscovery.discover(root.appendingPathComponent($0)).first
        }
        try? store.save(dictionaries,mode:.localFirst)
        _model = StateObject(wrappedValue: LookupModel(router:DictionaryRouter(remote:PreviewRemote()),history:RecentWordsStore()))
    }
    var body: some View {
        VStack(spacing:12) {
            HStack {
                Button("牛津") { settings=false; try? store.save(dictionaries,mode:.localFirst); model.lookup("hello") }
                Button("朗文") { settings=false; try? store.save(Array(dictionaries.reversed()),mode:.localFirst); model.lookup("hello") }
                Button("模拟在线") { settings=false; try? store.save(dictionaries,mode:.onlineOnly); model.lookup("hello") }
                Button("释放本地内容") { model.suspend() }
                Button("词典设置") { model.suspend(); settings.toggle() }
                #if ODICT_CHECKS
                Button("诊断") { Task {
                    let count = await LocalDictionaryLibrary.shared.readerCountForChecks()
                    diagnostics = "WebView: \(LocalRendererDiagnostics.liveCount), readers: \(count)"
                } }
                #endif
            }
            if !diagnostics.isEmpty { Text(diagnostics).font(.caption) }
            if settings {
                ScrollView { LocalDictionarySettingsView().padding(20) }.frame(width:640,height:440)
            } else {
                LookupView(model:model,openSettings:{settings=true},close:{model.suspend()})
            }
        }.padding(20).frame(width:680,height:540)
            .onAppear { model.lookup("hello"); NSApp.activate(ignoringOtherApps:true) }
    }
}
@main private struct LocalDictionaryPreviewApp: App {
    var body: some Scene {
        WindowGroup("ODict 本地词典验证") { PreviewRoot() }
    }
}
