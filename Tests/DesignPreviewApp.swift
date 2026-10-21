import AppKit
import SwiftUI

private final class DesignDictionary: DictionaryServing {
    func suggestions(_ query: String) async throws -> [Suggestion] {
        try await Task.sleep(nanoseconds: 150_000_000)
        if query == "player" {
            return [Suggestion(word: query, phonetic: nil, translationPreview: "运动员；演奏者；播放器", translation: nil)]
        }
        return zip(["play", "player", "playing", "playground"],
                   ["游戏；玩；播放", "运动员；演奏者；播放器", "游戏的；正在播放的", "操场；游乐场"])
            .map { Suggestion(word: $0.0, phonetic: nil, translationPreview: $0.1, translation: nil) }
    }
    func entry(_ word: String) async throws -> Entry {
        try await Task.sleep(nanoseconds: 100_000_000)
        return Entry(id: 1, word: word, phonetic: word == "player" ? "/ˈpleɪə(r)/" : "/pleɪ/",
            definition: word == "player" ? "1. a person who takes part in a game or sport\n2. a person who plays a musical instrument" : "a dramatic work intended for performance by actors on a stage",
            translation: word == "player" ? "n. 运动员；演员；演奏者\n播放设备；播放器" : "n. 游戏；比赛；戏剧",
            tags: [], partsOfSpeech: [], inflections: [.init(type: "plural", typeName: "词形", form: word + "s")])
    }
    func search(_ query: String, translation: Bool) async throws -> [Suggestion] { try await suggestions(query) }
}

private actor PreviewAI: AIQueryServing {
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        try await Task.sleep(nanoseconds: 150_000_000)
        return AIAnswer(kind: kind.resolved(for: text), translation: "这是用于检查布局的模拟译文。",
                        explanation: "此预览只使用本机模拟数据。", examples: [])
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let suite = "ODict.ResizePreview.\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var model: LookupModel!
    private var status: MenuBarController!
    private var controller: LookupWindowController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults = UserDefaults(suiteName: suite)!
        let store = LocalDictionaryStore(defaults: defaults)
        try! store.save([], mode: .onlineOnly)
        var configuration = AIConfiguration()
        configuration.address = "https://fixture.invalid/v1"
        configuration.model = "界面模拟"
        let fixtureConfiguration = configuration
        model = LookupModel(router: DictionaryRouter(remote: DesignDictionary(), local: LocalDictionaryLibrary(), store: store),
                            history: RecentWordsStore(defaults: defaults), preferences: defaults,
                            ai: AIQueryModel(client: PreviewAI(), configuration: { fixtureConfiguration }))
        status = MenuBarController()
        controller = LookupWindowController(model: model, status: status, actions: LookupWindowActions(
            openSettings: {}, captureSelection: {}, captureScreenshot: {}, editQuery: {}, interacted: {},
            dismissed: { [weak self] in self?.model.suspend() }), preferences: defaults)
        status.onToggle = { [weak self] in self?.controller.show(anchor: nil) }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem)
        let checks = NSMenuItem(title: "布局验证", action: nil, keyEquivalent: "")
        let checksMenu = NSMenu()
        for (title, action, key) in [("默认尺寸", #selector(defaultSize), "1"), ("最小尺寸", #selector(minimumSize), "2"), ("放大窗口", #selector(largeSize), "3"), ("重新打开", #selector(reopen), "4")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; checksMenu.addItem(item)
        }
        checks.submenu = checksMenu; menu.addItem(checks); NSApp.mainMenu = menu
        controller.show(anchor: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func resizeFixture(_ size: NSSize) {
        guard let window = NSApp.windows.first(where: { $0.title == "ODict 查词" }) else { return }
        precondition(window.styleMask.contains(.resizable))
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        controller.screenChanged()
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        FileHandle.standardError.write(Data("Preview size: \(window.frame.width) x \(window.frame.height)\n".utf8))
    }
    @objc private func defaultSize() { resizeFixture(LookupWindowLayout.defaultSize) }
    @objc private func minimumSize() { resizeFixture(LookupWindowLayout.minimumSize) }
    @objc private func largeSize() { resizeFixture(NSSize(width: 700, height: 580)) }
    @objc private func reopen() {
        controller.hide()
        controller.show(anchor: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller.hide()
        status.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}
@main
private struct DesignPreviewApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
