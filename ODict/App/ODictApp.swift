import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictionary = Self("toggleDictionary")
    static let selectedTextLookup = Self("selectedTextLookup")
    static let screenshotLookup = Self("screenshotLookup")
    static let toggleHoverLookup = Self("toggleHoverLookup")
}

@main
struct ODictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ApplicationCoordinator?
    private var awaitingHistorySave = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        LifecycleDiagnostics.record("launch.begin")
        let coordinator = ApplicationCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }
    func applicationDidBecomeActive(_ notification: Notification) { coordinator?.becameActive() }
    func applicationDidResignActive(_ notification: Notification) { coordinator?.resignedActive() }
    func applicationDidChangeScreenParameters(_ notification: Notification) { coordinator?.screenChanged() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !awaitingHistorySave else { return .terminateLater }
        awaitingHistorySave = true
        Task { @MainActor in
            let saved = await coordinator.prepareForTermination()
            var shouldQuit = saved
            if !saved {
                let alert = NSAlert()
                alert.messageText = "部分 AI 历史记录尚未保存"
                alert.informativeText = "退出后，尚未写入磁盘的结果可能丢失。可以返回应用，检查磁盘空间或文件权限后重试。"
                alert.addButton(withTitle: "返回应用")
                alert.addButton(withTitle: "仍然退出")
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if !shouldQuit { coordinator.cancelTerminationPreparation() }
            self.awaitingHistorySave = false
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.reopen()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        coordinator = nil
    }
}

// Shared native typography; system fallback preserves Chinese and IPA glyphs.
enum AppTypography {
    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let navigation = Font.system(size: 14, weight: .medium)
    static let body = Font.system(size: 14)
    static let secondary = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let word = Font.system(size: 30, weight: .semibold)
    static let candidate = Font.system(size: 16, weight: .medium)
    static let search = NSFont.systemFont(ofSize: 16)
}
