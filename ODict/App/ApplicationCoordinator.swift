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
        interacted: { [weak self] in self?.hover.cancel(dismiss: false) },
        dismissed: { [weak self] in
            self?.hover.cancel(dismiss: false)
            self?.capture.cancel()
            self?.model.suspend()
        }))
    private lazy var hover: HoverLookupController = {
        let controller = HoverLookupController()
        controller.canBegin = { [weak self] in
            guard let self else { return false }
            return !self.settings.isVisible && !self.capture.isRunning && (!self.lookup.isVisible || self.lookup.isHover)
        }
        controller.containsPanel = { [weak self] point in self?.lookup.contains(point) ?? false }
        controller.onResult = { [weak self] result in
            guard let self else { return }
            self.model.lookup(result.text)
            self.lookup.show(anchor: result.anchor, hover: true)
        }
        controller.onFailure = { [weak self] message, anchor in
            guard let self else { return }
            self.model.presentCaptureStatus(message, busy: false)
            self.lookup.show(anchor: anchor, hover: true)
        }
        controller.onInteraction = { [weak self] in self?.lookup.promote() }
        controller.onDismiss = { [weak self] in
            guard let self, self.lookup.isHover else { return }
            self.lookup.hide(reason: "hoverEnded", notifyDismissed: false)
            self.model.suspend()
        }
        return controller
    }()
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
        settings.didSave = { [weak self] in self?.model.sourcesChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(dictionarySourcesChanged),
            name: LocalDictionaryStore.changed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sourceChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelHover), name: name, object: nil)
        }
        _ = lookup
        NotificationCenter.default.addObserver(self, selector: #selector(hoverPreferenceChanged),
            name: HoverLookupController.preferenceChanged, object: nil)
        hover.updateEnabled()
        KeyboardShortcuts.onKeyUp(for: .toggleDictionary) { [weak self] in self?.toggleLookup() }
        KeyboardShortcuts.onKeyUp(for: .selectedTextLookup) { [weak self] in self?.startSelection() }
        KeyboardShortcuts.onKeyUp(for: .screenshotLookup) { [weak self] in self?.startScreenshot() }
        KeyboardShortcuts.onKeyUp(for: .toggleHoverLookup) {
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: HoverLookupController.preferenceKey), forKey: HoverLookupController.preferenceKey)
            NotificationCenter.default.post(name: HoverLookupController.preferenceChanged, object: nil)
        }
        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "didWelcome")
        }
        LifecycleDiagnostics.record("launch.ready")
    }

    @objc private func dictionarySourcesChanged() { model.sourcesChanged() }

    @objc private func cancelHover() { hover.cancel() }

    @objc private func hoverPreferenceChanged() { hover.updateEnabled() }

    func toggleLookup() {
        hover.cancel()
        if lookup.isVisible { lookup.hide(); return }
        capture.cancel()
        lookup.show(anchor: nil)
    }

    private func showSettings() {
        hover.cancel()
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
        hover.cancel()
        // Removing an OCR overlay can return focus to its original app. That is
        // an expected transition, not the user abandoning the capture operation.
        if capture.isRunning, captureOriginPID == app.processIdentifier { return }
        capture.cancel()
        if lookup.isVisible { lookup.hide(reason: "externalApplicationActivated") }
    }

    private func prepareCapture() -> CGRect {
        hover.cancel()
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

    func becameActive() { hover.updateEnabled() }

    func resignedActive() {
        guard !NSApp.isActive else { return }
        // Closing settings or showing a nonactivating selection panel can resign
        // the app without abandoning capture. Actual external switches are handled
        // by sourceChanged; deactivation alone must not dismiss the overlay.
        if capture.isRunning, !lookup.isVisible { return }
        if !lookup.isKeyWindow && !lookup.isHover { lookup.hide(reason: "applicationDeactivated") }
    }

    func screenChanged() {
        hover.cancel()
        capture.cancel()
        if model.captureStatus != nil { lookup.hide() }
        lookup.screenChanged()
    }

    func reopen() {
        if !lookup.isVisible && !settings.isVisible { toggleLookup() }
    }

    func stop() {
        hover.stop()
        capture.cancel()
        lookup.hide()
        settings.close()
        KeyboardShortcuts.removeAllHandlers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        status.stop()
    }
}
