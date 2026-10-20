import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictionary = Self("toggleDictionary")
    static let selectedTextLookup = Self("selectedTextLookup")
    static let screenshotLookup = Self("screenshotLookup")
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
