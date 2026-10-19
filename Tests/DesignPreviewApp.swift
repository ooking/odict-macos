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

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let model = LookupModel(dictionary: DesignDictionary())
    var panel: PreviewPanel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "ODict 设计验证"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let hosting = NSHostingView(rootView: LookupView(model: model, openSettings: {}, close: { [weak self] in
            self?.model.suspend(); NSApp.terminate(nil)
        }, resize: { [weak self] size in self?.panel.setContentSize(size) }))
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 16
            glass.contentView = hosting; panel.contentView = glass
        } else {
            let material = NSVisualEffectView(); material.material = .popover; material.blendingMode = .behindWindow
            material.addSubview(hosting); panel.contentView = material
        }
        model.query = "play"; model.queryChanged()
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
private final class PreviewPanel: NSPanel { override var canBecomeKey: Bool { true } }

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
