import AppKit
import KeyboardShortcuts

/// Connects independent feature controllers; platform notifications are interpreted
/// here instead of being allowed to directly cancel any arbitrary in-flight task.
@MainActor
final class ApplicationCoordinator: NSObject {
    private let model: LookupModel
    private let status = MenuBarController()
    private let settings = SettingsWindowController()
    private var lastExternalPID: pid_t?
    private var captureOriginPID: pid_t?
    private lazy var lookup = LookupWindowController(model: model, status: status, actions: LookupWindowActions(
        openSettings: { [weak self] in self?.showSettings() },
        captureSelection: { [weak self] in self?.startSelection() },
        captureScreenshot: { [weak self] in self?.startScreenshot() },
        editQuery: { [weak self] in self?.capture.cancel() },
        dismissed: { [weak self] in self?.capture.cancel(); self?.model.suspend() }))
    private lazy var capture: CaptureCoordinator = {
        let coordinator = CaptureCoordinator()
        coordinator.onResult = { [weak self] result in
            guard let self else { return }
            self.model.lookup(result.text)
            self.lookup.show(anchor: result.anchor)
        }
        coordinator.onFailure = { [weak self] message, anchor in
            guard let self else { return }
            self.model.presentCaptureStatus(message, busy: false)
            self.lookup.show(anchor: anchor)
        }
        coordinator.onRecognizing = { [weak self] anchor in
            guard let self else { return }
            self.model.presentCaptureStatus("正在本机识别文字…", busy: true)
            self.lookup.show(anchor: anchor)
        }
        coordinator.onCancelled = { [weak self] in
            guard let self else { return }
            self.lookup.hide()
            if let pid = self.captureOriginPID {
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
            }
        }
        return coordinator
    }()

    override init() {
        LegacyPreferencesMigration.run()
        model = LookupModel()
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        rememberSource()
        status.onToggle = { [weak self] in self?.toggleLookup() }
        settings.didSave = { [weak self] in self?.model.suspend() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sourceChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        _ = lookup
        KeyboardShortcuts.onKeyUp(for: .toggleDictionary) { [weak self] in self?.toggleLookup() }
        KeyboardShortcuts.onKeyUp(for: .selectedTextLookup) { [weak self] in self?.startSelection() }
        KeyboardShortcuts.onKeyUp(for: .screenshotLookup) { [weak self] in self?.startScreenshot() }
        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "didWelcome")
        }
        LifecycleDiagnostics.record("launch.ready")
    }

    func toggleLookup() {
        if lookup.isVisible { lookup.hide(); return }
        capture.cancel()
        lookup.show(anchor: nil)
    }

    private func showSettings() {
        lookup.hide()
        settings.show()
    }

    private func rememberSource() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
        }
    }

    @objc private func sourceChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
        // Removing an OCR overlay can return focus to its original app. That is
        // an expected transition, not the user abandoning the capture operation.
        if capture.isRunning, captureOriginPID == app.processIdentifier { return }
        capture.cancel()
        if lookup.isVisible { lookup.hide(reason: "externalApplicationActivated") }
    }

    private func prepareCapture() -> CGRect {
        rememberSource()
        captureOriginPID = lastExternalPID
        lookup.hide()
        settings.close()
        return CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
    }

    private func startSelection() {
        let anchor = prepareCapture()
        capture.takeSelection(pid: captureOriginPID, anchor: anchor, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    private func startScreenshot() { capture.takeScreenshot(anchor: prepareCapture()) }

    func resignedActive() {
        guard !NSApp.isActive else { return }
        // Closing settings or showing a nonactivating selection panel can resign
        // the app without abandoning capture. Actual external switches are handled
        // by sourceChanged; deactivation alone must not dismiss the overlay.
        if capture.isRunning, !lookup.isVisible { return }
        if !lookup.isKeyWindow { lookup.hide(reason: "applicationDeactivated") }
    }

    func screenChanged() {
        capture.cancel()
        if model.captureStatus != nil { lookup.hide() }
        lookup.screenChanged()
    }

    func reopen() {
        if !lookup.isVisible && !settings.isVisible { toggleLookup() }
    }

    func stop() {
        capture.cancel()
        lookup.hide()
        settings.close()
        KeyboardShortcuts.removeAllHandlers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        status.stop()
    }
}
