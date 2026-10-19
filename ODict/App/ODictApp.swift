import SwiftUI
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictionary = Self("toggleDictionary")
}

@main
struct ODictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lookupPanel: LookupPanel!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private let model = LookupModel()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "ODict 查词")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ODict — 点击查词"
            button.target = self
            button.action = #selector(toggleLookup)
        }
        configureLookupPanel()
        KeyboardShortcuts.onKeyUp(for: .toggleDictionary) { [weak self] in self?.toggleLookup() }
        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "didWelcome")
        }
    }

    private func configureLookupPanel() {
        lookupPanel = LookupPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: false)
        lookupPanel.isReleasedWhenClosed = false
        lookupPanel.isOpaque = false
        lookupPanel.backgroundColor = .clear
        lookupPanel.hasShadow = true
        lookupPanel.level = .floating
        lookupPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        lookupPanel.title = "ODict 查词"
        let hostingView = NSHostingView(rootView: LookupView(model: model,
            openSettings: { [weak self] in self?.showSettings() },
            close: { [weak self] in self?.hideLookup() },
            resize: { [weak self] size in self?.resizeLookup(size: size) }))
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = hostingView
            lookupPanel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            material.layer?.masksToBounds = true
            hostingView.frame = material.bounds
            material.addSubview(hostingView)
            lookupPanel.contentView = material
        }
    }

    @objc private func toggleLookup() {
        if lookupPanel.isVisible { hideLookup(); return }
        positionLookup()
        NSApp.activate(ignoringOtherApps: true)
        lookupPanel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        model.focusRequest = UUID()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideLookup()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.lookupPanel && event.window !== self.statusItem.button?.window {
                self.hideLookup()
            }
            return event
        }
    }

    private func positionLookup() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = lookupPanel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY - 6)
        let y = max(visible.minY + 8, top - size.height)
        lookupPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resizeLookup(size: NSSize) {
        lookupPanel.setContentSize(size)
        if lookupPanel.isVisible { positionLookup() }
    }

    private func hideLookup() {
        guard lookupPanel != nil else { return }
        lookupPanel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
        model.suspend()
    }

    private func showSettings() {
        hideLookup()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 512, height: 430),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ODict 设置"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(didSave: { [weak self] in
                self?.model.suspend()
                self?.model.queryChanged()
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Field-editor and panel-size changes can transiently move key-window status.
    // Dismiss only on an outside click or actual app deactivation.
    func applicationDidResignActive(_ notification: Notification) { hideLookup() }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if lookupPanel.isVisible { positionLookup() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !lookupPanel.isVisible && settingsWindow?.isVisible != true { toggleLookup() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { hideLookup() }
}

// Borderless NSPanel removes the popover arrow while allowing a native field editor.
private final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
