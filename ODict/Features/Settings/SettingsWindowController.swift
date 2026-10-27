import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?
    var didSave: (() -> Void)?
    var visibilityChanged: ((Bool) -> Void)?

    func show(category: SettingsCategory? = nil) {
        if window == nil {
            let model = SettingsModel()
            model.category = category ?? .capture
            model.didSave = { [weak self] in self?.didSave?() }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ODict 设置"
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            self.model = model
            self.window = window
        }
        if let category { model?.category = category }
        visibilityChanged?(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() {
        let closingWindow = window
        releaseWindow()
        closingWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        releaseWindow()
    }

    private func releaseWindow() {
        guard window != nil else { return }
        model?.close()
        window?.delegate = nil
        window = nil
        model = nil
        visibilityChanged?(false)
    }
}
