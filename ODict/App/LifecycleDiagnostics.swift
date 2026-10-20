import AppKit
import os

@MainActor
enum LifecycleDiagnostics {
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "WindowLifecycle")
    private static let start = ProcessInfo.processInfo.systemUptime

    static func record(_ event: String, panel: NSWindow? = nil) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let visible = panel?.isVisible ?? false
        let key = panel?.isKeyWindow ?? false
        let onSpace = panel?.isOnActiveSpace ?? false
        log.debug("event=\(event, privacy: .public) elapsed=\(elapsed) visible=\(visible) key=\(key) onActiveSpace=\(onSpace) active=\(NSApp.isActive)")
    }

    static func statusClick() {
        let delay = NSApp.currentEvent.map { max(0, ProcessInfo.processInfo.systemUptime - $0.timestamp) } ?? 0
        log.debug("event=status.click dispatchDelay=\(delay)")
    }
}
