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
    private var statusItem: NSStatusItem!
    private var lookupPanel: LookupPanel!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private lazy var model = LookupModel()
    private var settingsWindow: NSWindow?
    private var lookupAnchor: CGRect?
    private var lastExternalPID: pid_t?
    private lazy var capture: CaptureCoordinator = {
        let coordinator = CaptureCoordinator()
        coordinator.onResult = { [weak self] result in
            guard let self else { return }
            self.model.lookup(result.text)
            self.showLookup(anchor: result.anchor)
        }
        coordinator.onFailure = { [weak self] message, anchor in
            guard let self else { return }
            self.model.presentCaptureStatus(message, busy: false)
            self.showLookup(anchor: anchor)
        }
        coordinator.onRecognizing = { [weak self] anchor in
            guard let self else { return }
            self.model.presentCaptureStatus("正在本机识别文字…", busy: true)
            self.showLookup(anchor: anchor)
        }
        coordinator.onCancelled = { [weak self] in
            guard let self else { return }
            self.hideLookup()
            guard let pid = self.lastExternalPID else { return }
            NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
        }
        return coordinator
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyPreferencesMigration.run()
        NSApp.setActivationPolicy(.accessory)
        rememberExternalApplication()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(externalApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
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
        KeyboardShortcuts.onKeyUp(for: .selectedTextLookup) { [weak self] in self?.startSelection() }
        KeyboardShortcuts.onKeyUp(for: .screenshotLookup) { [weak self] in self?.startScreenshot() }
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
            resize: { [weak self] size in self?.resizeLookup(size: size) },
            captureSelection: { [weak self] in self?.startSelection() },
            captureScreenshot: { [weak self] in self?.startScreenshot() },
            editQuery: { [weak self] in self?.capture.cancel() }))
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            // Clip the backing surface too: the glass shape alone does not clip
            // the borderless window's rectangular content surface at its corners.
            glass.wantsLayer = true
            glass.layer?.cornerRadius = glass.cornerRadius
            glass.layer?.masksToBounds = true
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
        capture.cancel()
        showLookup(anchor: nil)
    }

    private func showLookup(anchor: CGRect?) {
        lookupAnchor = anchor
        positionLookup()
        NSApp.activate(ignoringOtherApps: true)
        lookupPanel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        model.focusRequest = UUID()
        removeClickMonitors()
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
        if let anchor = lookupAnchor {
            let screen = NSScreen.screens.max { left, right in
                let l = left.frame.intersection(anchor), r = right.frame.intersection(anchor)
                return (l.isNull ? 0 : l.width * l.height) < (r.isNull ? 0 : r.width * r.height)
            } ?? NSScreen.main
            guard let screen else { return }
            lookupPanel.setFrameOrigin(CaptureGeometry.panelOrigin(size: lookupPanel.frame.size,
                anchor: anchor, visible: screen.visibleFrame))
            return
        }
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
        capture.cancel()
        guard lookupPanel != nil else { return }
        lookupPanel.orderOut(nil)
        statusItem.button?.highlight(false)
        removeClickMonitors()
        model.suspend()
    }

    private func removeClickMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    private func sourcePID() -> pid_t? {
        rememberExternalApplication()
        return lastExternalPID
    }

    private func rememberExternalApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
        }
    }

    @objc private func externalApplicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
        capture.cancel()
    }

    private var pointerAnchor: CGRect { CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1)) }

    private func startSelection(pid: pid_t? = nil) {
        let source = pid ?? sourcePID()
        let anchor = pointerAnchor
        hideLookup()
        settingsWindow?.orderOut(nil)
        capture.takeSelection(pid: source, anchor: anchor, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    private func startScreenshot() {
        let anchor = pointerAnchor
        hideLookup()
        settingsWindow?.orderOut(nil)
        capture.takeScreenshot(anchor: anchor)
    }

    private func showSettings() {
        hideLookup()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 512, height: 680),
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
        capture.cancel()
        if model.captureStatus != nil { hideLookup() }
        if lookupPanel.isVisible { positionLookup() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !lookupPanel.isVisible && settingsWindow?.isVisible != true { toggleLookup() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        hideLookup()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

// Borderless NSPanel removes the popover arrow while allowing a native field editor.
private final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
