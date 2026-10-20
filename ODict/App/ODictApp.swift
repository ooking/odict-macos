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
