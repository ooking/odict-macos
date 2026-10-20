import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?
    var didSave: (() -> Void)?

    func show() {
        if window == nil {
            let model = SettingsModel()
            model.didSave = { [weak self] in self?.didSave?() }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 512, height: 680),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ODict 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            self.model = model
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model?.load()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() {
        model?.close()
        window?.delegate = nil
        window?.close()
        window = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        window?.delegate = nil
        window = nil
        model = nil
    }
}
